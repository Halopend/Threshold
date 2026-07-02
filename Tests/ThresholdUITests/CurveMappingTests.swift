// CurveMappingTests.swift — ResponseCurveMapping position ↔ value contract:
// exact endpoints, monotonicity, and round-trips for linear / exp(k) / sCurve.

import Testing
import ThresholdCore
@testable import ThresholdUI

private let testCurves: [ResponseCurve] = [
    .linear, .exp(k: 2), .exp(k: -3), .exp(k: 0.5), .sCurve,
]

private let testRanges: [ClosedRange<Float>] = [
    0...1, 0.5...3.0, -2...4, 1...4096,
]

@Suite("ResponseCurveMapping")
struct CurveMappingTests {
    @Test("Endpoints are exact in both directions")
    func endpointsExact() {
        for curve in testCurves {
            for range in testRanges {
                #expect(ResponseCurveMapping.value(forPosition: 0, in: range, curve: curve)
                    == range.lowerBound)
                #expect(ResponseCurveMapping.value(forPosition: 1, in: range, curve: curve)
                    == range.upperBound)
                #expect(ResponseCurveMapping.position(
                    forValue: range.lowerBound, in: range, curve: curve) == 0)
                #expect(ResponseCurveMapping.position(
                    forValue: range.upperBound, in: range, curve: curve) == 1)
            }
        }
    }

    @Test("value(forPosition:) is monotonically non-decreasing")
    func monotonic() {
        for curve in testCurves {
            for range in testRanges {
                var previous = -Float.infinity
                for step in 0...100 {
                    let value = ResponseCurveMapping.value(
                        forPosition: Float(step) / 100, in: range, curve: curve)
                    #expect(value >= previous, "curve \(curve), range \(range), step \(step)")
                    #expect(range.contains(value))
                    previous = value
                }
            }
        }
    }

    @Test("position ↔ value round-trips across the range (seeded random)")
    func roundTrip() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        for curve in testCurves {
            for range in testRanges {
                for _ in 0..<50 {
                    let t = rng.float(in: 0...1)
                    let value = ResponseCurveMapping.value(forPosition: t, in: range, curve: curve)
                    let back = ResponseCurveMapping.position(forValue: value, in: range, curve: curve)
                    #expect(abs(back - t) <= 1e-3, "curve \(curve), range \(range), t \(t) → \(back)")
                }
            }
        }
    }

    @Test("value → position → value round-trips (seeded random)")
    func roundTripValues() {
        var rng = SplitMix64(seed: 0xBADA55)
        for curve in testCurves {
            for range in testRanges {
                let span = range.upperBound - range.lowerBound
                for _ in 0..<50 {
                    let value = rng.float(in: range)
                    let t = ResponseCurveMapping.position(forValue: value, in: range, curve: curve)
                    let back = ResponseCurveMapping.value(forPosition: t, in: range, curve: curve)
                    #expect(abs(back - value) <= span * 1e-3,
                            "curve \(curve), range \(range), v \(value) → \(back)")
                }
            }
        }
    }

    @Test("exp(k → 0) degenerates to linear")
    func tinyKIsLinear() {
        for step in 0...20 {
            let t = Float(step) / 20
            let value = ResponseCurveMapping.value(
                forPosition: t, in: 0...1, curve: .exp(k: 1e-6))
            let linear = ResponseCurveMapping.value(forPosition: t, in: 0...1, curve: .linear)
            #expect(value == linear)
        }
    }

    @Test("sCurve midpoint is the range midpoint")
    func sCurveMidpoint() {
        let mid = ResponseCurveMapping.value(forPosition: 0.5, in: 0...2, curve: .sCurve)
        #expect(abs(mid - 1) <= 1e-6)
        let pos = ResponseCurveMapping.position(forValue: 1, in: 0...2, curve: .sCurve)
        #expect(abs(pos - 0.5) <= 1e-6)
    }

    @Test("Out-of-range inputs clamp to endpoints")
    func clamping() {
        for curve in testCurves {
            #expect(ResponseCurveMapping.value(forPosition: -0.5, in: 1...3, curve: curve) == 1)
            #expect(ResponseCurveMapping.value(forPosition: 1.5, in: 1...3, curve: curve) == 3)
            #expect(ResponseCurveMapping.position(forValue: 0, in: 1...3, curve: curve) == 0)
            #expect(ResponseCurveMapping.position(forValue: 9, in: 1...3, curve: curve) == 1)
        }
    }

    @Test("Degenerate range (lo == hi) is stable")
    func degenerateRange() {
        for curve in testCurves {
            #expect(ResponseCurveMapping.value(forPosition: 0.7, in: 2...2, curve: curve) == 2)
            #expect(ResponseCurveMapping.position(forValue: 2, in: 2...2, curve: curve) == 0)
        }
    }
}
