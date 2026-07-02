// DistanceOpTests.swift — sanity for the distance-space ops (HandAttract,
// ForearmCarve) and the IQ smooth min/max helpers they are built on.

import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdShaderIR

@Suite("Smooth min/max helpers")
struct SmoothMinMaxTests {
    @Test("smin/smax match the op-semantics definitions on scalars")
    func definitions() {
        var rng = SplitMix64(seed: 31)
        for _ in 0..<200 {
            let x = rng.float(in: -2...2)
            let y = rng.float(in: -2...2)
            let k = rng.float(in: 0.01...1)
            // smin(x, y, k): h = max(k - |x - y|, 0)/k; min(x, y) - h²k/4
            let h = max(k - abs(x - y), 0) / k
            let expectedMin = min(x, y) - h * h * k / 4
            #expect(abs(ReferenceOps.smin(x, y, k) - expectedMin) <= 1e-6)
            // smax(x, y, k) = -smin(-x, -y, k)
            #expect(ReferenceOps.smax(x, y, k) == -ReferenceOps.smin(-x, -y, k))
        }
    }

    @Test("smin <= min with equality outside the blend band; smax dual")
    func envelopeProperties() {
        var rng = SplitMix64(seed: 32)
        for _ in 0..<200 {
            let x = rng.float(in: -2...2)
            let y = rng.float(in: -2...2)
            let k = rng.float(in: 0.01...1)
            let sMin = ReferenceOps.smin(x, y, k)
            let sMax = ReferenceOps.smax(x, y, k)
            #expect(sMin <= min(x, y) + 1e-6)
            #expect(sMax >= max(x, y) - 1e-6)
            if abs(x - y) >= k {
                #expect(sMin == min(x, y))
                #expect(sMax == max(x, y))
            }
            // The blend correction never exceeds k/4.
            #expect(min(x, y) - sMin <= k / 4 + 1e-6)
        }
    }
}

@Suite("Distance ops")
struct DistanceOpTests {
    private func attract(strength: Float, pocket: Bool = false) -> ThreshWarpOp {
        .handAttract(center: SIMD3(0.5, 0.2, -0.3), radius: 0.4,
                     ballScale: 1.0, softness: 0.1,
                     pocketSize: 0.4, pocketSoftness: 0.05,
                     pocketEnabled: pocket, strength: strength)
    }

    @Test("attract (s > 0) lowers d near the center")
    func attractLowers() {
        var rng = SplitMix64(seed: 33)
        let center = SIMD3<Float>(0.5, 0.2, -0.3)
        for _ in 0..<100 {
            let op = attract(strength: rng.float(in: 0.1...1))
            // Points near the ball, with a DE value larger than the ball's
            // SDF there: the union must pull d down.
            let p = center + rng.unitVector() * rng.float(in: 0...0.3)
            let d = rng.float(in: 0.5...4)
            let dOut = ReferenceOps.applyDistanceOps(p, distance: d, ops: [op])
            #expect(dOut < d, "attract must lower d=\(d) near center, got \(dOut)")
            // And never below the ball SDF beyond the smoothing correction.
            let sphere = simd_length(p - center) - 0.4
            #expect(dOut >= min(d, sphere) - 0.1 / 4 - 1e-5)
        }
    }

    @Test("repel (s < 0) raises d inside the ball")
    func repelRaises() {
        var rng = SplitMix64(seed: 34)
        let center = SIMD3<Float>(0.5, 0.2, -0.3)
        for _ in 0..<100 {
            let op = attract(strength: rng.float(in: -1...(-0.1)))
            let p = center + rng.unitVector() * rng.float(in: 0...0.35) // inside R·ballScale
            let d = rng.float(in: 0.001...0.02) // marching close to a surface
            let dOut = ReferenceOps.applyDistanceOps(p, distance: d, ops: [op])
            #expect(dOut > d, "repel must raise d=\(d) inside the ball, got \(dOut)")
        }
    }

    @Test("pocket (flag + s > 0) carves back out at the center")
    func pocketCarves() {
        var rng = SplitMix64(seed: 35)
        let center = SIMD3<Float>(0.5, 0.2, -0.3)
        for _ in 0..<100 {
            // Near-full strength so the attract step pulls d' below the
            // pocket surface — that is where the carve-back must bite.
            let s = rng.float(in: 0.9...1)
            let plain = attract(strength: s, pocket: false)
            let pocketed = attract(strength: s, pocket: true)
            let p = center + rng.unitVector() * rng.float(in: 0...0.1) // well inside pocketSize·R
            let d = rng.float(in: 0.5...2)
            let dPlain = ReferenceOps.applyDistanceOps(p, distance: d, ops: [plain])
            let dPocket = ReferenceOps.applyDistanceOps(p, distance: d, ops: [pocketed])
            #expect(dPocket > dPlain,
                    "pocket must push d back up at the center (\(dPocket) vs \(dPlain))")
        }
        // Pocket flag without attraction (s < 0) changes nothing vs plain repel.
        let p = center + SIMD3<Float>(0.05, 0, 0)
        let dRepelPlain = ReferenceOps.applyDistanceOps(p, distance: 0.01, ops: [attract(strength: -0.5)])
        let dRepelPocket = ReferenceOps.applyDistanceOps(p, distance: 0.01, ops: [attract(strength: -0.5, pocket: true)])
        #expect(dRepelPlain == dRepelPocket)
    }

    @Test("forearmCarve only ever increases d, for either strength sign")
    func carveMonotone() {
        var rng = SplitMix64(seed: 36)
        for _ in 0..<300 {
            let op = ThreshWarpOp.forearmCarve(
                from: rng.point(in: -1...1),
                to: rng.point(in: -1...1),
                radius: rng.float(in: 0.05...0.5),
                softness: rng.float(in: 0.01...0.3),
                strength: rng.float(in: -1...1)) // sign must be irrelevant: |s|
            let p = rng.point(in: -2...2)
            let d = rng.float(in: -0.5...2)
            let dOut = ReferenceOps.applyDistanceOps(p, distance: d, ops: [op])
            #expect(dOut >= d - 1e-6,
                    "carve is always subtractive: d' \(dOut) < d \(d)")
        }
    }

    @Test("forearmCarve uses |s|: opposite signs are identical")
    func carveSignless() {
        var rng = SplitMix64(seed: 37)
        for _ in 0..<100 {
            let from = rng.point(in: -1...1)
            let to = rng.point(in: -1...1)
            let radius = rng.float(in: 0.05...0.5)
            let soft = rng.float(in: 0.01...0.3)
            let s = rng.float(in: 0.1...1)
            let plus = ThreshWarpOp.forearmCarve(from: from, to: to, radius: radius, softness: soft, strength: s)
            let minus = ThreshWarpOp.forearmCarve(from: from, to: to, radius: radius, softness: soft, strength: -s)
            let p = rng.point(in: -2...2)
            let d = rng.float(in: -0.5...2)
            #expect(ReferenceOps.applyDistanceOps(p, distance: d, ops: [plus])
                    == ReferenceOps.applyDistanceOps(p, distance: d, ops: [minus]))
        }
    }

    @Test("strength 0 is the identity for both distance ops")
    func zeroStrengthIdentity() {
        var rng = SplitMix64(seed: 38)
        for _ in 0..<100 {
            let p = rng.point(in: -2...2)
            let d = rng.float(in: -1...4)
            let hand = attract(strength: 0, pocket: rng.bool())
            let carve = ThreshWarpOp.forearmCarve(
                from: rng.point(in: -1...1), to: rng.point(in: -1...1),
                radius: 0.2, softness: 0.1, strength: 0)
            #expect(ReferenceOps.applyDistanceOps(p, distance: d, ops: [hand, carve]) == d)
        }
    }

    @Test("class separation: point ops ignore distance ops and vice versa")
    func classSeparation() {
        var rng = SplitMix64(seed: 39)
        let hand = attract(strength: 0.8)
        let carve = ThreshWarpOp.forearmCarve(
            from: SIMD3(0, -1, 0), to: SIMD3(0, 1, 0), radius: 0.3, softness: 0.1, strength: 1)
        let twist = ThreshWarpOp.twist(axis: SIMD3(0, 1, 0), strength: 0.7)
        let mirror = ThreshWarpOp.mirror()
        for _ in 0..<50 {
            let p = rng.point(in: -2...2)
            let d = rng.float(in: -1...2)
            // applyPointOps skips distance ops entirely...
            let withDistOps = ReferenceOps.applyPointOps(p, ops: [hand, twist, carve, mirror])
            let without = ReferenceOps.applyPointOps(p, ops: [twist, mirror])
            #expect(withDistOps.p == without.p)
            #expect(withDistOps.dScale == without.dScale)
            // ...and applyDistanceOps skips point ops entirely.
            let dMixed = ReferenceOps.applyDistanceOps(p, distance: d, ops: [twist, hand, mirror, carve])
            let dPure = ReferenceOps.applyDistanceOps(p, distance: d, ops: [hand, carve])
            #expect(dMixed == dPure)
        }
        // None and unknown kinds are no-ops on both paths.
        var unknown = ThreshWarpOp()
        unknown.kind = 42
        unknown.strength = 1
        let p = SIMD3<Float>(0.3, -0.4, 0.9)
        #expect(ReferenceOps.applyPointOps(p, ops: [unknown]).p == p)
        #expect(ReferenceOps.applyDistanceOps(p, distance: 0.5, ops: [unknown]) == 0.5)
    }
}
