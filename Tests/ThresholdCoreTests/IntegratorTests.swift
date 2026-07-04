// IntegratorTests.swift — time-integrated phase params (ARCHITECTURE.md §3
// "Stateful params", Invariant 17): phase += rate × dt × timeScale, wrapped
// into the phase param's range; frozen while paused.

import Testing
@testable import ThresholdCore

@Suite("Integrator phases")
struct IntegratorTests {
    private func makeHueEngine(
        clock: FixedStepClock,
        rateDefault: Float = 1
    ) throws -> ModulationEngine {
        try makeEngine(
            [
                spec("color.hueRate", range: -10...10, default: rateDefault),
                spec("color.huePhase", range: 0...1, default: 0,
                     integratorRateKey: ParamKey("color.hueRate")),
            ],
            clock: clock)
    }

    @Test("Phase accumulates rate × dt")
    func phaseAccumulates() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeHueEngine(clock: clock)
        let phaseSlot = firstContentSlot + 1

        for frame in 1...5 {
            clock.advance()
            let resolved = engine.resolve().values[phaseSlot]
            #expect(abs(resolved - Float(frame) * 0.1) < 1e-5)
        }
        #expect(abs(engine.readIntegratorPhase(slot: phaseSlot)! - 0.5) < 1e-5)
    }

    @Test("The rate is an ordinary lane-resolved param")
    func rateIsLaneResolved() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeHueEngine(clock: clock)
        // Music doubles the rate additively: rate = 1 + 1 = 2.
        engine.write(lane: .music, slot: firstContentSlot, value: 1)
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot + 1] - 0.2) < 1e-5)
    }

    @Test("Phase wraps into the param's range")
    func phaseWraps() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeHueEngine(clock: clock, rateDefault: 4)
        let phaseSlot = firstContentSlot + 1

        // 0.4 per frame: 0.4, 0.8, 1.2→0.2, 0.6, 1.0→0.0, …
        var expected: Float = 0
        for _ in 0..<10 {
            clock.advance()
            expected = (expected + 0.4).truncatingRemainder(dividingBy: 1)
            let value = engine.resolve().values[phaseSlot]
            #expect(abs(value - expected) < 1e-4)
            #expect(value >= 0 && value < 1 + 1e-6)
        }
    }

    @Test("Negative rates wrap correctly below the lower bound")
    func negativeRateWraps() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeHueEngine(clock: clock, rateDefault: -3)
        clock.advance()
        // 0 − 0.3 wraps to 0.7.
        #expect(abs(engine.resolve().values[firstContentSlot + 1] - 0.7) < 1e-5)
    }

    @Test("Paused clock freezes the phase")
    func pauseFreezesPhase() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeHueEngine(clock: clock)
        let phaseSlot = firstContentSlot + 1

        clock.advance()
        _ = engine.resolve()
        clock.paused = true
        for _ in 0..<5 {
            clock.advance()
            #expect(abs(engine.resolve().values[phaseSlot] - 0.1) < 1e-5)
        }
        clock.paused = false
        clock.advance()
        #expect(abs(engine.resolve().values[phaseSlot] - 0.2) < 1e-5)
    }

    @Test("timeScale scales phase advance but not smoothing")
    func timeScale() throws {
        let clock = FixedStepClock(step: 0.1, timeScale: 2)
        let engine = try makeHueEngine(clock: clock)
        clock.advance()
        // phase += rate × dt × timeScale = 1 × 0.1 × 2.
        #expect(abs(engine.resolve().values[firstContentSlot + 1] - 0.2) < 1e-5)
    }

    @Test("setIntegratorPhase/readIntegratorPhase round-trip with wrapping")
    func phaseSnapshotting() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeHueEngine(clock: clock)
        let phaseSlot = firstContentSlot + 1

        engine.setIntegratorPhase(slot: phaseSlot, value: 0.25)
        #expect(engine.readIntegratorPhase(slot: phaseSlot) == 0.25)

        engine.setIntegratorPhase(slot: phaseSlot, value: 3.75)  // wraps into [0,1)
        #expect(abs(engine.readIntegratorPhase(slot: phaseSlot)! - 0.75) < 1e-5)

        // Non-integrator slots: read is nil, set is a no-op.
        #expect(engine.readIntegratorPhase(slot: firstContentSlot) == nil)
        engine.setIntegratorPhase(slot: firstContentSlot, value: 1)
        #expect(engine.readIntegratorPhase(slot: firstContentSlot) == nil)

        // The restored phase is where integration resumes.
        engine.setIntegratorPhase(slot: phaseSlot, value: 0.5)
        clock.advance()
        #expect(abs(engine.resolve().values[phaseSlot] - 0.6) < 1e-5)
    }

    @Test("Integrator output ignores lane writes to the phase slot")
    func phaseSlotOwnedByEngine() throws {
        let clock = FixedStepClock(step: 0.1)
        let engine = try makeHueEngine(clock: clock)
        engine.write(lane: .user, slot: firstContentSlot + 1, value: 0.9)  // engine owns the phase
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot + 1] - 0.1) < 1e-5)
    }
}
