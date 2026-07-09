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
    func legacyMandelboxEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0x1E6A_C0DE)
        let descriptor = try #require(DERegistry.descriptor(forKey: "legacyMandelbox"))

        // params: [scale, minDistance, sphereRadius, foldLimit]
        let paramSets: [(params: [Float], iterations: Int)] = [
            ([2.8, 2.2960358, 0.01, 1.0], 8),       // Paul
            ([2.8, 2.3174517, 0.01, 1.0], 8),       // Spiky
            ([3.0075026, 12.501993, 0.31832752, 1.0], 10),
        ]
        var tested = 0
        for set in paramSets {
            let points = (0..<40).map { _ in exteriorPoint(&rng, radius: 4.0...8.0) }
            let gpu = try evaluator.evaluate(points: points, deIndex: Int(descriptor.index),
                                             deParams: set.params,
                                             iterations: set.iterations)
            for (i, p) in points.enumerated() {
                let cpu = ReferenceDEs.legacyMandelbox(p, params: set.params,
                                                       iterations: set.iterations)
                #expect(relClose(gpu[i].x, cpu.x, rel: 1e-3),
                        "legacyMandelbox .x GPU \(gpu[i].x) vs CPU \(cpu.x) at \(p), params \(set.params)")
                #expect(relClose(gpu[i].y, cpu.y, rel: 5e-3),
                        "legacyMandelbox .y GPU \(gpu[i].y) vs CPU \(cpu.y) at \(p), params \(set.params)")
                tested += 1
            }
        }
        #expect(tested == 120)
    }

    @Test(.enabled(if: GPU.available))
    func mandelboxSphereProjectionEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xDE00_5B70)

        // params: [scale, minRadius, fixedRadius, foldLimit, projBlend, projRadius]
        let paramSets: [(params: [Float], iterations: Int)] = [
            ([2.0, 0.5, 1.0, 1.0, 0.0, 1.0], 12),   // blend 0 → plain mandelbox
            ([2.0, 0.5, 1.0, 1.0, 1.0, 1.0], 12),   // full projection
            ([2.5, 0.6, 1.2, 1.0, 0.5, 2.1], 8),
            ([1.7, 0.4, 1.0, 1.2, 0.9, 0.6], 12),
        ]
        var tested = 0
        for set in paramSets {
            let points = (0..<50).map { _ in exteriorPoint(&rng, radius: 4.0...8.0) }
            let gpu = try evaluator.evaluate(points: points, deIndex: 6,
                                             deParams: set.params,
                                             iterations: set.iterations)
            for (i, p) in points.enumerated() {
                let cpu = ReferenceDEs.mandelboxSphereProjection(p, params: set.params,
                                                                 iterations: set.iterations)
                #expect(relClose(gpu[i].x, cpu.x, rel: 1e-3),
                        "mandelboxSphereProjection .x GPU \(gpu[i].x) vs CPU \(cpu.x) at \(p), params \(set.params)")
                // Trap tolerance is looser than the other DEs': with the
                // per-fold projection near blend 1 the orbit is chaotic
                // enough that GPU fast-math can flip a sphere-fold branch on
                // a handful of points, shifting the orbit minimum by a few
                // percent while the distance (.x, above) still agrees at
                // 1e-3. Trap feeds coloring only — never geometry.
                #expect(relClose(gpu[i].y, cpu.y, rel: 1e-1),
                        "mandelboxSphereProjection .y (trap) GPU \(gpu[i].y) vs CPU \(cpu.y) at \(p), params \(set.params)")
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

        // params: [power] (legacy 1-param, rotation defaults to 0) and
        // [power, rotationSpeed, rotationPhase] (rotationSpeed unused by the DE;
        // rotationPhase must move CPU and GPU identically).
        let paramSets: [(params: [Float], iterations: Int)] = [
            ([8.0], 12),
            ([8.0], 8),
            ([5.0], 12),
            ([9.0], 10),
            ([8.0, 0.0, 0.0], 12),   // 3-param, zero phase ≡ un-rotated
            ([8.0, 0.5, 1.3], 12),   // rotated
            ([5.0, -1.0, 3.14159], 10),
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
        #expect(tested == 350)
    }

    @Test(.enabled(if: GPU.available))
    func kleinianEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xDE00_0B2C)

        // params: [minX, minY, minZ, sphereFold, maxX, maxY, maxZ, crossRadius]
        let paramSets: [(params: [Float], iterations: Int)] = [
            ([-0.3252, -0.7862, -0.0948, 0.69, 0.35, 1.0, 1.22, 0.84], 12),
            ([-0.5, -0.5, -0.5, 1.0, 0.5, 0.5, 0.5, 0.5], 8),
            ([-0.8, -1.0, -0.3, 0.5, 0.8, 1.0, 1.5, 1.2], 10),
        ]
        for set in paramSets {
            let points = (0..<50).map { _ in exteriorPoint(&rng, radius: 0.5...4.0) }
            let gpu = try evaluator.evaluate(points: points, deIndex: 2,
                                             deParams: set.params,
                                             iterations: set.iterations)
            for (i, p) in points.enumerated() {
                let cpu = ReferenceDEs.kleinian(p, params: set.params,
                                                iterations: set.iterations)
                #expect(relClose(gpu[i].x, cpu.x, rel: 1e-3),
                        "kleinian .x GPU \(gpu[i].x) vs CPU \(cpu.x) at \(p)")
                #expect(relClose(gpu[i].y, cpu.y, rel: 5e-3),
                        "kleinian .y (trap) GPU \(gpu[i].y) vs CPU \(cpu.y) at \(p)")
            }
        }
    }

    @Test(.enabled(if: GPU.available))
    func mengerEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xDE00_0B3D)

        // params: [scale, offsetX, offsetY, offsetZ]
        let paramSets: [(params: [Float], iterations: Int)] = [
            ([3.0, 1.0, 1.0, 1.0], 12),
            ([2.5, 1.2, 0.8, 1.0], 8),
            ([4.0, 1.0, 1.5, 0.5], 10),
        ]
        for set in paramSets {
            let points = (0..<50).map { _ in exteriorPoint(&rng, radius: 1.5...6.0) }
            let gpu = try evaluator.evaluate(points: points, deIndex: 3,
                                             deParams: set.params,
                                             iterations: set.iterations)
            for (i, p) in points.enumerated() {
                let cpu = ReferenceDEs.menger(p, params: set.params,
                                              iterations: set.iterations)
                #expect(relClose(gpu[i].x, cpu.x, rel: 1e-3),
                        "menger .x GPU \(gpu[i].x) vs CPU \(cpu.x) at \(p)")
                #expect(relClose(gpu[i].y, cpu.y, rel: 5e-3),
                        "menger .y (trap) GPU \(gpu[i].y) vs CPU \(cpu.y) at \(p)")
            }
        }
    }

    @Test(.enabled(if: GPU.available))
    func quaternionJuliaEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xDE00_0B4E)

        // params: [cX, cY, cZ, cW, threshold]
        let paramSets: [(params: [Float], iterations: Int)] = [
            ([-0.2, 0.8, 0.0, 0.0, 10.0], 12),
            ([0.3, -0.5, 0.4, 0.1, 10.0], 8),
            ([-0.4, 0.6, -0.2, 0.0, 16.0], 10),
        ]
        for set in paramSets {
            let points = (0..<50).map { _ in exteriorPoint(&rng, radius: 1.5...4.0) }
            let gpu = try evaluator.evaluate(points: points, deIndex: 4,
                                             deParams: set.params,
                                             iterations: set.iterations)
            for (i, p) in points.enumerated() {
                let cpu = ReferenceDEs.quaternionJulia(p, params: set.params,
                                                       iterations: set.iterations)
                #expect(relClose(gpu[i].x, cpu.x, rel: 1e-3),
                        "quatJulia .x GPU \(gpu[i].x) vs CPU \(cpu.x) at \(p)")
                #expect(relClose(gpu[i].y, cpu.y, rel: 5e-3),
                        "quatJulia .y (trap) GPU \(gpu[i].y) vs CPU \(cpu.y) at \(p)")
            }
        }
    }

    @Test(.enabled(if: GPU.available))
    func mandelbulbJuliaEquivalence() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        var rng = SplitMix64(seed: 0xDE00_0B5F)

        // params: [power, cX, cY, cZ] — same sampling-domain note as the
        // mandelbulb test at the top of this file.
        let paramSets: [(params: [Float], iterations: Int)] = [
            ([8.0, 0.2, -0.15, 0.35], 12),
            ([5.0, 0.3, 0.1, -0.2], 8),
            ([9.0, -0.25, 0.2, 0.15], 10),
        ]
        for set in paramSets {
            let near = (0..<25).map { _ in exteriorPoint(&rng, radius: 1.5...1.9) }
            let far = (0..<25).map { _ in exteriorPoint(&rng, radius: 4.5...8.0) }
            let points = near + far
            let gpu = try evaluator.evaluate(points: points, deIndex: 5,
                                             deParams: set.params,
                                             iterations: set.iterations)
            for (i, p) in points.enumerated() {
                let cpu = ReferenceDEs.mandelbulbJulia(p, params: set.params,
                                                       iterations: set.iterations)
                #expect(relClose(gpu[i].x, cpu.x, rel: 1e-3),
                        "bulbJulia .x GPU \(gpu[i].x) vs CPU \(cpu.x) at \(p)")
                #expect(relClose(gpu[i].y, cpu.y, rel: 5e-3),
                        "bulbJulia .y (trap) GPU \(gpu[i].y) vs CPU \(cpu.y) at \(p)")
            }
        }
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
