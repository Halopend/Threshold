// DEEquivalenceTests.swift — the GPU built-in DEs (visible functions,
// dispatched through the function table) against
// ThresholdShaderIR.ReferenceDEs, on seeded random EXTERIOR points.
//
// Sampling note (deliberate): mandelbulb points are drawn from radii
// [1.5, 1.9] ∪ [4.5, 8]. On that domain the orbit's first escape leaps far
// past any reasonable bailout radius, so the comparison is insensitive to
// the exact bailout convention — the DE estimate 0.5·log(r)·r/dr is
// asymptotically invariant to running extra escaped iterations. Radii just
// above the set (where an orbit could linger between 2 and 4) are the one
// place two "standard formulations" can legitimately disagree, so the test
// stays off them.

import Foundation
import simd
import Testing
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("Built-in DE CPU/GPU equivalence", .serialized)
struct DEEquivalenceTests {

    private func exteriorPoint(_ rng: inout SplitMix64,
                               radius: ClosedRange<Float>) -> SIMD3<Float> {
        rng.unitVector() * rng.float(in: radius)
    }

    @Test(.enabled(if: GPU.available))
    func mandelboxEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xDE00_0B0C)

        // params: [scale, minRadius, fixedRadius, foldLimit]
        let paramSets: [(params: [Float], iterations: Int)] = [
            ([2.0, 0.5, 1.0, 1.0], 12),
            ([2.5, 0.6, 1.2, 1.0], 8),
            ([1.7, 0.4, 1.0, 1.2], 12),
            ([2.2, 0.5, 1.0, 0.8], 10),
        ]
        var tested = 0
        for set in paramSets {
            // Exterior of the mandelbox (bounding radius ≈ (scale+1)/(scale-1)).
            let points = (0..<50).map { _ in exteriorPoint(&rng, radius: 4.0...8.0) }
            let gpu = try evaluator.evaluate(points: points, deIndex: 0,
                                             deParams: set.params,
                                             iterations: set.iterations)
            for (i, p) in points.enumerated() {
                let cpu = ReferenceDEs.mandelbox(p, params: set.params,
                                                 iterations: set.iterations)
                #expect(relClose(gpu[i].x, cpu.x, rel: 1e-3),
                        "mandelbox .x GPU \(gpu[i].x) vs CPU \(cpu.x) at \(p), params \(set.params)")
                #expect(relClose(gpu[i].y, cpu.y, rel: 5e-3),
                        "mandelbox .y (trap) GPU \(gpu[i].y) vs CPU \(cpu.y) at \(p), params \(set.params)")
                tested += 1
            }
        }
        #expect(tested == 200)
    }

    @Test(.enabled(if: GPU.available))
    func mandelbulbEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xDE00_0B1B)

        // params: [power]
        let paramSets: [(params: [Float], iterations: Int)] = [
            ([8.0], 12),
            ([8.0], 8),
            ([5.0], 12),
            ([9.0], 10),
        ]
        var tested = 0
        for set in paramSets {
            let near = (0..<25).map { _ in exteriorPoint(&rng, radius: 1.5...1.9) }
            let far = (0..<25).map { _ in exteriorPoint(&rng, radius: 4.5...8.0) }
            let points = near + far
            let gpu = try evaluator.evaluate(points: points, deIndex: 1,
                                             deParams: set.params,
                                             iterations: set.iterations)
            for (i, p) in points.enumerated() {
                let cpu = ReferenceDEs.mandelbulb(p, params: set.params,
                                                  iterations: set.iterations)
                #expect(relClose(gpu[i].x, cpu.x, rel: 1e-3),
                        "mandelbulb .x GPU \(gpu[i].x) vs CPU \(cpu.x) at \(p), power \(set.params[0])")
                #expect(relClose(gpu[i].y, cpu.y, rel: 5e-3),
                        "mandelbulb .y (trap) GPU \(gpu[i].y) vs CPU \(cpu.y) at \(p), power \(set.params[0])")
                tested += 1
            }
        }
        #expect(tested == 200)
    }

    /// The iterations convention: the encoder appends iterations as the LAST
    /// entry of the DE param slice, and the DE genuinely reads it — different
    /// iteration counts must give different exterior estimates somewhere.
    @Test(.enabled(if: GPU.available))
    func iterationsConventionIsHonored() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xDE00_17E2)
        let points = (0..<16).map { _ in rng.unitVector() * rng.float(in: 4...6) }
        let params: [Float] = [2.0, 0.5, 1.0, 1.0]

        let few = try evaluator.evaluate(points: points, deIndex: 0,
                                         deParams: params, iterations: 2)
        let many = try evaluator.evaluate(points: points, deIndex: 0,
                                          deParams: params, iterations: 12)
        var anyDifference = false
        for i in points.indices where abs(few[i].x - many[i].x) > 1e-6 {
            anyDifference = true
        }
        #expect(anyDifference, "iteration count (last DE slice entry) must reach the DE")
    }
}
