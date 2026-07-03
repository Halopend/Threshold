// MirrorTests.swift — ParameterMirror: epsilon diffing, command routing, and
// fps-estimate math. All time is synthetic snapshot time; refresh() is driven
// manually (no timers in tests).

import Testing
@testable import ThresholdCore
import ThresholdRender
@testable import ThresholdUI

@MainActor
@Suite("ParameterMirror diffing")
struct MirrorDiffingTests {
    @Test("resolvedValues seed from catalog defaults before any snapshot")
    func seededDefaults() {
        let (mirror, _, _) = makeMirror()
        let layout = mirror.layout
        #expect(mirror.resolvedValues.count == layout.slotCount)
        #expect(mirror.resolvedValues[layout.slot(for: ParamKey("test.alpha"))!] == 0.5)
        let tint = layout.slot(for: ParamKey("test.tint"))!
        #expect(mirror.resolvedValues[tint..<(tint + 3)] == [0.1, 0.2, 0.3])
    }

    @Test("refresh with no snapshot is a no-op")
    func noSnapshot() {
        let (mirror, _, _) = makeMirror()
        mirror.refresh()
        #expect(mirror.refreshGeneration == 0)
    }

    @Test("Same snapshot twice → exactly one observable change event")
    func sameSnapshotTwice() {
        let (mirror, snapshots, _) = makeMirror()
        let values = [Float](repeating: 0.25, count: mirror.layout.slotCount)
        snapshots.publish(makeSnapshot(values: values, frameIndex: 1, time: 0.016))

        mirror.refresh()
        #expect(mirror.refreshGeneration == 1)
        #expect(mirror.resolvedValues == values)

        mirror.refresh()  // identical snapshot again
        #expect(mirror.refreshGeneration == 1)
    }

    @Test("Value changes below epsilon do not mutate observable state")
    func subEpsilonChange() {
        let (mirror, snapshots, _) = makeMirror()
        let values = [Float](repeating: 0.25, count: mirror.layout.slotCount)
        snapshots.publish(makeSnapshot(values: values))
        mirror.refresh()
        let generation = mirror.refreshGeneration

        // New snapshot object, same frame/time, values nudged by 5e-6 < 1e-5.
        snapshots.publish(makeSnapshot(values: values.map { $0 + 5e-6 }))
        mirror.refresh()

        #expect(mirror.refreshGeneration == generation)
        #expect(mirror.resolvedValues == values)  // kept the OLD array
    }

    @Test("Value changes beyond epsilon are applied")
    func beyondEpsilonChange() {
        let (mirror, snapshots, _) = makeMirror()
        var values = [Float](repeating: 0.25, count: mirror.layout.slotCount)
        snapshots.publish(makeSnapshot(values: values))
        mirror.refresh()
        let generation = mirror.refreshGeneration

        values[16] = 0.75
        snapshots.publish(makeSnapshot(values: values))
        mirror.refresh()

        #expect(mirror.refreshGeneration == generation + 1)
        #expect(mirror.resolvedValues[16] == 0.75)
    }

    @Test("deKey / warpStack / paused changes are applied")
    func structuralEcho() {
        let (mirror, snapshots, _) = makeMirror()
        let values = [Float](repeating: 0, count: mirror.layout.slotCount)
        let stack = [dto(kind: 1, strength: 1), dto(kind: 5, strength: 0.5)]
        snapshots.publish(makeSnapshot(
            values: values, deKey: "mandelbulb", warpStack: stack, paused: true))

        mirror.refresh()

        #expect(mirror.deKey == "mandelbulb")
        #expect(mirror.warpStack == stack)
        #expect(mirror.paused)
    }

    @Test("displayValue prefers the in-flight edit echo, then resolved, then 0")
    func displayValuePriority() {
        let (mirror, snapshots, _) = makeMirror()
        var values = [Float](repeating: 0, count: mirror.layout.slotCount)
        values[16] = 0.4
        snapshots.publish(makeSnapshot(values: values))
        mirror.refresh()

        #expect(mirror.displayValue(slot: 16) == 0.4)
        #expect(mirror.displayValue(slot: 9999) == 0)  // out of range

        mirror.beginEdit(slot: 16)
        mirror.updateEdit(slot: 16, target: 0.9)
        #expect(mirror.displayValue(slot: 16) == 0.9)  // local echo wins

        mirror.endEdit(slot: 16)
        #expect(mirror.displayValue(slot: 16) == 0.4)  // falls back to snapshot
    }
}

@MainActor
@Suite("ParameterMirror command routing")
struct MirrorCommandTests {
    @Test("updateEdit publishes exactly one userEdit with slot and target")
    func updateEditRouting() {
        let (mirror, _, commands) = makeMirror()

        mirror.updateEdit(slot: 17, target: 0.42)

        let drained = commands.drain()
        #expect(drained.count == 1)
        guard case .userEdit(let slot, let target) = drained.first else {
            Issue.record("expected .userEdit, got \(String(describing: drained.first))")
            return
        }
        #expect(slot == 17)
        #expect(target == 0.42)
    }

    @Test("beginEdit publishes nothing; endEdit publishes one clearUserEdit")
    func editBracketRouting() {
        let (mirror, _, commands) = makeMirror()

        mirror.beginEdit(slot: 17)
        #expect(commands.drain().isEmpty)

        mirror.endEdit(slot: 17)
        let drained = commands.drain()
        #expect(drained.count == 1)
        guard case .clearUserEdit(let slot) = drained.first else {
            Issue.record("expected .clearUserEdit, got \(String(describing: drained.first))")
            return
        }
        #expect(slot == 17)
    }

    @Test("A drag is userEdit* then clearUserEdit, in order")
    func dragSequence() {
        let (mirror, _, commands) = makeMirror()

        mirror.beginEdit(slot: 16)
        mirror.updateEdit(slot: 16, target: 0.1)
        mirror.updateEdit(slot: 16, target: 0.2)
        mirror.endEdit(slot: 16)

        let drained = commands.drain()
        #expect(drained.count == 3)
        guard drained.count == 3,
              case .userEdit(16, 0.1) = drained[0],
              case .userEdit(16, 0.2) = drained[1],
              case .clearUserEdit(16) = drained[2]
        else {
            Issue.record("unexpected drag sequence: \(drained)")
            return
        }
    }

    @Test("setWarpStack publishes the stack and echoes it locally")
    func setWarpStackRouting() {
        let (mirror, _, commands) = makeMirror()
        let stack = [dto(kind: 4, strength: 1)]

        mirror.setWarpStack(stack)

        #expect(mirror.warpStack == stack)
        let drained = commands.drain()
        #expect(drained.count == 1)
        guard case .setWarpStack(let sent) = drained.first else {
            Issue.record("expected .setWarpStack, got \(String(describing: drained.first))")
            return
        }
        #expect(sent == stack)
    }

    @Test("setDE / setPaused / setBindings / applyScene route to their commands")
    func structuralRouting() {
        let (mirror, _, commands) = makeMirror()
        let binding = ThresholdCore.Binding(
            signal: .audioRMS, param: ParamKey("test.alpha"), lane: .music)
        let scene = SceneEnvelope(version: 1, fractalTypeKey: "mandelbulb")

        mirror.setDE(key: "mandelbulb")
        mirror.setPaused(true)
        mirror.setBindings([binding])
        mirror.applyScene(scene)

        #expect(mirror.deKey == "mandelbulb")
        #expect(mirror.paused)

        let drained = commands.drain()
        #expect(drained.count == 4)
        guard drained.count == 4 else { return }
        guard case .setDE("mandelbulb") = drained[0] else {
            Issue.record("expected .setDE, got \(drained[0])")
            return
        }
        guard case .setPaused(true) = drained[1] else {
            Issue.record("expected .setPaused, got \(drained[1])")
            return
        }
        guard case .setBindings(let bindings) = drained[2], bindings == [binding] else {
            Issue.record("expected .setBindings, got \(drained[2])")
            return
        }
        guard case .applyScene(let sent) = drained[3], sent == scene else {
            Issue.record("expected .applyScene, got \(drained[3])")
            return
        }
    }

    @Test("animation state mirrors from snapshots; transport routes commands")
    func animationMirrorAndTransport() {
        let (mirror, snapshots, commands) = makeMirror()
        #expect(mirror.animation == .idle)

        let playing = AnimationPlaybackState(
            hasClip: true, clipName: "spin", time: 1.5, duration: 4,
            isPlaying: true, isFinished: false)
        snapshots.publish(makeSnapshot(
            values: [Float](repeating: 0, count: mirror.layout.slotCount),
            animation: playing))
        mirror.refresh()
        #expect(mirror.animation == playing)

        let clip = AnimationClip(name: "spin", loop: .once, duration: 4, tracks: [])
        mirror.setAnimationClip(clip)
        mirror.animationTransport(.play)
        mirror.animationTransport(.seek(2))
        mirror.setAnimationClip(nil)
        let drained = commands.drain()
        try? #require(drained.count == 4)
        guard case .setAnimationClip(let sent) = drained[0], sent?.name == "spin",
              case .animationTransport(.play) = drained[1],
              case .animationTransport(.seek(2)) = drained[2],
              case .setAnimationClip(nil) = drained[3] else {
            Issue.record("unexpected command sequence: \(drained)")
            return
        }
    }

    @Test("refresh publishes no commands (readback is one-way)")
    func refreshPublishesNothing() {
        let (mirror, snapshots, commands) = makeMirror()
        snapshots.publish(makeSnapshot(
            values: [Float](repeating: 1, count: mirror.layout.slotCount)))
        mirror.refresh()
        #expect(commands.drain().isEmpty)
    }
}

@MainActor
@Suite("ParameterMirror fps estimate")
struct MirrorStatsTests {
    @Test("fps is Δframes / Δtime between distinct snapshots")
    func fpsMath() {
        let (mirror, snapshots, _) = makeMirror()
        let values = [Float](repeating: 0, count: mirror.layout.slotCount)

        snapshots.publish(makeSnapshot(values: values, frameIndex: 0, time: 0))
        mirror.refresh()
        #expect(mirror.stats.fps == 0)  // no baseline yet

        snapshots.publish(makeSnapshot(values: values, frameIndex: 60, time: 1.0))
        mirror.refresh()
        #expect(abs(mirror.stats.fps - 60) <= 1e-9)

        snapshots.publish(makeSnapshot(values: values, frameIndex: 90, time: 1.25))
        mirror.refresh()
        #expect(abs(mirror.stats.fps - 120) <= 1e-9)
    }

    @Test("fps baseline does not advance on repeated identical snapshots")
    func fpsBaselineStable() {
        let (mirror, snapshots, _) = makeMirror()
        let values = [Float](repeating: 0, count: mirror.layout.slotCount)

        snapshots.publish(makeSnapshot(values: values, frameIndex: 0, time: 0))
        mirror.refresh()
        mirror.refresh()  // same snapshot polled again
        mirror.refresh()

        snapshots.publish(makeSnapshot(values: values, frameIndex: 30, time: 0.5))
        mirror.refresh()
        #expect(abs(mirror.stats.fps - 60) <= 1e-9)  // Δ from the FIRST sample
    }

    @Test("Time advancing with no new frame reads as 0 fps")
    func stalledFrames() {
        let (mirror, snapshots, _) = makeMirror()
        let values = [Float](repeating: 0, count: mirror.layout.slotCount)

        snapshots.publish(makeSnapshot(values: values, frameIndex: 10, time: 1.0))
        mirror.refresh()
        snapshots.publish(makeSnapshot(values: values, frameIndex: 20, time: 1.1))
        mirror.refresh()
        #expect(mirror.stats.fps > 0)

        snapshots.publish(makeSnapshot(values: values, frameIndex: 20, time: 2.0, paused: true))
        mirror.refresh()
        #expect(mirror.stats.fps == 0)
        #expect(mirror.paused)
    }

    @Test("gpuMilliseconds and totalSteps mirror the snapshot")
    func gpuStats() {
        let (mirror, snapshots, _) = makeMirror()
        let values = [Float](repeating: 0, count: mirror.layout.slotCount)
        snapshots.publish(makeSnapshot(
            values: values, frameIndex: 3, time: 0.05,
            gpuMilliseconds: 4.2, totalSteps: 123_456))
        mirror.refresh()
        #expect(abs(mirror.stats.gpuMilliseconds - 4.2) <= 1e-9)
        #expect(mirror.stats.totalSteps == 123_456)
    }
}
