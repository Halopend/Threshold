// TransienceTests.swift — music decay (plan §3.2), Invariant 3 (transient
// lanes never fold into base), gesture hold/clear.

import Testing
@testable import ThresholdCore

@Suite("Music transience & gesture hold")
struct TransienceTests {
    @Test("Music decays toward the additive neutral when not re-written")
    func musicDecaysAdditive() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [spec("t.a", default: 1, smoothing: Smoothing(music: 0.08))],
            clock: clock)
        let slot = firstContentSlot

        // Written this frame → smooths toward the target (ramping in from 0).
        engine.write(lane: .music, slot: slot, value: 1.0)
        clock.advance()
        let peak = engine.resolve().values[slot] - 1  // music contribution
        #expect(peak > 0)

        // Not re-written → decays monotonically toward 0.
        var previous = peak
        for _ in 0..<30 {
            clock.advance()
            let contribution = engine.resolve().values[slot] - 1
            #expect(contribution <= previous + 1e-6)
            #expect(contribution >= 0)
            previous = contribution
        }
        // 30 × 50 ms ≈ 19 time constants: fully decayed and cleared.
        #expect(abs(previous) < 1e-3)
        #expect(engine.currentValue(lane: .music, slot: slot) == nil)
    }

    @Test("Music decays toward the multiplicative neutral 1")
    func musicDecaysMultiplicative() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [spec("t.m", range: 0...100, default: 2, composition: .multiplicative,
                  smoothing: Smoothing(music: 0.08))],
            clock: clock)
        let slot = firstContentSlot

        engine.write(lane: .music, slot: slot, value: 3.0)
        clock.advance()
        _ = engine.resolve()

        for _ in 0..<40 {
            clock.advance()
            _ = engine.resolve()
        }
        // Decayed to neutral and cleared: resolved value is the base again.
        clock.advance()
        #expect(abs(engine.resolve().values[slot] - 2) < 1e-3)
        #expect(engine.currentValue(lane: .music, slot: slot) == nil)
    }

    @Test("Music re-written every frame holds; stopping the writes decays")
    func musicRewriteHolds() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [spec("t.a", default: 0, smoothing: Smoothing(music: 0.08))],
            clock: clock)
        let slot = firstContentSlot

        for _ in 0..<30 {
            engine.write(lane: .music, slot: slot, value: 0.5)
            clock.advance()
            _ = engine.resolve()
        }
        // Converged onto the binding's value.
        engine.write(lane: .music, slot: slot, value: 0.5)
        clock.advance()
        #expect(abs(engine.resolve().values[slot] - 0.5) < 1e-3)

        // Binding stops → decays away.
        for _ in 0..<40 {
            clock.advance()
            _ = engine.resolve()
        }
        clock.advance()
        #expect(abs(engine.resolve().values[slot]) < 1e-3)
    }

    @Test("Invariant 3: music writes never touch the scene lane")
    func musicNeverTouchesScene() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", default: 0)], clock: clock)
        let slot = firstContentSlot

        engine.applyScene(values: [ParamKey("t.a"): [4]])
        clock.advance()
        _ = engine.resolve()
        #expect(engine.currentValue(lane: .scene, slot: slot) == 4)

        for i in 0..<25 {
            engine.write(lane: .music, slot: slot, value: Float(i))
            clock.advance()
            _ = engine.resolve()
        }
        for _ in 0..<25 {  // and through the decay
            clock.advance()
            _ = engine.resolve()
        }
        // Scene lane is bit-for-bit untouched (recentering is a non-event).
        #expect(engine.currentValue(lane: .scene, slot: slot) == 4)
    }

    @Test("Invariant 11: applyScene writes only the scene lane, clears nothing")
    func applySceneOnlyScene() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", default: 0)], clock: clock)
        let slot = firstContentSlot

        engine.write(lane: .user, slot: slot, value: 2)
        engine.write(lane: .gesture, slot: slot, value: 3)
        clock.advance()
        _ = engine.resolve()

        engine.applyScene(values: [ParamKey("t.a"): [10], ParamKey("unknown.key"): [1]])
        clock.advance()
        let resolved = engine.resolve()

        // Scene applied; user & gesture offsets survived (10 + 2 + 3).
        #expect(resolved.values[slot] == 15)
        #expect(engine.currentValue(lane: .user, slot: slot) == 2)
        #expect(engine.currentValue(lane: .gesture, slot: slot) == 3)
        #expect(engine.currentValue(lane: .animation, slot: slot) == nil)
    }

    @Test("Gesture holds until cleared")
    func gestureHoldsUntilCleared() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", default: 1)], clock: clock)
        let slot = firstContentSlot

        engine.write(lane: .gesture, slot: slot, value: 0.5)
        // Many frames without re-writing: gesture must hold (unlike music).
        for _ in 0..<50 {
            clock.advance()
            _ = engine.resolve()
        }
        clock.advance()
        #expect(engine.resolve().values[slot] == 1.5)

        // clearLane is the binding-policy hook: momentary bindings clear.
        engine.clearLane(.gesture)
        clock.advance()
        #expect(engine.resolve().values[slot] == 1)
        #expect(engine.currentValue(lane: .gesture, slot: slot) == nil)
    }
}
