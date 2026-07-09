// SessionCoreTests.swift — the interactive session's per-frame logic, driven
// manually (no display link, no drawable): commands, grab-what-you-see edits,
// bindings, pause, determinism, and one GPU-guarded render of a stepped
// frame's request through OffscreenRenderer.
//
// Determinism: timestamps are synthetic (fed into step(now:)), any randomness
// is seeded SplitMix64 from TestSupport.

import Foundation
import simd
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

// MARK: - Fixture

/// Test-only param keys (raw-string init is sanctioned for tests/codecs).
private enum TK {
    static let add = ParamKey("session.test.add")
    static let mul = ParamKey("session.test.mul")
    static let rate = ParamKey("session.test.rate")
    static let phase = ParamKey("session.test.phase")
}

/// Engine defaults + both built-in DEs + instant-smoothing test params:
/// an additive, a multiplicative, and an integrator (rate + phase).
/// Instant smoothing keeps the userEdit/binding assertions EXACT — the
/// inversion guarantee is resolve(invert(x)) == clamp(x) at tau 0.
private func makeSessionLayout() -> CatalogLayout {
    let catalog = Catalog.withEngineDefaults()
    for descriptor in DERegistry.builtin {
        try! descriptor.registerParams(into: catalog)
    }
    try! catalog.register(ParamSpec(
        key: TK.add, label: "Test Additive",
        range: -10...10, default: 1,
        composition: .additive, smoothing: .instant,
        persistence: .scene, capabilities: [.musicBindable], group: .shape))
    try! catalog.register(ParamSpec(
        key: TK.mul, label: "Test Multiplicative",
        range: 0...10, default: 2,
        composition: .multiplicative, smoothing: .instant,
        persistence: .scene, group: .shape))
    try! catalog.register(ParamSpec(
        key: TK.rate, label: "Test Rate",
        range: 0...4, default: 1,
        composition: .additive, smoothing: .instant,
        persistence: .scene, group: .color))
    try! catalog.register(ParamSpec(
        key: TK.phase, label: "Test Phase",
        range: 0...1, default: 0,
        smoothing: .instant, persistence: .transient,
        group: .color, integratorRateKey: TK.rate))
    return catalog.freeze()
}

/// A SessionCore plus its channels, stepped with synthetic display-link
/// timestamps from an arbitrary origin (1000 s — proves nothing depends on a
/// zero-based clock).
private struct Harness {
    let layout: CatalogLayout
    let signals: SignalTable
    let mailbox: LaneMailbox
    let commands: CommandMailbox<SessionCommand>
    let core: SessionCore
    private(set) var now: Double = 1000.0

    init(scene: SceneEnvelope? = nil) {
        layout = makeSessionLayout()
        signals = SignalTable(ids: SignalID.standardSession)
        mailbox = LaneMailbox()
        commands = CommandMailbox<SessionCommand>()
        core = SessionCore(
            layout: layout, signals: signals, laneMailbox: mailbox,
            commands: commands, initialScene: scene)
    }

    /// Advance the synthetic timestamp and step one frame. The FIRST call
    /// establishes the WallClock baseline (delta 0, session time 0).
    @discardableResult
    mutating func step(dt: Double = 1.0 / 60.0, width: Int = 32, height: Int = 32) -> SessionFrame {
        now += dt
        return core.step(now: now, width: width, height: height)
    }

    /// Step with a synthetic previous-frame GPU duration (governor input).
    @discardableResult
    mutating func step(gpuMilliseconds: Double) -> SessionFrame {
        now += 1.0 / 60.0
        return core.step(now: now, width: 32, height: 32, gpuMilliseconds: gpuMilliseconds)
    }

    func slot(_ key: ParamKey) -> Int {
        layout.slot(for: key)!
    }
}

// MARK: - Tests

@Suite("Interactive session core")
struct SessionCoreTests {

    // MARK: applyScene

    @Test func applySceneChangesResolvedValuesDEAndWarpStack() {
        var h = Harness()
        let baseline = h.step()
        #expect(baseline.deKey == "mandelbulb", "default DE before any scene")

        let authored = [
            WarpOpDTO(kind: WK.twist, strength: 0.5, a: [0, 1, 0, 0], b: [0, 0, 0, 0])
        ]
        let scene = SceneEnvelope(
            version: SceneCodec.currentVersion,
            fractalTypeKey: "mandelbox",
            params: [
                TK.add.rawValue: [3.5],
                ParamKey.de("mandelbox", "scale").rawValue: [2.5],
            ],
            warpStack: authored)
        h.commands.publish(.applyScene(scene, transition: nil))
        let frame = h.step()

        #expect(frame.deKey == "mandelbox")
        #expect(frame.request.uniforms.meta.y == 0, "mandelbox function-table index")
        #expect(frame.warpStack == authored, "snapshot carries the AUTHORED stack")
        #expect(frame.request.ops.count == 1)
        #expect(abs(frame.resolved.values[h.slot(TK.add)] - 3.5) < 1e-5)
        #expect(abs(frame.resolved.values[h.slot(.de("mandelbox", "scale"))] - 2.5) < 1e-5)

        let snapshot = frame.snapshot(gpuMilliseconds: 1.25, totalSteps: 7)
        #expect(snapshot.deKey == "mandelbox")
        #expect(snapshot.warpStack == authored)
        #expect(snapshot.gpuMilliseconds == 1.25 && snapshot.totalSteps == 7)
    }

    @Test func setWarpStackSimplifiesForGPUButKeepsAuthored() {
        var h = Harness()
        h.step()
        let authored = [
            WarpOpDTO(kind: WK.twist, strength: 0, a: [0, 1, 0, 0], b: [0, 0, 0, 0]),
            WarpOpDTO(kind: WK.twist, strength: 0.5, a: [0, 1, 0, 0], b: [0, 0, 0, 0]),
        ]
        h.commands.publish(.setWarpStack(authored))
        let frame = h.step()
        #expect(frame.warpStack == authored, "authored stack survives verbatim")
        #expect(frame.request.ops.count == 1, "zero-strength op simplified away for the GPU")
    }

    // MARK: setDE

    @Test func setDEPreservesUserLaneOffsetsAcrossSwap() {
        var h = Harness()
        h.step()
        let addSlot = h.slot(TK.add)

        h.commands.publish(.userEdit(slot: addSlot, targetResolved: 4.25))
        var frame = h.step()
        #expect(abs(frame.resolved.values[addSlot] - 4.25) <= 1e-4)

        h.commands.publish(.setDE(key: "mandelbox"))
        frame = h.step()
        #expect(frame.deKey == "mandelbox")
        #expect(frame.request.uniforms.meta.y == 0)
        #expect(abs(frame.resolved.values[addSlot] - 4.25) <= 1e-4,
                "DE swap swaps the descriptor ONLY — lane state persists (plan §2.1)")

        h.commands.publish(.setDE(key: "no-such-de"))
        frame = h.step()
        #expect(frame.deKey == "mandelbox", "unknown DE keys are ignored, never crash")
    }

    // MARK: userEdit / clearUserEdit (grab-what-you-see)

    @Test func userEditResolvesToClampedTargetWithNonzeroOtherLanes() {
        var h = Harness()
        h.step()
        let addSlot = h.slot(TK.add)
        let mulSlot = h.slot(TK.mul)

        // Nonzero OTHER lanes: gesture offsets on both params, settled first.
        h.mailbox.publish(LaneWrite(lane: .gesture, slot: addSlot, value: 0.7))
        h.mailbox.publish(LaneWrite(lane: .gesture, slot: mulSlot, value: 1.5))
        let before = h.step()
        #expect(abs(before.resolved.values[addSlot] - 1.7) <= 1e-5)  // 1 + 0.7
        #expect(abs(before.resolved.values[mulSlot] - 3.0) <= 1e-5)  // 2 × 1.5

        h.commands.publish(.userEdit(slot: addSlot, targetResolved: 4.2))
        h.commands.publish(.userEdit(slot: mulSlot, targetResolved: 2.5))
        let frame = h.step()
        #expect(abs(frame.resolved.values[addSlot] - 4.2) <= 1e-4,
                "additive inversion: resolve == clamp(target)")
        #expect(abs(frame.resolved.values[mulSlot] - 2.5) <= 1e-4,
                "multiplicative inversion: resolve == clamp(target)")

        // Out-of-range target lands on the clamp, not the raw value.
        h.commands.publish(.userEdit(slot: addSlot, targetResolved: 99))
        let clamped = h.step()
        #expect(abs(clamped.resolved.values[addSlot] - 10) <= 1e-4,
                "target 99 clamps to the param range's upper bound 10")
    }

    @Test func userEditBurstsCoalesceToLatestTargetPerSlot() {
        var h = Harness()
        h.step()
        let addSlot = h.slot(TK.add)
        let mulSlot = h.slot(TK.mul)

        for i in 0..<1_000 {
            h.commands.publish(.userEdit(slot: addSlot, targetResolved: Float(i % 10)))
            h.commands.publish(.userEdit(slot: mulSlot, targetResolved: Float((i % 5) + 1)))
        }

        let frame = h.step()
        #expect(abs(frame.resolved.values[addSlot] - 9) <= 1e-4)
        #expect(abs(frame.resolved.values[mulSlot] - 5) <= 1e-4)
    }

    @Test func clearUserEditRestoresPreEditResolvedValue() {
        var h = Harness()
        h.step()
        let mulSlot = h.slot(TK.mul)

        h.mailbox.publish(LaneWrite(lane: .gesture, slot: mulSlot, value: 1.5))
        let before = h.step().resolved.values[mulSlot]
        #expect(abs(before - 3.0) <= 1e-5)

        h.commands.publish(.userEdit(slot: mulSlot, targetResolved: 2.5))
        let edited = h.step().resolved.values[mulSlot]
        #expect(abs(edited - 2.5) <= 1e-4)

        h.commands.publish(.clearUserEdit(slot: mulSlot))
        let restored = h.step().resolved.values[mulSlot]
        #expect(abs(restored - before) <= 1e-4,
                "clearing the user-lane slot restores the pre-edit composition")
    }

    @Test func commitUserEditPersistsAcrossReleaseInsteadOfReverting() {
        var h = Harness()
        h.step()
        let addSlot = h.slot(TK.add)  // additive, base 1
        let mulSlot = h.slot(TK.mul)  // multiplicative, base 2

        // Nonzero transient (gesture) lanes so the commit exercises the
        // scene-lane inversion, not just a trivial replace.
        h.mailbox.publish(LaneWrite(lane: .gesture, slot: addSlot, value: 0.7))
        h.mailbox.publish(LaneWrite(lane: .gesture, slot: mulSlot, value: 1.5))
        h.step()

        // Drag (live user lane) then RELEASE via commit.
        h.commands.publish(.userEdit(slot: addSlot, targetResolved: 4.2))
        h.commands.publish(.userEdit(slot: mulSlot, targetResolved: 2.5))
        h.step()
        h.commands.publish(.commitUserEdit(slot: addSlot, targetResolved: 4.2))
        h.commands.publish(.commitUserEdit(slot: mulSlot, targetResolved: 2.5))
        let committed = h.step()

        // The edit does NOT revert on release (the bug being fixed) …
        #expect(abs(committed.resolved.values[addSlot] - 4.2) <= 1e-4,
                "commit keeps the resolved value at the target across release")
        #expect(abs(committed.resolved.values[mulSlot] - 2.5) <= 1e-4)

        // … and it persists across subsequent frames (it lives on the scene
        // lane now, so it is permanent and Save captures it).
        let later = h.step()
        #expect(abs(later.resolved.values[addSlot] - 4.2) <= 1e-4,
                "committed edit is permanent, not momentary")
        #expect(abs(later.resolved.values[mulSlot] - 2.5) <= 1e-4)
    }

    // MARK: bindings

    // TODO(core-bindings): this test currently runs against the PROVISIONAL
    // BindingEngine shim in ThresholdRender (BindingEngineShim.swift), written
    // to ThresholdCore's pinned API:
    //   BindingEngine(layout:); var bindings: [Binding];
    //   func apply(signals:engine:now:)
    // When ThresholdCore's BindingEngine lands, delete the shim; this test
    // then exercises the real engine unchanged.
    @Test func musicBindingMovesParamAndMomentaryReturnsTowardBaseWhenStale() {
        var h = Harness()
        h.step()  // session time 0 baseline
        let addSlot = h.slot(TK.add)

        let binding = Binding(
            signal: .audioRMS, param: TK.add, lane: .music,
            mapping: SignalMapping(), policy: .momentary, scale: 1)
        h.commands.publish(.setBindings([binding]))

        // Fresh sample, stamped with the NEXT frame's session-clock time.
        h.signals.publish(
            id: .audioRMS, value: SIMD4(0.5, 0, 0, 0), confidence: 1,
            timestamp: 1.0 / 60.0)
        let driven = h.step()
        #expect(abs(driven.resolved.values[addSlot] - 1.5) <= 1e-4,
                "base 1 + identity-mapped signal 0.5")

        // No republish: the signal goes stale; momentary policy releases the
        // music lane and the always-transient music decay does the rest.
        var frame = driven
        for _ in 0..<8 {
            frame = h.step(dt: 0.5)
        }
        #expect(abs(frame.resolved.values[addSlot] - 1.0) <= 1e-3,
                "stale momentary binding returns the param toward base")
    }

    // MARK: pause

    @Test func setPausedFreezesTimeAndIntegratorPhases() {
        var h = Harness()
        h.step()  // baseline: time 0, phase 0
        let phaseSlot = h.slot(TK.phase)

        let running = h.step()
        #expect(running.time > 0)
        #expect(running.resolved.values[phaseSlot] > 0,
                "integrator advances by rate × dt while running")

        h.commands.publish(.setPaused(true))
        let pausedFrame = h.step()
        #expect(pausedFrame.paused)
        #expect(pausedFrame.time == running.time,
                "pause lands before clock.update — time freezes immediately")

        let frozenPhase = pausedFrame.resolved.values[phaseSlot]
        var later = pausedFrame
        for _ in 0..<5 {
            later = h.step(dt: 0.25)
        }
        #expect(later.time == running.time, "snapshot.time frozen across steps")
        #expect(later.resolved.values[phaseSlot] == frozenPhase,
                "integrator phases frozen across steps")
        #expect(later.paused)

        // Unpausing resumes without a jump (paused spans not accumulated).
        h.commands.publish(.setPaused(false))
        let resumed = h.step()
        #expect(!resumed.paused)
        #expect(abs(resumed.time - (running.time + 1.0 / 60.0)) <= 1e-9)
        #expect(resumed.resolved.values[phaseSlot] > frozenPhase)
    }

    @Test func pausedSessionStillAcceptsInstantUserEdits() {
        var h = Harness()
        h.step()
        let addSlot = h.slot(TK.add)
        h.commands.publish(.setPaused(true))
        h.step()
        h.commands.publish(.userEdit(slot: addSlot, targetResolved: 5))
        let frame = h.step()
        #expect(abs(frame.resolved.values[addSlot] - 5) <= 1e-4,
                "pausing time must not disable the user's sliders")
    }

    // MARK: determinism

    @Test func identicallySteppedCoresProduceIdenticalResolvedTables() {
        var a = Harness()
        var b = Harness()
        var rng = SplitMix64(seed: 0xD1CE_5EED)

        let addSlot = a.slot(TK.add)
        let slots = [addSlot, a.slot(TK.mul), a.slot(TK.rate)]
        #expect(a.slot(TK.mul) == b.slot(TK.mul), "identical layouts")

        for frame in 0..<120 {
            if rng.bool(probability: 0.35) {
                let slot = slots[rng.int(in: 0...(slots.count - 1))]
                let lane: Lane = rng.bool() ? .gesture : .music
                let value = rng.float(in: -2...2)
                a.mailbox.publish(LaneWrite(lane: lane, slot: slot, value: value))
                b.mailbox.publish(LaneWrite(lane: lane, slot: slot, value: value))
            }
            if rng.bool(probability: 0.1) {
                let target = rng.float(in: 0...3)
                a.commands.publish(.userEdit(slot: addSlot, targetResolved: target))
                b.commands.publish(.userEdit(slot: addSlot, targetResolved: target))
            }
            if rng.bool(probability: 0.05) {
                a.commands.publish(.clearUserEdit(slot: addSlot))
                b.commands.publish(.clearUserEdit(slot: addSlot))
            }
            let dt = Double(rng.float(in: 0.008...0.033))
            let fa = a.step(dt: dt)
            let fb = b.step(dt: dt)
            #expect(fa.resolved.values == fb.resolved.values,
                    "resolved tables diverged at frame \(frame)")
            #expect(fa.time == fb.time && fa.frameIndex == fb.frameIndex)
        }
    }

    // MARK: resize

    @Test func requestFollowsPerStepDrawableSize() {
        var h = Harness()
        let small = h.step(width: 32, height: 24)
        #expect(small.request.width == 32 && small.request.height == 24)
        let big = h.step(width: 300, height: 200)
        #expect(big.request.width == 300 && big.request.height == 200,
                "dispatch size follows the drawable's actual size each frame")
    }

    // MARK: GPU round trip

    @Test(.enabled(if: GPU.available))
    func steppedFrameRendersThroughOffscreenRenderer() throws {
        var h = Harness()
        h.step()
        h.commands.publish(.setWarpStack([
            WarpOpDTO(kind: WK.twist, strength: 0.5, a: [0, 1, 0, 0], b: [0, 0, 0, 0])
        ]))
        let frame = h.step(width: 64, height: 64)

        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let result = try renderer.render(frame.request)
        #expect(result.width == 64 && result.height == 64)
        #expect(result.stats.totalSteps > 0, "the session-built request marches")
        #expect(
            stride(from: 3, to: result.rgba8.count, by: 4).allSatisfy { result.rgba8[$0] == 255 },
            "no NaN sentinel pixels from a session-built request")
    }

    // MARK: External DE via session commands

    @Test(.enabled(if: GPU.available))
    func externalDEActivatesRendersAndReverts() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let source = ExternalDETests.sphereSource
        let program = try loader.load(EmbeddedDE(
            source: source, abiVersion: Int(THRESHOLD_ABI_VERSION),
            hash: ExternalDELoader.sourceHash(source)))

        var h = Harness()
        h.step()

        // Activate: descriptor and meta.y follow the program.
        h.commands.publish(.setExternalDE(program))
        let external = h.step(width: 64, height: 64)
        #expect(external.deKey == program.descriptor.key)
        #expect(external.request.uniforms.meta.y == program.descriptor.index)
        #expect(external.externalProgram === program)

        // The frame renders through the program's extended table.
        let renderer = try OffscreenRenderer(context: ctx)
        let result = try renderer.render(external.request, program: program)
        #expect(result.stats.totalSteps > 0)

        // setDE reverts to a built-in and clears the program.
        h.commands.publish(.setDE(key: "mandelbox"))
        let reverted = h.step()
        #expect(reverted.deKey == "mandelbox")
        #expect(reverted.externalProgram == nil)

        // Re-activate, then clearing with nil reverts to the LAST built-in.
        h.commands.publish(.setExternalDE(program))
        _ = h.step()
        h.commands.publish(.setExternalDE(nil))
        let cleared = h.step()
        #expect(cleared.deKey == "mandelbox")
        #expect(cleared.externalProgram == nil)
    }

    @Test(.enabled(if: GPU.available))
    func externalDEParamsRegisterIntoTheArenaAndRecycle() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let source = ExternalDETests.sphereSource
        let embedded = EmbeddedDE(
            source: source, abiVersion: Int(THRESHOLD_ABI_VERSION),
            hash: ExternalDELoader.sourceHash(source),
            params: [EmbeddedDEParam(name: "radius", defaultValue: 1, min: 0.1, max: 2)])
        let program = try loader.load(embedded)

        var h = Harness()
        h.step()

        // Scene apply (embedded) + program activation — the exact command
        // pair InteractiveSession.applyScene(_:loader:) publishes. The scene
        // authors the param via the raw "de.external.<name>" convention.
        var scene = SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "external")
        scene.embeddedDE = embedded
        scene.params["de.external.radius"] = [1.5]
        h.commands.publish(.applyScene(scene, transition: nil))
        h.commands.publish(.setExternalDE(program))

        let frame = h.step()
        let entry = try #require(frame.dynamicEntries.first)
        #expect(frame.dynamicEntries.count == 1)
        #expect(h.layout.arenaRange.contains(entry.slot),
                "external params live in the dynamic arena")
        #expect(entry.spec.key == ParamKey.de(program.descriptor.key, "radius"))
        // The scene-authored value (not the declared default) reaches the
        // GPU slice at deParamOffset.
        #expect(frame.request.params[Int(frame.request.uniforms.meta.w)] == 1.5)

        // A user edit on the arena slot lands in the slice, clamped to the
        // declared range — same single-clamp-site behavior as built-ins. The
        // external DE param eases on the user lane (ADR-005: continuous feel),
        // so converge the drag before checking it settled at the clamp (2).
        h.commands.publish(.userEdit(slot: entry.slot, targetResolved: 5))
        var edited = h.step()
        for _ in 0..<240 { edited = h.step() }  // 4 s = 20τ past the 0.2 s user tau
        #expect(abs(edited.request.params[Int(edited.request.uniforms.meta.w)] - 2) < 1e-4)

        // Clearing the program recycles the arena…
        h.commands.publish(.setExternalDE(nil))
        let cleared = h.step()
        #expect(cleared.dynamicEntries.isEmpty)

        // …and re-activation starts clean: the declared default, no ghost
        // user edit or stale scene value from the recycled slot… except the
        // scene lane, which re-seeds from the STILL-CURRENT scene's params
        // (the scene remains applied). So: 1.5 again, but the user edit gone.
        h.commands.publish(.setExternalDE(program))
        let again = h.step()
        #expect(again.dynamicEntries.count == 1)
        #expect(again.request.params[Int(again.request.uniforms.meta.w)] == 1.5,
                "re-seeded from the current scene; the user edit must NOT survive recycling")
    }

    @Test func gestureLaneOrbitMovesTheCamera() {
        var h = Harness()
        let before = h.step()

        // Desktop orbit writes the gesture lane (plan §8.3) — through the
        // session's lane mailbox, like any input source.
        let yawSlot = h.slot(.cameraOrbitYaw)
        h.mailbox.publish(LaneWrite(lane: .gesture, slot: yawSlot, value: Float.pi))
        // Gesture smoothing is 0.15 s — step past it.
        for _ in 0..<120 { h.step() }
        let after = h.step()

        #expect(before.request.uniforms.camPosFov.z > 0, "starts at +Z")
        #expect(after.request.uniforms.camPosFov.z < 0,
                "π yaw orbits to the opposite side (z \(after.request.uniforms.camPosFov.z))")

        // Scene apply writes only the scene lane — the gesture orbit SURVIVES
        // (Invariant 11).
        h.commands.publish(.applyScene(
            SceneEnvelope(version: SceneCodec.currentVersion, fractalTypeKey: "mandelbox"),
            transition: nil))
        for _ in 0..<10 { h.step() }
        #expect(h.step().request.uniforms.camPosFov.z < 0)
    }

    @Test func captureSceneRoundTripsAuthoredContent() throws {
        var h = Harness()
        h.step()
        var scene = SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "mandelbox")
        scene.params[ParamKey.engineAOStrength.rawValue] = [1.25]
        scene.warpStack = [WarpOpDTO(kind: WK.twist, strength: 0.5,
                                     a: [0, 1, 0, 0], b: [0, 0, 0, 0])]
        scene.palette = Palette(stops: [
            GradientStop(position: 0, red: 1, green: 0, blue: 0),
            GradientStop(position: 1, red: 0, green: 0, blue: 1),
        ])
        h.commands.publish(.applyScene(scene, transition: nil))
        h.step()

        // Transient lanes must NOT persist (Invariant 3): add a user edit.
        h.commands.publish(.userEdit(slot: h.slot(.engineAOStrength), targetResolved: 0.1))
        h.step()

        let slot = SceneCaptureSlot()
        h.commands.publish(.captureScene(into: slot))
        h.step()
        let captured = try #require(slot.take())
        #expect(slot.take() == nil, "take() drains the slot")

        #expect(captured.fractalTypeKey == "mandelbox")
        #expect(captured.params[ParamKey.engineAOStrength.rawValue] == [1.25],
                "the AUTHORED value, not the user-edited resolve")
        #expect(captured.warpStack.count == 1 && captured.warpStack[0].kind == WK.twist)
        #expect(captured.palette?.stops.count == 2)
        #expect(captured.version == SceneCodec.currentVersion)

        // The capture re-applies cleanly (save → open round trip).
        let data = try SceneCodec.encode(captured)
        let reopened = try SceneCodec.decode(data)
        #expect(reopened.params[ParamKey.engineAOStrength.rawValue] == [1.25])
    }

    @Test func qualityGovernorDrivesResolutionOnlyAndNeverTouchesTheFractal() {
        var h = Harness()
        h.step()
        let maxStepsSlot = Int(THRESH_SLOT_MAX_STEPS)
        let iterationsSlot = Int(THRESH_SLOT_ITERATIONS)
        let authoredSteps = h.step().resolved.values[maxStepsSlot]
        let authoredIters = h.step().resolved.values[iterationsSlot]
        #expect(h.step().request.renderScale == 1, "no governor → native scale")

        // Enable and feed a blown budget: the RESOLUTION backs off…
        h.commands.publish(.setQualityGovernor(QualityGovernorConfig(
            targetMilliseconds: 8, minRenderScale: 0.5)))
        for _ in 0..<120 { h.step(gpuMilliseconds: 24) }
        let throttled = h.step()
        #expect(throttled.request.renderScale < 1,
                "sustained 3× overshoot must reduce resolution")
        #expect(throttled.request.renderScale >= 0.5, "never below the floor")

        // …and ONLY the resolution: the fractal's shape params stay authored
        // (the removed iterations/maxSteps lever visibly morphed the DE —
        // docs/perf-notes.md perf block 5).
        #expect(throttled.resolved.values[maxStepsSlot] == authoredSteps)
        #expect(throttled.resolved.values[iterationsSlot] == authoredIters)

        // Headroom: resolution creeps back up.
        for _ in 0..<600 { h.step(gpuMilliseconds: 2) }
        let recovered = h.step()
        #expect(recovered.request.renderScale > throttled.request.renderScale,
                "recovers with headroom")

        // Disabling returns to native resolution.
        h.commands.publish(.setQualityGovernor(nil))
        h.step()
        #expect(h.step().request.renderScale == 1)
    }

    @Test func renderQualityIsTheCeilingInBothGovernorModes() {
        var h = Harness()
        h.step()

        // Governor OFF: the Render Quality setting IS the scale.
        var tuning = RenderTuning.envDefault
        tuning.manualRenderScale = 0.7
        h.commands.publish(.setRenderTuning(tuning))
        h.step()
        #expect(abs(h.step().request.renderScale - 0.7) < 1e-5,
                "governor off → the quality setting is the exact scale")

        // Governor ON with headroom (fast frames): it would recover toward 1,
        // but the user's ceiling caps it (ADR-003 contract).
        h.commands.publish(.setQualityGovernor(QualityGovernorConfig(
            targetMilliseconds: 8, minRenderScale: 0.35)))
        for _ in 0..<300 { h.step(gpuMilliseconds: 2) }
        let capped = h.step()
        #expect(capped.request.renderScale <= 0.7 + 1e-5,
                "governor with headroom must not exceed the user ceiling")

        // Under load it still adapts BELOW the ceiling.
        for _ in 0..<120 { h.step(gpuMilliseconds: 24) }
        let throttled = h.step()
        #expect(throttled.request.renderScale < 0.7,
                "governor adapts below the ceiling under load")

        // Raising the ceiling back to 1 with headroom lets it recover past 0.7.
        tuning.manualRenderScale = 1
        h.commands.publish(.setRenderTuning(tuning))
        for _ in 0..<900 { h.step(gpuMilliseconds: 2) }
        #expect(h.step().request.renderScale > 0.7,
                "recovery is bounded only by the (raised) ceiling")
    }

    // MARK: Octave rebase (plan §6.3, infinite-zoom phase 2)

    @Test func octaveRebaseFoldsTheZoomPhaseAndRescalesTheCamera() {
        // A scene deep past the rebase threshold: zoom phase 8.5 with the
        // camera out at the matching world magnitude.
        var scene = SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "mandelbulb")
        scene.camera = CameraDTO(
            position: [0, 0, 768], orientation: [0, 0, 0, 1], fovYRadians: .pi / 3)
        scene.integratorPhases[ParamKey.scaleZoom.rawValue] = 8.5
        var h = Harness(scene: scene)

        let frame = h.step()
        #expect(frame.scaleOctave == 8, "integer octaves fold into the counter")
        let phase = frame.resolved.values[h.slot(.scaleZoom)]
        #expect(abs(phase - 0.5) < 1e-6, "fractional zoom remains as the phase")
        #expect(abs(frame.request.uniforms.camPosFov.z - 3) < 1e-4,
                "camera rescales by exactly 2⁻⁸ (768 → 3)")

        // The invariant that makes a rebase invisible: the model-space camera
        // (world position × modelScale) is unchanged by the fold.
        let modelZ = frame.request.uniforms.camPosFov.z * exp2(-phase)
        #expect(abs(modelZ - 768 * exp2(-8.5)) < 1e-6)

        // Steady state: within budget, no re-fire.
        let again = h.step()
        #expect(again.scaleOctave == 8)
        #expect(abs(again.request.uniforms.camPosFov.z - 3) < 1e-4)
    }

    @Test func sustainedZoomRebasesRepeatedlyAndKeepsThePhaseBounded() {
        var h = Harness()
        h.step()
        // Max zoom rate: 2 octaves/second into the integrator.
        h.commands.publish(.userEdit(slot: h.slot(.scaleZoomSpeed), targetResolved: 2))
        var last = h.step()
        for _ in 0..<900 {  // 15 s at 60 fps → ~30 octaves of travel
            last = h.step()
            let phase = last.resolved.values[h.slot(.scaleZoom)]
            #expect(phase < ScaleContext.rebaseThreshold + 0.1,
                    Comment(rawValue: "phase must stay within the float budget (got \(phase))"))
        }
        let depth = Float(last.scaleOctave) + last.resolved.values[h.slot(.scaleZoom)]
        #expect(last.scaleOctave >= 24, "deep zoom folded into the octave counter")
        #expect(abs(depth - 30) < 0.5,
                Comment(rawValue: "total depth ≈ rate × time across every rebase (got \(depth))"))
    }

    @Test func zoomOutNeverRebases() {
        var scene = SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "mandelbulb")
        scene.integratorPhases[ParamKey.scaleZoom.rawValue] = -20
        var h = Harness(scene: scene)
        let frame = h.step()
        #expect(frame.scaleOctave == 0)
        #expect(abs(frame.resolved.values[h.slot(.scaleZoom)] + 20) < 1e-5)
    }

    @Test func captureAfterRebaseRoundTripsTheZoomDepth() throws {
        var scene = SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "mandelbulb")
        scene.camera = CameraDTO(
            position: [0, 0, 768], orientation: [0, 0, 0, 1], fovYRadians: .pi / 3)
        scene.integratorPhases[ParamKey.scaleZoom.rawValue] = 8.5
        var h = Harness(scene: scene)
        h.step()

        let slot = SceneCaptureSlot()
        h.commands.publish(.captureScene(into: slot))
        h.step()
        let captured = try #require(slot.take())
        #expect(captured.scaleOctave == 8, "depth counter persists")
        let savedPhase = try #require(captured.integratorPhases[ParamKey.scaleZoom.rawValue])
        #expect(abs(savedPhase - 0.5) < 1e-5, "phase saved in the rebased frame")
        #expect(abs(captured.camera.position[2] - 3) < 1e-4,
                "camera saved in the rebased world — phase + camera alone reproduce the image")

        // Reopening restores the depth without re-firing a rebase.
        var h2 = Harness(scene: try SceneCodec.decode(SceneCodec.encode(captured)))
        let reopened = h2.step()
        #expect(reopened.scaleOctave == 8)
        #expect(abs(reopened.request.uniforms.camPosFov.z - 3) < 1e-4)
    }

    @Test func builtinSceneApplyClearsAnExternalProgram() throws {
        // CPU-only: command/descriptor bookkeeping (no GPU program needed for
        // the clear path — apply a builtin scene while external is nil).
        var h = Harness()
        h.step()
        h.commands.publish(.applyScene(
            SceneEnvelope(version: SceneCodec.currentVersion, fractalTypeKey: "mandelbox"),
            transition: nil))
        let frame = h.step()
        #expect(frame.deKey == "mandelbox")
        #expect(frame.externalProgram == nil)
    }
}
