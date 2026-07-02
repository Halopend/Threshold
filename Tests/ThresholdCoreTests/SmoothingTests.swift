// SmoothingTests.swift — exponential smoothing convergence and pause
// semantics (plan §3.3; task spec: alpha = 1 - exp(-dt/tau), tau 0 = jump,
// dt == 0 / paused → frozen).

import Foundation
import Testing
@testable import ThresholdCore

@Suite("Smoothing & pause")
struct SmoothingTests {
    @Test("Smoothed lane follows alpha = 1 - exp(-dt/tau) exactly")
    func smoothingFormula() throws {
        let dt = 0.05
        let tau = 0.15
        let clock = FixedStepClock(step: dt)
        let engine = try makeEngine(
            [spec("t.a", default: 0, smoothing: Smoothing(gesture: tau))],
            clock: clock)
        let slot = 16

        engine.write(lane: .gesture, slot: slot, value: 1.0)
        var expected: Float = 0  // ramps in from the additive neutral
        let alpha = Float(1 - exp(-dt / tau))
        for _ in 0..<10 {
            clock.advance()
            expected += (1.0 - expected) * alpha
            let value = engine.resolve().values[slot]
            #expect(abs(value - expected) < 1e-5)
        }
    }

    @Test("Smoothing converges to the target")
    func convergence() throws {
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let engine = try makeEngine(
            [spec("t.a", default: 0, smoothing: Smoothing(gesture: 0.15))],
            clock: clock)
        let slot = 16

        engine.write(lane: .gesture, slot: slot, value: 2.0)
        for _ in 0..<180 {  // 3 s = 20 time constants
            clock.advance()
            _ = engine.resolve()
        }
        clock.advance()
        #expect(abs(engine.resolve().values[slot] - 2.0) < 1e-4)
    }

    @Test("tau == 0 jumps to the target in one resolve")
    func instantJump() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", default: 0)], clock: clock)
        engine.write(lane: .user, slot: 16, value: 3)
        clock.advance()
        #expect(engine.resolve().values[16] == 3)
    }

    @Test("Pause freezes mid-flight smoothing, music decay, and values")
    func pauseFreezes() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [spec("t.a", default: 0, smoothing: Smoothing(gesture: 0.15, music: 0.08))],
            clock: clock)
        let slot = 16

        // Get a gesture mid-smooth and a music value mid-decay.
        engine.write(lane: .gesture, slot: slot, value: 1.0)
        engine.write(lane: .music, slot: slot, value: 0.5)
        clock.advance()
        _ = engine.resolve()
        clock.advance()
        let beforePause = engine.resolve().values[slot]

        clock.paused = true
        for _ in 0..<10 {
            clock.advance()  // paused: delta == 0
            #expect(engine.resolve().values[slot] == beforePause)
        }

        // Unpause: motion resumes.
        clock.paused = false
        clock.advance()
        #expect(engine.resolve().values[slot] != beforePause)
    }

    @Test("dt == 0 freezes smoothing even when unpaused")
    func zeroDtFreezes() throws {
        let clock = FixedStepClock(step: 0)  // legal: zero-length steps
        let engine = try makeEngine(
            [spec("t.a", default: 0, smoothing: Smoothing(gesture: 0.15))],
            clock: clock)
        let slot = 16

        engine.write(lane: .gesture, slot: slot, value: 1.0)
        clock.advance()
        // alpha would be 1 - exp(0) = 0 → still at the ramp-in origin (0).
        #expect(engine.resolve().values[slot] == 0)
    }

    @Test("Instant lanes still respond to fresh writes while paused")
    func instantWriteDuringPause() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", default: 0)], clock: clock)
        clock.advance()
        _ = engine.resolve()

        clock.paused = true
        clock.advance()
        // The user's slider (tau 0) must work while time is paused.
        engine.write(lane: .user, slot: 16, value: 4)
        #expect(engine.resolve().values[16] == 4)
    }

    @Test("Default smoothing: user/scene/system/animation instant, gesture 0.15, music 0.08")
    func defaultSmoothing() {
        let smoothing = Smoothing.default
        #expect(smoothing.tau(for: .scene) == 0)
        #expect(smoothing.tau(for: .animation) == 0)
        #expect(smoothing.tau(for: .system) == 0)
        #expect(smoothing.tau(for: .user) == 0)
        #expect(smoothing.tau(for: .gesture) == 0.15)
        #expect(smoothing.tau(for: .music) == 0.08)
    }
}
