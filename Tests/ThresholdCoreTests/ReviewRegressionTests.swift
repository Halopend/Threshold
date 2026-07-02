// ReviewRegressionTests.swift — pins for the adversarial-review findings
// (2026-07-02). Each test is a reproduction that FAILED before the fix.

import Foundation
import Testing

@testable import ThresholdCore

@Suite("Review regressions: non-finite values")
struct NonFiniteRegressionSuite {
    @Test("NaN lane write is dropped at ingress and never reaches the resolved table")
    func nanWriteDropped() throws {
        let clock = FixedStepClock()
        let engine = try makeEngine([spec("p", range: 0...1, default: 0.5)], clock: clock)
        let slot = engine.layout.slot(for: ParamKey("p"))!

        engine.mailbox.publish(LaneWrite(lane: .music, slot: slot, value: .nan))
        engine.mailbox.publish(LaneWrite(lane: .user, slot: slot, value: .infinity))
        clock.advance()
        let resolved = engine.resolve()
        #expect(resolved.values[slot] == 0.5)  // default; both writes dropped
        #expect(engine.currentValue(lane: .music, slot: slot) == nil)

        // The slot is not poisoned: a later finite write works normally.
        engine.write(lane: .user, slot: slot, value: 0.9)
        clock.advance()
        #expect(engine.resolve().values[slot] > 0.5)
    }

    @Test("Every resolved value is finite even under extreme finite inputs")
    func resolveAlwaysFinite() throws {
        // greatestFiniteMagnitude offsets overflow composition arithmetic to
        // ±inf; the clamp site must fall back to the default, not upload inf.
        let clock = FixedStepClock()
        let engine = try makeEngine(
            [spec("p", range: -1e30...1e30, default: 1)], clock: clock)
        let slot = engine.layout.slot(for: ParamKey("p"))!
        engine.write(lane: .scene, slot: slot, value: Float.greatestFiniteMagnitude)
        engine.write(lane: .user, slot: slot, value: Float.greatestFiniteMagnitude)
        clock.advance()
        let resolved = engine.resolve()
        #expect(resolved.values[slot].isFinite)
    }

    @Test("setIntegratorPhase(NaN) cannot poison persistent phase state")
    func integratorPhaseNaNProof() throws {
        let clock = FixedStepClock()
        let engine = try makeEngine(
            [
                spec("rate", range: -10...10, default: 1),
                spec("phase", range: 0...10, integratorRateKey: ParamKey("rate")),
            ], clock: clock)
        let phaseSlot = engine.layout.slot(for: ParamKey("phase"))!

        engine.setIntegratorPhase(slot: phaseSlot, value: .nan)
        let phase = try #require(engine.readIntegratorPhase(slot: phaseSlot))
        #expect(phase.isFinite)

        clock.advance()
        let resolved = engine.resolve()
        #expect(resolved.values[phaseSlot].isFinite)
    }
}

@Suite("Review regressions: scene decode robustness")
struct SceneDecodeRegressionSuite {
    @Test("Out-of-Int-range version throws malformed instead of trapping")
    func hugeVersionThrows() {
        for versionLiteral in ["1e300", "-1e300", "99999999999999999999"] {
            let data = Data(#"{"version": \#(versionLiteral), "fractalTypeKey": "m"}"#.utf8)
            #expect(throws: SceneCodecError.self, "version \(versionLiteral)") {
                try SceneCodec.decode(data)
            }
        }
        // Negative-but-in-range is also malformed, not a migration lookup.
        #expect(throws: SceneCodecError.self) {
            try SceneCodec.decode(Data(#"{"version": -1, "fractalTypeKey": "m"}"#.utf8))
        }
    }

    @Test("Param values beyond Float range go to the foreign sidecar, keeping the scene saveable")
    func hugeParamStaysForeign() throws {
        let data = Data(
            #"{"version": 1, "fractalTypeKey": "m", "params": {"future.big": 1e300, "shape.power": [8]}}"#
                .utf8)
        let decoded = try SceneCodec.decode(data)
        #expect(decoded.params["future.big"] == nil)
        #expect(decoded.foreignParams["future.big"] == .number(1e300))
        #expect(decoded.params["shape.power"] == [8])

        // The critical property: re-encoding must not throw (inf would).
        let reencoded = try SceneCodec.encode(decoded)
        let roundTripped = try SceneCodec.decode(reencoded)
        #expect(roundTripped == decoded)
    }
}
