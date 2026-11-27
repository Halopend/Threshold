import Testing
import ThresholdCore
import ThresholdRender
@testable import ThresholdUI

private actor PreparationGate {
    private var continuation: CheckedContinuation<ExternalDEProgram?, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func prepare() async throws -> ExternalDEProgram? {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(failing: Bool) {
        if failing { continuation?.resume(throwing: ExternalDEError.missingEntryPoint) }
        else { continuation?.resume(returning: nil) }
        continuation = nil
    }
}

@MainActor
@Suite("Scene selection ordering")
struct SceneLoadCoordinatorTests {
    private func scene(_ key: String, external: Bool = false) -> SceneEnvelope {
        var result = SceneEnvelope(version: 1, fractalTypeKey: key)
        if external {
            result.embeddedDE = EmbeddedDE(source: "test", abiVersion: 3, hash: "")
        }
        return result
    }

    @Test("A newer built-in selection suppresses older compilation and diagnostics", arguments: [false, true])
    func stalePreparation(failing: Bool) async {
        let commands = CommandMailbox<SessionCommand>()
        let mirror = ParameterMirror(layout: makeTestLayout(), snapshots: SnapshotSlot(), commands: commands)
        let gate = PreparationGate()
        let loads = SceneLoadCoordinator(mirror: mirror) { _ in try await gate.prepare() }
        var submitted = 0
        var failed = 0
        let old = loads.load(scene("old", external: true), onSubmitted: { submitted += 1 }, onFailure: { _ in failed += 1 })
        await gate.waitUntilStarted()
        loads.load(scene("new"), onSubmitted: { submitted += 1 }, onFailure: { _ in failed += 1 })
        await gate.finish(failing: failing)
        await old?.value
        let drained = commands.drain()
        #expect(drained.count == 1)
        if case .applyPreparedScene(let envelope, _, _) = drained.first {
            #expect(envelope.fractalTypeKey == "new")
        } else { Issue.record("Expected the latest prepared scene") }
        #expect(submitted == 1)
        #expect(failed == 0)
    }

    @Test("A fractal pick made while a scene compiles is not overwritten when it finishes")
    func structuralEditSupersedesCompile() async {
        let commands = CommandMailbox<SessionCommand>()
        let mirror = ParameterMirror(layout: makeTestLayout(), snapshots: SnapshotSlot(), commands: commands)
        let gate = PreparationGate()
        let loads = SceneLoadCoordinator(mirror: mirror) { _ in try await gate.prepare() }
        var submitted = 0
        let pending = loads.load(scene("old", external: true),
                                 onSubmitted: { submitted += 1 },
                                 onFailure: { _ in Issue.record("Unexpected failure") })
        await gate.waitUntilStarted()
        mirror.setDE(key: "picked")
        await gate.finish(failing: false)
        await pending?.value
        #expect(submitted == 0)
        #expect(mirror.deKey == "picked")
        let drained = commands.drain()
        #expect(drained.count == 1)
        if case .setDE(let key) = drained.first { #expect(key == "picked") }
        else { Issue.record("Expected only the user's fractal pick") }
    }

    @Test("Out-of-order external preparations submit only the latest scene and seed its editors")
    func externalOrdering() async {
        let commands = CommandMailbox<SessionCommand>()
        let mirror = ParameterMirror(layout: makeTestLayout(), snapshots: SnapshotSlot(), commands: commands)
        let oldGate = PreparationGate(), newGate = PreparationGate()
        let loads = SceneLoadCoordinator(mirror: mirror) { embedded in
            try await (embedded.source == "old" ? oldGate : newGate).prepare()
        }
        var older = scene("old", external: true)
        older.embeddedDE?.source = "old"
        var newer = scene("new", external: true)
        newer.embeddedDE?.source = "new"
        newer.bindings = [Binding(signal: .audioRMS, param: ParamKey("test.alpha"), lane: .music)]
        var submitted = 0
        let first = loads.load(older, onSubmitted: { submitted += 1 }, onFailure: { _ in Issue.record("Unexpected failure") })
        await oldGate.waitUntilStarted()
        let second = loads.load(newer, onSubmitted: { submitted += 1 }, onFailure: { _ in Issue.record("Unexpected failure") })
        await newGate.waitUntilStarted()
        await newGate.finish(failing: false)
        await second?.value
        await oldGate.finish(failing: false)
        await first?.value
        #expect(submitted == 1)
        #expect(mirror.bindings == newer.bindings)
        let drained = commands.drain()
        #expect(drained.count == 1)
        if case .applyPreparedScene(let envelope, _, _) = drained.first {
            #expect(envelope.fractalTypeKey == "new")
        } else { Issue.record("Expected the latest external scene") }
    }

    @Test("Current preparation failure changes neither renderer nor editors")
    func failedPreparation() async {
        let commands = CommandMailbox<SessionCommand>()
        let mirror = ParameterMirror(layout: makeTestLayout(), snapshots: SnapshotSlot(), commands: commands)
        let loads = SceneLoadCoordinator(mirror: mirror) { _ in throw ExternalDEError.missingEntryPoint }
        var failed = false
        let task = loads.load(scene("bad", external: true), onSubmitted: { Issue.record("Unexpected submission") }, onFailure: { _ in failed = true })
        await task?.value
        #expect(failed)
        #expect(commands.drain().isEmpty)
    }

    @Test("Mailbox rejection preserves editors and skips platform side effects")
    func backpressure() {
        let commands = CommandMailbox<SessionCommand>(capacity: 1, maxCapacity: 1)
        let mirror = ParameterMirror(layout: makeTestLayout(), snapshots: SnapshotSlot(), commands: commands)
        commands.publish(.setPaused(true))
        var incoming = scene("mandelbulb")
        incoming.bindings = [Binding(signal: .audioRMS, param: ParamKey("test.alpha"), lane: .music)]
        let loads = SceneLoadCoordinator(mirror: mirror) { _ in nil }
        var failed = false
        loads.load(incoming, onSubmitted: { Issue.record("Rejected scene ran platform effects") }, onFailure: { _ in failed = true })
        #expect(failed)
        #expect(mirror.bindings.isEmpty)
        #expect(!mirror.applyScene(incoming))
        #expect(mirror.bindings.isEmpty)
        #expect(commands.pendingCount == 1)
    }
}
