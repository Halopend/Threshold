// SceneTransitionTests.swift — the ADR-005 scene-transition window and the
// continuous-smoothing / graceful-release additions to ModulationEngine.
//
// Everything here drives the engine directly with a FixedStepClock, so the
// exponential (alpha = 1 - exp(-dt/tau)) is deterministic. Content slots are
// anchored on `firstContentSlot` (TestSupport) so they track reserved-count.

import Foundation
import Testing
@testable import ThresholdCore

@Suite("Scene transitions & continuous smoothing (ADR-005)")
struct SceneTransitionTests {
    private let s0 = firstContentSlot

    // MARK: Continuous smoothing / kind handling

    @Test("A continuous user edit eases in and converges to the target")
    func continuousUserEases() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let engine = try makeEngine(
            [spec("t.a", default: 0, composition: .additive, smoothing: .continuous)],
            clock: clock)

        engine.write(lane: .user, slot: s0, value: 4)
        clock.advance()
        let firstFrame = engine.resolve().values[s0]
        #expect(firstFrame > 0 && firstFrame < 4,
                "one 1/60 s step at tau 0.2 moves a fraction of the way, got \(firstFrame)")

        for _ in 0..<300 { clock.advance(); _ = engine.resolve() }  // 5 s = 25 tau
        clock.advance()
        #expect(abs(engine.resolve().values[s0] - 4) < 1e-4)
    }

    @Test("Enum/bool KINDS are forced instant even with a continuous spec")
    func discreteKindsNeverEase() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let engine = try makeEngine(
            [spec("t.enum", range: 0...3, default: 0, composition: .replace,
                  smoothing: .continuous, kind: .enumeration(caseCount: 4)),
             spec("t.flag", range: 0...1, default: 0, composition: .replace,
                   smoothing: .continuous, kind: .bool)],
            clock: clock)

        engine.write(lane: .user, slot: s0, value: 3)      // enum
        engine.write(lane: .user, slot: s0 + 1, value: 1)  // bool
        clock.advance()
        let v = engine.resolve().values
        #expect(v[s0] == 3, "enum index must jump, not sweep through 1,2")
        #expect(v[s0 + 1] == 1, "bool must jump")
    }

    // MARK: Graceful release

    @Test("releaseLane glides a gesture value to neutral, then clears")
    func releaseGlides() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let engine = try makeEngine(
            [spec("t.a", default: 0, composition: .additive,
                  smoothing: Smoothing(gesture: 0.15))],
            clock: clock)

        engine.write(lane: .gesture, slot: s0, value: 2)
        for _ in 0..<120 { clock.advance(); _ = engine.resolve() }  // settle in
        #expect(abs((engine.currentValue(lane: .gesture, slot: s0) ?? 0) - 2) < 1e-3)

        engine.releaseLane(.gesture, slot: s0)
        clock.advance()
        _ = engine.resolve()  // the release pass runs inside resolve()
        let midGlide = engine.currentValue(lane: .gesture, slot: s0)
        #expect(midGlide != nil && abs(midGlide! - 2) > 1e-4 && abs(midGlide!) > 1e-4,
                "one frame into release it is between its value and neutral, got \(midGlide as Any)")

        for _ in 0..<240 { clock.advance(); _ = engine.resolve() }  // 4 s = 26 tau
        #expect(engine.currentValue(lane: .gesture, slot: s0) == nil,
                "release clears the slot once it reaches neutral")
    }

    @Test("releaseLane on a tau-0 (instant) spec clears immediately")
    func releaseInstantForZeroTau() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let engine = try makeEngine([spec("t.a", default: 0)], clock: clock)  // .instant
        engine.write(lane: .gesture, slot: s0, value: 2)
        clock.advance(); _ = engine.resolve()
        engine.releaseLane(.gesture, slot: s0)
        #expect(engine.currentValue(lane: .gesture, slot: s0) == nil,
                "no tau to glide through → immediate clear")
    }

    // MARK: Scene transition window

    /// A tweenable scene param eases from its current base toward the new scene
    /// value and lands EXACTLY when the window closes.
    @Test("Scene transition eases a continuous scene param and lands exactly")
    func transitionEasesAndLands() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let engine = try makeEngine(
            [spec("t.a", default: 0, composition: .replace, smoothing: .continuous)],
            clock: clock)

        // Establish a base (snap) so the tween has somewhere to ease FROM.
        engine.snapWrite(lane: .scene, slot: s0, value: 1)
        clock.advance()
        #expect(engine.resolve().values[s0] == 1)

        // Open a 0.5 s transition, then write the new scene value (non-snap).
        engine.beginSceneTransition(duration: 0.5)
        engine.write(lane: .scene, slot: s0, value: 5)

        clock.advance()
        let early = engine.resolve().values[s0]
        #expect(early > 1 && early < 5, "eases from 1 toward 5, got \(early)")

        // Step to just before the window closes: ~98% there, not yet exact.
        for _ in 0..<28 { clock.advance(); _ = engine.resolve() }  // ~0.48 s
        #expect(engine.sceneTransitionActive, "still mid-transition")

        // Cross the deadline: lands EXACTLY on 5 and the window closes.
        for _ in 0..<3 { clock.advance(); _ = engine.resolve() }
        #expect(!engine.sceneTransitionActive)
        #expect(engine.resolve().values[s0] == 5, "exact landing, not ~4.9")
    }

    @Test("snapOnSceneTransition params snap even inside a transition window")
    func snapFlagIgnoresTransition() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let engine = try makeEngine(
            [spec("t.q", range: 0...256, default: 0, composition: .replace,
                  smoothing: .continuous).snapping()],
            clock: clock)

        engine.snapWrite(lane: .scene, slot: s0, value: 10)
        clock.advance(); _ = engine.resolve()

        engine.beginSceneTransition(duration: 0.5)
        engine.write(lane: .scene, slot: s0, value: 200)
        clock.advance()
        #expect(engine.resolve().values[s0] == 200,
                "a snapOnSceneTransition param jumps, never sweeps")
    }

    @Test("Non-transition apply snaps (transition: nil is byte-identical)")
    func nilTransitionSnaps() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let layout = { () -> CatalogLayout in
            let c = Catalog()
            try! c.register(spec("t.a", default: 0, composition: .replace, smoothing: .continuous))
            return c.freeze()
        }()
        let engine = ModulationEngine(layout: layout, clock: clock)

        SceneCodec.apply(
            SceneEnvelope(version: SceneCodec.currentVersion, fractalTypeKey: "x",
                          params: ["t.a": [7]]),
            layout: layout, engine: engine, transition: nil)
        clock.advance()
        #expect(engine.resolve().values[s0] == 7, "snap apply lands in one resolve")
    }

    // MARK: Authoritative clear ramps to default

    @Test("A param the new scene omits ramps to default during a transition")
    func omittedParamRampsToDefault() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let layout = { () -> CatalogLayout in
            let c = Catalog()
            try! c.register(spec("t.a", default: 2, composition: .replace, smoothing: .continuous))
            return c.freeze()
        }()
        let engine = ModulationEngine(layout: layout, clock: clock)

        // Scene A sets t.a = 8 (snap).
        SceneCodec.apply(
            SceneEnvelope(version: SceneCodec.currentVersion, fractalTypeKey: "x",
                          params: ["t.a": [8]]),
            layout: layout, engine: engine, transition: nil)
        clock.advance()
        #expect(engine.resolve().values[s0] == 8)

        // Scene B omits t.a → authoritative apply ramps it toward the default (2).
        SceneCodec.apply(
            SceneEnvelope(version: SceneCodec.currentVersion, fractalTypeKey: "x", params: [:]),
            layout: layout, engine: engine, transition: SceneTransition(duration: 0.5))
        clock.advance()
        let mid = engine.resolve().values[s0]
        #expect(mid < 8 && mid > 2, "eases from 8 toward the default 2, got \(mid)")

        for _ in 0..<40 { clock.advance(); _ = engine.resolve() }
        #expect(!engine.sceneTransitionActive)
        #expect(engine.resolve().values[s0] == 2, "lands on the catalog default")
    }

    // MARK: Pause freezes a transition mid-flight

    @Test("Pause freezes a scene transition; unpause resumes it")
    func pauseFreezesTransition() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let engine = try makeEngine(
            [spec("t.a", default: 0, composition: .replace, smoothing: .continuous)],
            clock: clock)
        engine.snapWrite(lane: .scene, slot: s0, value: 1)
        clock.advance(); _ = engine.resolve()

        engine.beginSceneTransition(duration: 0.5)
        engine.write(lane: .scene, slot: s0, value: 5)
        clock.advance(); _ = engine.resolve()
        let held = engine.resolve().values[s0]

        clock.paused = true
        for _ in 0..<20 {
            clock.advance()
            #expect(engine.resolve().values[s0] == held, "frozen while paused")
        }
        #expect(engine.sceneTransitionActive, "the window does not advance while paused")

        clock.paused = false
        clock.advance()
        #expect(engine.resolve().values[s0] != held, "motion resumes on unpause")
    }
}

// MARK: - Test helpers

private extension ParamSpec {
    /// Return a copy that snaps during scene transitions (ADR-005).
    func snapping() -> ParamSpec {
        ParamSpec(
            key: key, label: label, kind: kind, range: range, defaultValue: defaultValue,
            curve: curve, composition: composition, smoothing: smoothing,
            persistence: persistence,
            capabilities: capabilities.union(.snapOnSceneTransition),
            group: group, integratorRateKey: integratorRateKey)
    }
}
