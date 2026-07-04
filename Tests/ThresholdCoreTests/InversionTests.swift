// InversionTests.swift — grab-what-you-see property tests
// (ARCHITECTURE.md §3: resolve(invert(x)) == clamp(x) for arbitrary lane
// states, including a nonzero system lane — ADR-003 action item 2).

import Testing
@testable import ThresholdCore

@Suite("Grab-what-you-see inversion")
struct InversionTests {
    @Test("Property: userLaneValue then resolve == clamp(target), 500 seeded configs")
    func inversionProperty() throws {
        var rng = SplitMix64(seed: 0xC0FF_EE00_DEAD_BEEF)
        let clock = FixedStepClock(step: 0.05)

        // One param per composition, all-instant smoothing (the user lane is
        // instant by default; the others are instant so lane currents equal
        // their targets after one resolve).
        let additiveRange: ClosedRange<Float> = -10...10
        let multiplicativeRange: ClosedRange<Float> = 0.01...50
        let replaceRange: ClosedRange<Float> = -5...5
        let engine = try makeEngine(
            [
                spec("t.add", range: additiveRange, default: 0.5, composition: .additive),
                spec("t.mul", range: multiplicativeRange, default: 1.5, composition: .multiplicative),
                spec("t.rep", range: replaceRange, default: 0, composition: .replace),
            ],
            clock: clock)

        for iteration in 0..<500 {
            let comp = [Composition.additive, .multiplicative, .replace][rng.int(in: 0...2)]
            let slot: Int
            switch comp {
            case .additive: slot = firstContentSlot
            case .multiplicative: slot = firstContentSlot + 1
            case .replace: slot = firstContentSlot + 2
            }

            // Fresh lane state per iteration.
            for lane in Lane.allCases { engine.clearLane(lane) }

            // Random subset of other lanes, random values. For .replace,
            // gesture/music must stay unset — they compose after user and
            // would replace it (documented contract of userLaneValue).
            var otherLanes: [Lane] = [.scene, .animation, .system]
            if comp != .replace { otherLanes += [.gesture, .music] }
            var musicValue: Float?
            for lane in otherLanes where rng.bool() {
                let value: Float
                switch comp {
                case .additive: value = rng.float(in: -3...3)
                case .multiplicative: value = rng.float(in: 0.2...2.5)  // away from ~0
                case .replace: value = rng.float(in: replaceRange)
                }
                engine.write(lane: lane, slot: slot, value: value)
                if lane == .music { musicValue = value }
            }

            // Settle currents (instant taus: one resolve).
            clock.advance()
            _ = engine.resolve()

            // Aim anywhere, including outside the range (must clamp).
            let target = rng.float(in: -60...60)
            let user = Inversion.userLaneValue(toAchieve: target, slot: slot, in: engine)
            engine.write(lane: .user, slot: slot, value: user)
            // A live music binding re-writes every frame; mimic it so decay
            // doesn't eat the music contribution between the two resolves.
            if let musicValue { engine.write(lane: .music, slot: slot, value: musicValue) }

            clock.advance()
            let resolved = engine.resolve().values[slot]
            let lo = comp == .additive ? additiveRange.lowerBound
                : comp == .multiplicative ? multiplicativeRange.lowerBound
                : replaceRange.lowerBound
            let hi = comp == .additive ? additiveRange.upperBound
                : comp == .multiplicative ? multiplicativeRange.upperBound
                : replaceRange.upperBound
            let expected = min(max(target, lo), hi)
            #expect(
                abs(resolved - expected) < 1e-4,
                "iteration \(iteration): comp=\(comp) target=\(target) user=\(user) resolved=\(resolved) expected=\(expected)")
        }
    }

    @Test("Multiplicative inversion guards division by ~0 and returns the neutral")
    func multiplicativeZeroGuard() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [spec("t.m", range: -10...10, default: 1, composition: .multiplicative)],
            clock: clock)
        let slot = firstContentSlot

        engine.write(lane: .scene, slot: slot, value: 0)  // base 0 → not invertible
        clock.advance()
        _ = engine.resolve()

        #expect(Inversion.userLaneValue(toAchieve: 5, slot: slot, in: engine) == 1)
    }

    @Test("Replace inversion is the clamped target itself")
    func replaceIsTarget() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [spec("t.r", range: 0...10, default: 2, composition: .replace)],
            clock: clock)
        #expect(Inversion.userLaneValue(toAchieve: 7, slot: firstContentSlot, in: engine) == 7)
        #expect(Inversion.userLaneValue(toAchieve: 25, slot: firstContentSlot, in: engine) == 10)  // clamped
    }

    @Test("Additive inversion accounts for a nonzero system lane (ADR-003)")
    func additiveWithSystemLane() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [spec("t.a", range: -10...10, default: 1, composition: .additive)],
            clock: clock)
        let slot = firstContentSlot

        engine.write(lane: .system, slot: slot, value: -0.5)
        clock.advance()
        _ = engine.resolve()

        let user = Inversion.userLaneValue(toAchieve: 3, slot: slot, in: engine)
        #expect(user == 3 - (1 - 0.5))  // target − (base + system)
        engine.write(lane: .user, slot: slot, value: user)
        clock.advance()
        #expect(abs(engine.resolve().values[slot] - 3) < 1e-5)
    }
}
