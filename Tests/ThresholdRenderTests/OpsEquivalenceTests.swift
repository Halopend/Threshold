// OpsEquivalenceTests.swift — sampled equivalence of the MSL point-op
// interpreter against the CPU reference (ThresholdShaderIR.ReferenceOps).
// Both implement docs/op-semantics.md independently; agreement here is the
// Invariant 7 cross-check.
//
// Escape hatch (documented, deliberate): several op maps are exactly
// discontinuous BY SPEC — Tiling and BoxFold-HoM at cell boundaries,
// ScaleRepeat at Droste shell boundaries, Kaleidoscope's atan2 branch cut at
// partial strength. Near such a seam, CPU and GPU can land on opposite sides
// from sub-ULP trig differences and the pointwise compare is meaningless.
// Each case therefore re-evaluates the CPU reference at ±1e-3 axis
// perturbations; if any perturbed output jumps by more than 10% (relative)
// the case is skipped. Tests assert that the skips stay a small minority so
// the hatch can never swallow a real regression.

import Foundation
import simd
import Testing
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

/// True when `p` sits next to a spec-level discontinuity of the op stack:
/// the CPU reference jumps > 10% under a ±1e-3 perturbation of the input.
func discontinuityAdjacent(_ p: SIMD3<Float>, ops: [ThreshWarpOp]) -> Bool {
    let base = ReferenceOps.applyPointOps(p, ops: ops)
    let h: Float = 1e-3
    let positionScale = max(1, simd_length(base.p))
    let dScaleScale = max(1, abs(base.dScale))
    for axis in 0..<3 {
        for sign: Float in [-1, 1] {
            var q = p
            q[axis] += sign * h
            let perturbed = ReferenceOps.applyPointOps(q, ops: ops)
            if simd_length(perturbed.p - base.p) > 0.1 * positionScale { return true }
            if abs(perturbed.dScale - base.dScale) > 0.1 * dScaleScale { return true }
        }
    }
    return false
}

@Suite("Point-op CPU/GPU equivalence", .serialized)
struct OpsEquivalenceTests {

    private func compare(cases: [(name: String, ops: [ThreshWarpOp])],
                         pointsPerCase: Int,
                         rng: inout SplitMix64,
                         evaluator: OpsEvaluator) throws -> (tested: Int, skipped: Int) {
        var tested = 0
        var skipped = 0
        for testCase in cases {
            let points = (0..<pointsPerCase).map { _ in rng.point() }
            let gpu = try evaluator.applyPointOps(points: points, ops: testCase.ops)
            #expect(gpu.count == points.count)
            for (i, p) in points.enumerated() {
                let cpu = ReferenceOps.applyPointOps(p, ops: testCase.ops)
                if discontinuityAdjacent(p, ops: testCase.ops) {
                    skipped += 1
                    continue
                }
                #expect(relClose(gpu[i].p, cpu.p, rel: 1e-3),
                        "\(testCase.name): position GPU \(gpu[i].p) vs CPU \(cpu.p) at p=\(p)")
                #expect(relClose(gpu[i].dScale, cpu.dScale, rel: 2e-3),
                        "\(testCase.name): dScale GPU \(gpu[i].dScale) vs CPU \(cpu.dScale) at p=\(p)")
                tested += 1
            }
        }
        return (tested, skipped)
    }

    /// 300+ seeded random (point, single-op) cases covering EVERY point kind,
    /// plus directed edge payloads (zero axis, tiny radius, HoM flag, N=1…).
    @Test(.enabled(if: GPU.available))
    func singleOpEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try OpsEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0x0975_E001)

        var cases: [(name: String, ops: [ThreshWarpOp])] = []
        for variant in 0..<2 {
            for kind in WK.allPointKinds {
                cases.append(("kind \(kind) v\(variant)", [randomPointOp(kind, &rng)]))
            }
        }
        // Edge payloads — the spec's explicit corners.
        cases += [
            ("twist zero axis", [makeOp(WK.twist, s: 0.7, a: SIMD4(0, 0, 0, 0))]),
            ("bend zero axis", [makeOp(WK.bend, s: 0.5, a: SIMD4(0, 0, 0, 0))]),
            ("ripple zero axis", [makeOp(WK.ripple, s: 0.4, a: SIMD4(0, 0, 0, 2.0))]),
            ("sphereFold tiny minRadius", [makeOp(WK.sphereFold, s: 1, a: SIMD4(1e-3, 1.0, 0, 0))]),
            ("tubeFold tiny innerR", [makeOp(WK.tubeFold, s: 1, a: SIMD4(1e-3, 1.0, 0, 0))]),
            ("sphereInvert tiny radius", [makeOp(WK.sphereInvert, s: 1, a: SIMD4(1e-3, 0, 0, 0))]),
            ("boxFold hall of mirrors", [makeOp(WK.boxFold, s: 1, a: SIMD4(0.8, 0, 0, 0),
                                                flags: WK.flagOptionA)]),
            ("kaleidoscope N=1", [makeOp(WK.kaleidoscope, s: 1, a: SIMD4(1, 0, 0, 0))]),
            ("coxeter {2,2}", [makeOp(WK.coxeter, s: 1, a: SIMD4(2, 2, 0, 0))]),
            ("mirror full strength", [makeOp(WK.mirror, s: 1)]),
            ("scale strength 0 (identity)", [makeOp(WK.scale, s: 0, a: SIMD4(2.5, 0, 0, 0))]),
        ]

        let (tested, skipped) = try compare(cases: cases, pointsPerCase: 9,
                                            rng: &rng, evaluator: evaluator)
        #expect(tested >= 300, "spec requires 300 single-op equivalence samples (got \(tested), skipped \(skipped))")
        #expect(skipped < tested / 4, "discontinuity escape hatch must stay a small minority")
    }

    /// 100 random multi-op stacks (length 2...6) — the interpreter's
    /// sequential application and dScale accumulation under composition.
    @Test(.enabled(if: GPU.available))
    func multiOpStackEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try OpsEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0x57AC_4E01)

        var cases: [(name: String, ops: [ThreshWarpOp])] = []
        for index in 0..<100 {
            let length = rng.int(in: 2...6)
            let ops = (0..<length).map { _ -> ThreshWarpOp in
                let kind = WK.allPointKinds[rng.int(in: 0...(WK.allPointKinds.count - 1))]
                return randomPointOp(kind, &rng)
            }
            cases.append(("stack #\(index) len \(length) kinds \(ops.map(\.kind))", ops))
        }

        let (tested, skipped) = try compare(cases: cases, pointsPerCase: 4,
                                            rng: &rng, evaluator: evaluator)
        #expect(tested >= 250, "expected the bulk of 400 stack samples to survive the hatch (got \(tested), skipped \(skipped))")
        #expect(skipped < (tested + skipped) / 3)
    }

    /// Distance-op kinds and None must be ignored by the point pipeline.
    @Test(.enabled(if: GPU.available))
    func pointPipelineSkipsDistanceOpsAndNone() throws {
        let ctx = try GPU.ctx()
        let evaluator = try OpsEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0x5C19_0AF3)
        let ops = [
            makeOp(WK.none, s: 1),
            makeOp(WK.handAttract, s: 0.9, a: SIMD4(0, 0, 0, 1), b: SIMD4(1, 0.2, 0.5, 0.2)),
            makeOp(WK.twist, s: 0.6, a: SIMD4(0, 1, 0, 0)),
            makeOp(WK.bounding, s: 1),
        ]
        let onlyTwist = [ops[2]]
        let points = (0..<8).map { _ in rng.point() }
        let full = try evaluator.applyPointOps(points: points, ops: ops)
        let twistOnly = try evaluator.applyPointOps(points: points, ops: onlyTwist)
        for i in points.indices {
            #expect(relClose(full[i].p, twistOnly[i].p, rel: 1e-6))
            #expect(relClose(full[i].dScale, twistOnly[i].dScale, rel: 1e-6))
        }
    }
}
