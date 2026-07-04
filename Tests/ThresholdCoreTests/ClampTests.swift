// ClampTests.swift — clamping happens in exactly one place: resolution
// (plan §2.2). Writes are stored unclamped.

import Testing
@testable import ThresholdCore

@Suite("Clamp semantics")
struct ClampTests {
    @Test("Resolution clamps to the param range")
    func resolutionClamps() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", range: 0...1, default: 0.5)], clock: clock)
        let slot = firstContentSlot

        engine.write(lane: .user, slot: slot, value: 100)
        clock.advance()
        #expect(engine.resolve().values[slot] == 1)

        engine.write(lane: .user, slot: slot, value: -100)
        clock.advance()
        #expect(engine.resolve().values[slot] == 0)
    }

    @Test("Writes outside the range are NOT rejected — lane storage is unclamped")
    func writesAreStoredUnclamped() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", range: 0...1, default: 0.5)], clock: clock)
        let slot = firstContentSlot

        // User pushes way out of range…
        engine.write(lane: .user, slot: slot, value: 5)
        clock.advance()
        #expect(engine.resolve().values[slot] == 1)  // clamped at resolve
        #expect(engine.currentValue(lane: .user, slot: slot) == 5)  // …but stored intact.

        // A music offset composes against the UNCLAMPED user value: if the
        // write had been clamped, 0.5 + 1 − 4.8 would give 0 (clamped from
        // -3.3); instead 0.5 + 5 − 4.8 = 0.7.
        engine.write(lane: .music, slot: slot, value: -4.8)
        clock.advance()
        let resolved = engine.resolve().values[slot]
        #expect(abs(resolved - 0.7) < 1e-5)
    }

    @Test("Vector params clamp per component")
    func vectorClampPerComponent() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [spec("t.v", range: 0...1, default: 0.5, kind: .float3)],
            clock: clock)

        #expect(engine.write(lane: .user, key: ParamKey("t.v"), values: [9, -9, 0.25]))
        clock.advance()
        let values = engine.resolve().values
        #expect(values[firstContentSlot] == 1)     // 0.5 + 9 clamped high
        #expect(values[firstContentSlot + 1] == 0)     // 0.5 − 9 clamped low
        #expect(values[firstContentSlot + 2] == 0.75)  // in range, untouched
    }

    @Test("Scene values are clamped at resolution too")
    func sceneClamps() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", range: 0...1, default: 0.5)], clock: clock)
        engine.applyScene(values: [ParamKey("t.a"): [42]])
        clock.advance()
        #expect(engine.resolve().values[firstContentSlot] == 1)
    }
}
