// DScaleTests.swift — the distance-scale accumulation rules of
// docs/op-semantics.md, checked against numeric Jacobians.
//
// Conformal ops (Scale, SphereInvert, SphereFold, ScaleRepeat) report the
// EXACT factor, unclamped: |J v|/|v| must equal the reported dScale for any
// direction v, within 2%. Samples stay away from region/shell boundaries
// (5% margin) where the piecewise definition kinks.
//
// One subtlety the doc glosses over: the strength lerp `p' = p·lerp(1, f(r), s)`
// of the radially-varying ops (SphereInvert; SphereFold's shell region) is
// only exactly conformal at s = 1 or where f is locally constant — at
// intermediate s the radial and tangential expansions differ, and the doc's
// reported factor is the declared semantic for the TANGENTIAL directions.
// The tests therefore check: full-strength → all directions; intermediate
// strength → tangential directions (v ⊥ p). Scale and ScaleRepeat (locally
// constant factor) are exact at every strength and direction.
//
// Lipschitz-approximated ops (Twist, Bend, Ripple, TubeFold, SphereProject)
// report `max(1, factor)`: the sampled local expansion must not exceed the
// report beyond documented slack. For Ripple/TubeFold/SphereProject the
// reported bound provably dominates the true spectral norm → 2% tolerance.
// For Twist/Bend the doc's √(1+(s·r⊥)²) is the SHEAR COLUMN bound, not the
// spectral norm; the true worst case exceeds it by ≤ 2/√3 (pure shear, twist)
// and ≤ √2 (offset rotation, bend) — the documented "approximation error
// absorbed by stepSafety". The tests assert those exact envelopes, plus the
// tight column identity along the adapted directions.

import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdShaderIR

@Suite("Conformal dScale exactness")
struct ConformalDScaleTests {
    @Test("Scale: exact 1/m expansion at any strength and direction")
    func scaleExact() {
        var rng = SplitMix64(seed: 11)
        for _ in 0..<80 {
            let op = ThreshWarpOp.scale(
                factor: rng.float(in: 0.3...3),
                strength: rng.float(in: 0.1...1))
            let p = rng.point(in: -2...2)
            let reported = reportedDScale(op, at: p)
            let measured = directionalExpansion(of: pointMap(op), at: p, along: rng.unitVector())
            #expect(abs(measured - reported) <= 0.02 * reported,
                    "scale: measured \(measured) vs reported \(reported)")
        }
    }

    @Test("ScaleRepeat: exact 1/m inside each Droste shell, any strength")
    func scaleRepeatExact() {
        var rng = SplitMix64(seed: 12)
        let factor: Float = 2
        var checked = 0
        for _ in 0..<400 where checked < 80 {
            let p = rng.point(in: -3...3)
            let r = simd_length(p)
            guard r > 0.05 else { continue }
            // Skip within 5% (log-space) of a shell boundary r = factorⁿ.
            let logR = logf(r) / logf(factor)
            let frac = logR - floorf(logR)
            guard frac > 0.07, frac < 0.93 else { continue }
            checked += 1
            let op = ThreshWarpOp.scaleRepeat(factor: factor, strength: rng.float(in: 0.1...1))
            let reported = reportedDScale(op, at: p)
            let measured = directionalExpansion(of: pointMap(op), at: p, along: rng.unitVector())
            #expect(abs(measured - reported) <= 0.02 * reported,
                    "scaleRepeat: measured \(measured) vs reported \(reported) at r=\(r)")
        }
        #expect(checked >= 80)
    }

    @Test("SphereInvert: exact R²/r² at s=1 (all directions), tangential at any s")
    func sphereInvertExact() {
        var rng = SplitMix64(seed: 13)
        for _ in 0..<80 {
            let radius = rng.float(in: 0.5...2)
            var p = rng.point(in: -2...2)
            while simd_length(p) < 0.3 { p = rng.point(in: -2...2) }

            // Full strength: conformal — any direction.
            let full = ThreshWarpOp.sphereInvert(radius: radius, strength: 1)
            let reportedFull = reportedDScale(full, at: p)
            let measuredFull = directionalExpansion(of: pointMap(full), at: p, along: rng.unitVector())
            #expect(abs(measuredFull - reportedFull) <= 0.02 * reportedFull,
                    "sphereInvert s=1: \(measuredFull) vs \(reportedFull)")

            // Intermediate strength: tangential directions carry the factor.
            let partial = ThreshWarpOp.sphereInvert(radius: radius, strength: rng.float(in: 0.1...0.9))
            let tangent = simd_normalize(simd_cross(p, rng.unitVector()))
            guard tangent.x.isFinite else { continue }
            let reportedPart = reportedDScale(partial, at: p)
            let measuredPart = directionalExpansion(of: pointMap(partial), at: p, along: tangent)
            #expect(abs(measuredPart - reportedPart) <= 0.02 * reportedPart,
                    "sphereInvert partial s: \(measuredPart) vs \(reportedPart)")
        }
    }

    @Test("SphereFold: exact per region (inner any s, shell s=1 + tangential, outer identity)")
    func sphereFoldExact() {
        var rng = SplitMix64(seed: 14)
        let minR: Float = 0.5
        let fixedR: Float = 1.5

        // Sample by radius per region, keeping a >5% margin from both
        // boundaries (and clear of r=0 so the h=1e-3 stencil stays inside).
        for _ in 0..<40 {
            // Inner region: constant factor fR²/mR² — conformal at ANY s.
            let p = rng.unitVector() * rng.float(in: 0.05...(minR * 0.93))
            let op = ThreshWarpOp.sphereFold(
                minRadius: minR, fixedRadius: fixedR, strength: rng.float(in: 0.1...1))
            let reported = reportedDScale(op, at: p)
            let measured = directionalExpansion(of: pointMap(op), at: p, along: rng.unitVector())
            #expect(abs(measured - reported) <= 0.02 * reported,
                    "sphereFold inner: \(measured) vs \(reported) at r=\(simd_length(p))")
        }
        for _ in 0..<40 {
            let p = rng.unitVector() * rng.float(in: (minR * 1.07)...(fixedR * 0.93))
            // Shell region, full strength: conformal inversion-like.
            let full = ThreshWarpOp.sphereFold(minRadius: minR, fixedRadius: fixedR, strength: 1)
            let reportedFull = reportedDScale(full, at: p)
            let measuredFull = directionalExpansion(of: pointMap(full), at: p, along: rng.unitVector())
            #expect(abs(measuredFull - reportedFull) <= 0.02 * reportedFull,
                    "sphereFold shell s=1: \(measuredFull) vs \(reportedFull)")
            // Intermediate strength: tangential directions.
            let partial = ThreshWarpOp.sphereFold(
                minRadius: minR, fixedRadius: fixedR, strength: rng.float(in: 0.1...0.9))
            let tangent = simd_normalize(simd_cross(p, rng.unitVector()))
            guard tangent.x.isFinite else { continue }
            let reportedPart = reportedDScale(partial, at: p)
            let measuredPart = directionalExpansion(of: pointMap(partial), at: p, along: tangent)
            #expect(abs(measuredPart - reportedPart) <= 0.02 * reportedPart,
                    "sphereFold shell partial: \(measuredPart) vs \(reportedPart)")
        }
        for _ in 0..<40 {
            let p = rng.unitVector() * rng.float(in: (fixedR * 1.07)...2.5)
            // Outside fixedRadius the op is the identity: factor exactly 1.
            let op = ThreshWarpOp.sphereFold(
                minRadius: minR, fixedRadius: fixedR, strength: rng.float(in: 0.1...1))
            #expect(reportedDScale(op, at: p) == 1)
            #expect(simd_length(pointMap(op)(p) - p) == 0)
        }
    }

    @Test("Conformal factors are NOT clamped: inversion inside the sphere shrinks dScale")
    func conformalUnclamped() {
        // r=2, R=1 → k = 1/4 < 1. The estimate must shrink with the map.
        let op = ThreshWarpOp.sphereInvert(radius: 1, strength: 1)
        let p = SIMD3<Float>(2, 0, 0)
        let reported = reportedDScale(op, at: p)
        #expect(abs(reported - 0.25) < 1e-6)
        // Scale with factor > 1 also reports < 1 (p' = p/m).
        let scale = ThreshWarpOp.scale(factor: 2, strength: 1)
        #expect(abs(reportedDScale(scale, at: p) - 0.5) < 1e-6)
    }
}

@Suite("Lipschitz dScale soundness")
struct LipschitzDScaleTests {
    /// Kinds whose reported bound provably dominates the true spectral norm.
    @Test("Ripple/TubeFold/SphereProject: sampled expansion <= reported · 1.02")
    func tightBounds() {
        var rng = SplitMix64(seed: 21)
        let minR: Float = 0.5
        let fixedR: Float = 1.5
        var count = 0
        for _ in 0..<1500 where count < 240 {
            let p = rng.point(in: -2...2)
            let pick = count % 3
            let op: ThreshWarpOp
            switch pick {
            case 0:
                op = .ripple(axis: rng.unitVector(),
                             frequency: rng.float(in: 0.5...6),
                             strength: rng.float(in: -1...1))
            case 1:
                // Skip TubeFold's in-plane region boundaries (5% margin).
                let rXZ = simd_length(SIMD2(p.x, p.z))
                guard rXZ > 0.05,
                      abs(rXZ - minR) > 0.05 * minR,
                      abs(rXZ - fixedR) > 0.05 * fixedR
                else { continue }
                op = .tubeFold(innerRadius: minR, outerRadius: fixedR,
                               strength: rng.float(in: 0...1))
            default:
                guard simd_length(p) > 0.2 else { continue }
                op = .sphereProject(radius: rng.float(in: 0.5...2),
                                    strength: rng.float(in: 0...1))
            }
            count += 1
            let reported = reportedDScale(op, at: p)
            let measured = sampledMaxExpansion(of: pointMap(op), at: p, rng: &rng)
            #expect(measured <= reported * 1.02,
                    "kind \(op.kind): expansion \(measured) exceeds reported \(reported) at \(p)")
        }
        #expect(count >= 240)
    }

    @Test("Twist: axis column equals √(1+(s·r⊥)²); spectral within the 2/√3 shear envelope")
    func twistEnvelope() {
        var rng = SplitMix64(seed: 22)
        let shearEnvelope: Float = 2 / sqrtf(3) // sup‖shear‖/√(1+a²), see header
        for _ in 0..<120 {
            let axis = rng.unitVector()
            let op = ThreshWarpOp.twist(axis: axis, strength: rng.float(in: -1...1))
            let p = rng.point(in: -2...2)
            let reported = reportedDScale(op, at: p)
            let map = pointMap(op)

            // Tight identity: the axial column norm IS the documented factor
            // (√(1+(s·r⊥)²)) and in-plane columns are unit.
            let axial = directionalExpansion(of: map, at: p, along: axis)
            #expect(abs(axial - reported) <= 0.02 * reported || reported == 1,
                    "twist axial column \(axial) vs reported \(reported)")
            let inPlane = directionalExpansion(
                of: map, at: p, along: ReferenceOps.perpOf(axis))
            #expect(inPlane <= 1.02, "twist in-plane column \(inPlane) must be ~1")

            // Sound envelope: the true spectral norm of a unit shear exceeds
            // the column bound by at most 2/√3 (docs: approximation absorbed
            // by stepSafety).
            let measured = sampledMaxExpansion(of: map, at: p, rng: &rng)
            #expect(measured <= reported * shearEnvelope * 1.02,
                    "twist spectral \(measured) vs envelope \(reported * shearEnvelope)")
        }
    }

    @Test("Bend: axis column is unit; spectral within the √2 offset-rotation envelope")
    func bendEnvelope() {
        var rng = SplitMix64(seed: 23)
        let envelope: Float = Float(2).squareRoot()
        for _ in 0..<120 {
            let axis = rng.unitVector()
            let op = ThreshWarpOp.bend(axis: axis, strength: rng.float(in: -1...1))
            let p = rng.point(in: -2...2)
            let reported = reportedDScale(op, at: p)
            let map = pointMap(op)

            // Moving along the rotation axis never stretches (ĉ ⊥ n̂).
            let axial = directionalExpansion(of: map, at: p, along: axis)
            #expect(axial <= 1.02, "bend axial column \(axial) must be ~1")

            let measured = sampledMaxExpansion(of: map, at: p, rng: &rng)
            #expect(measured <= reported * envelope * 1.02,
                    "bend spectral \(measured) vs envelope \(reported * envelope)")
        }
    }

    @Test("Reported Lipschitz factors are clamped to >= 1")
    func clampedFactors() {
        var rng = SplitMix64(seed: 24)
        for _ in 0..<60 {
            let p = rng.point(in: -2...2)
            let ops: [ThreshWarpOp] = [
                .twist(axis: rng.unitVector(), strength: rng.float(in: -1...1)),
                .bend(axis: rng.unitVector(), strength: rng.float(in: -1...1)),
                .ripple(axis: rng.unitVector(), frequency: rng.float(in: 0.5...6),
                        strength: rng.float(in: -1...1)),
                .tubeFold(innerRadius: 0.5, outerRadius: 1.5, strength: rng.float(in: 0...1)),
                .sphereProject(radius: rng.float(in: 0.5...2), strength: rng.float(in: 0...1)),
                .shells(spacing: rng.float(in: 0.5...2), strength: rng.float(in: 0...1)),
            ]
            for op in ops {
                #expect(reportedDScale(op, at: p) >= 1,
                        "kind \(op.kind) reported a contraction — must clamp to 1")
            }
        }
    }
}
