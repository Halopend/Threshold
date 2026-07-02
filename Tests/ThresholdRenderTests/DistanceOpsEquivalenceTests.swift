// DistanceOpsEquivalenceTests.swift — sampled equivalence of the MSL
// distance-op interpreter (handAttract / forearmCarve / bounding
// passthrough) against ThresholdShaderIR.ReferenceOps.applyDistanceOps.
// Distance ops are built from IQ smooth min/max — continuous everywhere —
// so no discontinuity escape hatch is needed here.

import Foundation
import simd
import Testing
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

private func randomHandAttract(_ rng: inout SplitMix64,
                               sign: Float, pocket: Bool) -> ThreshWarpOp {
    let center = rng.point(in: -1...1)
    let radius = rng.float(in: 0.3...1.2)
    let shaping = SIMD4<Float>(rng.float(in: 0.5...1.5),   // ballScale
                               rng.float(in: 0.05...0.4),  // blendSoftness
                               rng.float(in: 0.2...0.8),   // pocketSize
                               rng.float(in: 0.05...0.3))  // pocketSoftness
    return makeOp(WK.handAttract,
                  s: sign * rng.float(in: 0.2...1.0),
                  a: SIMD4(center, radius),
                  b: shaping,
                  flags: pocket ? WK.flagOptionA : 0)
}

private func randomForearmCarve(_ rng: inout SplitMix64, sign: Float) -> ThreshWarpOp {
    let start = rng.point(in: -1.5...1.5)
    var end = rng.point(in: -1.5...1.5)
    if simd_length(end - start) < 1e-2 { end.y += 0.5 }
    return makeOp(WK.forearmCarve,
                  s: sign * rng.float(in: 0.2...1.0),
                  a: SIMD4(start, rng.float(in: 0.1...0.5)),
                  b: SIMD4(end, rng.float(in: 0.05...0.4)))
}

@Suite("Distance-op CPU/GPU equivalence", .serialized)
struct DistanceOpsEquivalenceTests {

    private func compare(_ stacks: [(name: String, ops: [ThreshWarpOp])],
                         rng: inout SplitMix64,
                         evaluator: OpsEvaluator) throws {
        for stack in stacks {
            let points = (0..<8).map { _ in rng.point(in: -2...2) }
            let distances = (0..<8).map { _ in rng.float(in: -0.5...1.5) }
            let gpu = try evaluator.applyDistanceOps(points: points,
                                                     distances: distances,
                                                     ops: stack.ops)
            #expect(gpu.count == points.count)
            for i in points.indices {
                let cpu = ReferenceOps.applyDistanceOps(points[i],
                                                        distance: distances[i],
                                                        ops: stack.ops)
                #expect(relClose(gpu[i], cpu, rel: 1e-3),
                        "\(stack.name): GPU \(gpu[i]) vs CPU \(cpu) at p=\(points[i]) d=\(distances[i])")
            }
        }
    }

    @Test(.enabled(if: GPU.available))
    func handAttractVariants() throws {
        let ctx = try GPU.ctx()
        let evaluator = try OpsEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xD157_0001)

        var stacks: [(name: String, ops: [ThreshWarpOp])] = []
        for index in 0..<6 {
            stacks.append(("attract #\(index)", [randomHandAttract(&rng, sign: 1, pocket: false)]))
            stacks.append(("repel #\(index)", [randomHandAttract(&rng, sign: -1, pocket: false)]))
            stacks.append(("attract+pocket #\(index)", [randomHandAttract(&rng, sign: 1, pocket: true)]))
            // Pocket flag with repel: the pocket branch requires s > 0 and must not fire.
            stacks.append(("repel+pocketFlag #\(index)", [randomHandAttract(&rng, sign: -1, pocket: true)]))
        }
        // s = 0 is exact identity by spec.
        stacks.append(("zero strength", [makeOp(WK.handAttract, s: 0,
                                                a: SIMD4(0.2, 0, -0.1, 0.8),
                                                b: SIMD4(1, 0.2, 0.5, 0.2))]))
        try compare(stacks, rng: &rng, evaluator: evaluator)
    }

    @Test(.enabled(if: GPU.available))
    func forearmCarveVariants() throws {
        let ctx = try GPU.ctx()
        let evaluator = try OpsEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xD157_0002)

        var stacks: [(name: String, ops: [ThreshWarpOp])] = []
        for index in 0..<8 {
            // Carve is ALWAYS subtractive; sign of s must not matter (|s|).
            stacks.append(("carve+ #\(index)", [randomForearmCarve(&rng, sign: 1)]))
            stacks.append(("carve- #\(index)", [randomForearmCarve(&rng, sign: -1)]))
        }
        try compare(stacks, rng: &rng, evaluator: evaluator)
    }

    @Test(.enabled(if: GPU.available))
    func mixedStacksAndPassthrough() throws {
        let ctx = try GPU.ctx()
        let evaluator = try OpsEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xD157_0003)

        var stacks: [(name: String, ops: [ThreshWarpOp])] = []
        for index in 0..<8 {
            var ops: [ThreshWarpOp] = []
            let count = rng.int(in: 2...3)
            for _ in 0..<count {
                if rng.bool() {
                    ops.append(randomHandAttract(&rng, sign: rng.bool() ? 1 : -1,
                                                 pocket: rng.bool()))
                } else {
                    ops.append(randomForearmCarve(&rng, sign: 1))
                }
            }
            stacks.append(("distance stack #\(index)", ops))
        }
        // Point ops interleaved in the march stack must be invisible to the
        // distance pipeline; Bounding (66) is reserved passthrough.
        stacks.append(("mixed with point ops + bounding", [
            makeOp(WK.twist, s: 0.8, a: SIMD4(0, 1, 0, 0)),
            randomHandAttract(&rng, sign: 1, pocket: true),
            makeOp(WK.bounding, s: 1, a: SIMD4(1, 2, 3, 4)),
            randomForearmCarve(&rng, sign: -1),
            makeOp(WK.mirror, s: 1),
        ]))
        try compare(stacks, rng: &rng, evaluator: evaluator)

        // Bounding alone is exact passthrough on both sides.
        let points = (0..<4).map { _ in rng.point() }
        let distances = (0..<4).map { _ in rng.float(in: -1...1) }
        let gpu = try evaluator.applyDistanceOps(
            points: points, distances: distances,
            ops: [makeOp(WK.bounding, s: 0.7, a: SIMD4(1, 1, 1, 1))])
        for i in points.indices {
            #expect(gpu[i] == distances[i], "Bounding must pass distances through untouched")
        }
    }
}
