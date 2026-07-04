// BoundingInStackEquivalenceTests.swift — sampled equivalence of the IN-STACK
// Bounding fold (docs/op-semantics.md §66): the GPU `eval_bounds` kernel
// (capture during the point walk + CSG fold in mapScene) against
// ReferenceOps.mapBounds. Preceding point ops are included so the
// transformed-frame capture — sdSolid(p)/dScale — is exercised, including a
// conformal op where dScale ≠ 1. All ops are built from IQ smooth min/max
// (continuous), so no discontinuity escape hatch is needed.

import Foundation
import simd
import Testing
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

/// An IN-STACK bound (no OPTION_B): a.x shape, a.y scale, a.z softness;
/// OPTION_A = subtract vs intersect.
private func inStackBound(shape: Float, scale: Float, softness: Float,
                          strength: Float, subtract: Bool) -> ThreshWarpOp {
    makeOp(WK.bounding, s: strength,
           a: SIMD4(shape, scale, softness, 0),
           flags: subtract ? WK.flagOptionA : 0)
}

@Suite("In-stack Bounding CPU/GPU equivalence", .serialized)
struct BoundingInStackEquivalenceTests {

    private func compare(_ stacks: [(name: String, ops: [ThreshWarpOp])],
                         rng: inout SplitMix64,
                         evaluator: OpsEvaluator) throws {
        for stack in stacks {
            let points = (0..<8).map { _ in rng.point(in: -2...2) }
            let base = (0..<8).map { _ in rng.float(in: -0.5...1.5) }
            let gpu = try evaluator.applyBounds(points: points, baseDistances: base, ops: stack.ops)
            #expect(gpu.count == points.count)
            for i in points.indices {
                let cpu = ReferenceOps.mapBounds(points[i], baseDistance: base[i], ops: stack.ops)
                #expect(relClose(gpu[i], cpu, rel: 1e-3),
                        "\(stack.name): GPU \(gpu[i]) vs CPU \(cpu) at p=\(points[i]) base=\(base[i])")
            }
        }
    }

    /// Every exposed shape × intersect/subtract, in the identity frame
    /// (dScale = 1) — this pins the sdSolid + CSG fold parity.
    @Test(.enabled(if: GPU.available))
    func shapesAndModes() throws {
        let ctx = try GPU.ctx()
        let evaluator = try OpsEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xB0DD_0001)

        let shapes: [Float] = [0, 1, 2, 4, 5, 6]  // sphere, cube, tetra, octa, icosa, dodeca
        var stacks: [(name: String, ops: [ThreshWarpOp])] = []
        for shape in shapes {
            for subtract in [false, true] {
                stacks.append(("shape \(shape) \(subtract ? "subtract" : "intersect")",
                               [inStackBound(shape: shape, scale: 0.8, softness: 0.05,
                                             strength: 0.9, subtract: subtract)]))
            }
        }
        try compare(stacks, rng: &rng, evaluator: evaluator)
    }

    /// Preceding point ops transform the frame the bound captures — position in
    /// the stack matters. Includes a conformal `scale` op so dScale ≠ 1 and the
    /// /dScale world-unit conversion is exercised.
    @Test(.enabled(if: GPU.available))
    func withPrecedingPointOps() throws {
        let ctx = try GPU.ctx()
        let evaluator = try OpsEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xB0DD_0002)

        var stacks: [(name: String, ops: [ThreshWarpOp])] = []
        // Conformal scale before the bound → dScale = 1/1.5 at the capture slot.
        stacks.append(("scale then bound", [
            makeOp(WK.scale, s: 1, a: SIMD4(1.5, 0, 0, 0)),
            inStackBound(shape: 1, scale: 0.7, softness: 0.05, strength: 1, subtract: false),
        ]))
        // Isometric tiling before the bound → the solid repeats per cell.
        stacks.append(("tiling then bound", [
            makeOp(WK.tiling, s: 1, a: SIMD4(2, 0, 0, 0), b: SIMD4(1, 1, 1, 0)),
            inStackBound(shape: 4, scale: 0.6, softness: 0.08, strength: 1, subtract: false),
        ]))
        // Two bounds at different slots (interleaved with twists) fold in order.
        stacks.append(("bounds between twists", [
            makeOp(WK.twist, s: 0.6, a: SIMD4(0, 1, 0, 0)),
            inStackBound(shape: 5, scale: 0.9, softness: 0.05, strength: 0.8, subtract: true),
            makeOp(WK.twist, s: 0.4, a: SIMD4(0, 1, 0, 0)),
            inStackBound(shape: 2, scale: 0.5, softness: 0.05, strength: 1, subtract: false),
        ]))
        try compare(stacks, rng: &rng, evaluator: evaluator)
    }
}
