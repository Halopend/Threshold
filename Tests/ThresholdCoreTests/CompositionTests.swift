// CompositionTests.swift — lane order (Invariant 16) and Composition modes.

import Testing
@testable import ThresholdCore

@Suite("Lane order & composition")
struct CompositionTests {
    @Test("Lane raw values are the composition order, system between animation and user")
    func laneOrder() {
        #expect(Lane.scene.rawValue == 0)
        #expect(Lane.animation.rawValue == 1)
        #expect(Lane.system.rawValue == 2)
        #expect(Lane.user.rawValue == 3)
        #expect(Lane.gesture.rawValue == 4)
        #expect(Lane.music.rawValue == 5)
        #expect(Lane.allCases == [.scene, .animation, .system, .user, .gesture, .music])
        #expect(Lane.animation < Lane.system && Lane.system < Lane.user)
    }

    @Test("Unwritten param resolves to its catalog default")
    func defaultResolution() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeEngine([spec("t.a", default: 7)], clock: clock)
        clock.advance()
        #expect(engine.resolve().values[16] == 7)
    }

    @Test("Additive: set lanes sum on top of the scene-or-default base")
    func additive() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeEngine([spec("t.a", default: 0.5)], clock: clock)
        let slot = 16

        engine.write(lane: .scene, slot: slot, value: 1.0)
        engine.write(lane: .animation, slot: slot, value: 0.25)
        engine.write(lane: .system, slot: slot, value: 0.125)
        engine.write(lane: .user, slot: slot, value: 0.5)
        engine.write(lane: .gesture, slot: slot, value: 0.0625)
        engine.write(lane: .music, slot: slot, value: 0.03125)
        clock.advance()
        let resolved = engine.resolve()
        #expect(resolved.values[slot] == 1.0 + 0.25 + 0.125 + 0.5 + 0.0625 + 0.03125)
        #expect(resolved.generation == 1)

        // Unset lanes contribute the additive neutral 0: only user set.
        let engine2 = try makeEngine([spec("t.a", default: 0.5)], clock: clock)
        engine2.write(lane: .user, slot: slot, value: 2)
        clock.advance()
        #expect(engine2.resolve().values[slot] == 2.5)  // default 0.5 + user 2
    }

    @Test("Multiplicative: set lanes multiply; unset lanes are neutral 1")
    func multiplicative() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeEngine(
            [spec("t.m", range: 0...1000, default: 2, composition: .multiplicative)],
            clock: clock)
        let slot = 16

        // Only user set: default 2 × 3 = 6 (every other lane neutral).
        engine.write(lane: .user, slot: slot, value: 3)
        clock.advance()
        #expect(engine.resolve().values[slot] == 6)

        // Scene replaces the base; system scales it (ADR-003 governor shape).
        engine.write(lane: .scene, slot: slot, value: 4)
        engine.write(lane: .system, slot: slot, value: 0.5)
        clock.advance()
        #expect(engine.resolve().values[slot] == 4 * 0.5 * 3)

        // Clearing a lane restores its neutral contribution.
        engine.clearLane(.system, slot: slot)
        clock.advance()
        #expect(engine.resolve().values[slot] == 4 * 3)
    }

    @Test("Multiplicative neutral: writing 1 is indistinguishable from unset")
    func multiplicativeNeutral() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeEngine(
            [spec("t.m", range: 0...1000, default: 5, composition: .multiplicative)],
            clock: clock)
        let slot = 16
        engine.write(lane: .gesture, slot: slot, value: 1)
        clock.advance()
        #expect(engine.resolve().values[slot] == 5)
    }

    @Test("Replace: later lanes win, in exact Lane order")
    func replaceOrder() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeEngine(
            [spec("t.r", range: 0...100, default: 1, composition: .replace)],
            clock: clock)
        let slot = 16

        engine.write(lane: .animation, slot: slot, value: 10)
        clock.advance()
        #expect(engine.resolve().values[slot] == 10)

        // system beats animation…
        engine.write(lane: .system, slot: slot, value: 20)
        clock.advance()
        #expect(engine.resolve().values[slot] == 20)

        // …user beats system…
        engine.write(lane: .user, slot: slot, value: 30)
        clock.advance()
        #expect(engine.resolve().values[slot] == 30)

        // …gesture beats user…
        engine.write(lane: .gesture, slot: slot, value: 40)
        clock.advance()
        #expect(engine.resolve().values[slot] == 40)

        // …music beats gesture while re-written each frame.
        engine.write(lane: .music, slot: slot, value: 50)
        clock.advance()
        #expect(engine.resolve().values[slot] == 50)

        // Replace-composition music has no numeric neutral: not re-written →
        // it clears, exposing gesture again.
        clock.advance()
        #expect(engine.resolve().values[slot] == 40)
    }

    @Test("Vector params compose per component slot")
    func vectorComposition() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeEngine(
            [spec("t.v", range: -10...10, default: 1, kind: .float3)],
            clock: clock)
        // Slots 16, 17, 18.
        #expect(engine.write(lane: .user, key: ParamKey("t.v"), values: [1, 2, 3]))
        clock.advance()
        let values = engine.resolve().values
        #expect(values[16] == 2 && values[17] == 3 && values[18] == 4)  // default 1 + write
    }

    @Test("Generation increments monotonically")
    func generation() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeEngine([spec("t.a")], clock: clock)
        clock.advance()
        #expect(engine.resolve().generation == 1)
        #expect(engine.resolve().generation == 2)
        #expect(engine.resolve().generation == 3)
    }
}
