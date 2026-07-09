// CoreTests.swift — clocks (Invariant 9) and the small value vocabulary.

import Foundation
import Testing
@testable import ThresholdCore

@Suite("Clocks")
struct ClockTests {
    @Test("FixedStepClock advances deterministically")
    func fixedStep() {
        let clock = FixedStepClock(step: 0.25, startingAt: 1)
        #expect(clock.now == 1 && clock.delta == 0)
        clock.advance()
        #expect(clock.now == 1.25 && clock.delta == 0.25)
        clock.advance(frames: 3)
        #expect(clock.now == 2.0 && clock.delta == 0.25)
    }

    @Test("FixedStepClock pause freezes now and zeroes delta")
    func fixedStepPause() {
        let clock = FixedStepClock(step: 0.5)
        clock.advance()
        clock.paused = true
        clock.advance()
        #expect(clock.now == 0.5 && clock.delta == 0)
        clock.paused = false
        clock.advance()
        #expect(clock.now == 1.0 && clock.delta == 0.5)
    }

    @Test("WallClock is fed timestamps and accumulates app time")
    func wallClock() {
        let clock = WallClock()
        clock.update(now: 100.0)  // baseline
        #expect(clock.delta == 0 && clock.now == 0)
        clock.update(now: 100.1)
        #expect(abs(clock.delta - 0.1) < 1e-12)
        #expect(abs(clock.now - 0.1) < 1e-12)
        clock.update(now: 100.3)
        #expect(abs(clock.delta - 0.2) < 1e-12)
        #expect(abs(clock.now - 0.3) < 1e-12)
    }

    @Test("WallClock pause: paused wall spans are not accumulated, no unpause jump")
    func wallClockPause() {
        let clock = WallClock()
        clock.update(now: 10.0)
        clock.update(now: 10.5)
        #expect(abs(clock.now - 0.5) < 1e-12)

        clock.paused = true
        clock.update(now: 20.0)  // long paused span
        #expect(clock.delta == 0)
        #expect(abs(clock.now - 0.5) < 1e-12)

        clock.paused = false
        clock.update(now: 20.25)  // delta measured from the LAST update, not pause start
        #expect(abs(clock.delta - 0.25) < 1e-12)
        #expect(abs(clock.now - 0.75) < 1e-12)
    }

    @Test("WallClock treats backwards timestamps as zero delta")
    func wallClockBackwards() {
        let clock = WallClock()
        clock.update(now: 5.0)
        clock.update(now: 4.0)
        #expect(clock.delta == 0)
    }
}

@Suite("Bitset")
struct BitsetTests {
    @Test("removeAll clears all words and can be reused")
    func removeAllClearsAndReuses() {
        var bits = Bitset(bitCount: 130)
        bits.insert(0)
        bits.insert(64)
        bits.insert(129)
        #expect(!bits.isEmpty)

        bits.removeAll()
        #expect(bits.isEmpty)
        #expect(!bits.contains(0))
        #expect(!bits.contains(64))
        #expect(!bits.contains(129))

        bits.insert(17)
        #expect(bits.contains(17))
        #expect(!bits.contains(18))
    }

    @Test("lane bitsets do not share backing storage after full-lane clears")
    func laneBitsetsClearIndependently() throws {
        let clock = FixedStepClock(step: 0.01)
        let engine = try makeEngine(
            (0..<70).map {
                ParamSpec(
                    key: ParamKey("t.p\($0)"),
                    label: "P\($0)",
                    range: -10...10,
                    default: 0,
                    smoothing: .instant)
            },
            clock: clock)

        for lane in Lane.allCases {
            for slot in firstContentSlot..<(firstContentSlot + 70) {
                engine.write(lane: lane, slot: slot, value: 1)
            }
        }

        for _ in 0..<20 {
            for lane in Lane.allCases { engine.clearLane(lane) }
            engine.write(lane: .user, slot: firstContentSlot + 69, value: 2)
            clock.advance()
            _ = engine.resolve()
        }

        #expect(engine.resolve().values[firstContentSlot + 69] == 2)
    }
}

@Suite("Param value types")
struct ParamTypeTests {
    @Test("ParamKey and SignalID round-trip through Codable as bare strings")
    func codableRoundTrip() throws {
        let key = ParamKey.warp(slot: 2, field: "strength")
        let data = try JSONEncoder().encode([key])
        let decoded = try JSONDecoder().decode([ParamKey].self, from: data)
        #expect(decoded == [key])
        #expect(String(data: data, encoding: .utf8) == "[\"warp.slot2.strength\"]")

        let id = SignalID("audio.band.low")
        let idData = try JSONEncoder().encode([id])
        #expect(try JSONDecoder().decode([SignalID].self, from: idData) == [id])
    }

    @Test("Lane is Codable by raw value; order survives")
    func laneCodable() throws {
        let data = try JSONEncoder().encode(Lane.allCases)
        #expect(String(data: data, encoding: .utf8) == "[0,1,2,3,4,5]")
        #expect(try JSONDecoder().decode([Lane].self, from: data) == Lane.allCases)
    }

    @Test("Capabilities OptionSet composes")
    func capabilities() {
        let caps: Capabilities = [.musicBindable, .animatable]
        #expect(caps.contains(.musicBindable))
        #expect(!caps.contains(.gestureBindable))
        #expect(caps.union(.requiresOptIn).contains(.requiresOptIn))
    }

    @Test("GroupID constants")
    func groups() {
        #expect(GroupID.shape.rawValue == "shape")
        #expect(GroupID.color.rawValue == "color")
        #expect(GroupID.camera.rawValue == "camera")
        #expect(GroupID.performance.rawValue == "performance")
    }

    @Test("ResponseCurve is metadata: identical params with different curves resolve identically")
    func curveNotAppliedAtResolution() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [
                ParamSpec(key: ParamKey("t.lin"), label: "lin", range: 0...10, default: 1,
                          curve: .linear, smoothing: .instant),
                ParamSpec(key: ParamKey("t.exp"), label: "exp", range: 0...10, default: 1,
                          curve: .exp(k: 3), smoothing: .instant),
                ParamSpec(key: ParamKey("t.scv"), label: "scv", range: 0...10, default: 1,
                          curve: .sCurve, smoothing: .instant),
            ],
            clock: clock)
        for slot in firstContentSlot...(firstContentSlot + 2) { engine.write(lane: .user, slot: slot, value: 4) }
        clock.advance()
        let values = engine.resolve().values
        #expect(values[firstContentSlot] == values[firstContentSlot + 1] && values[firstContentSlot + 1] == values[firstContentSlot + 2])
        #expect(values[firstContentSlot] == 5)  // default 1 + 4, curve ignored
    }
}
