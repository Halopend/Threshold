// CoxeterDomainTests.swift — review-regression pin: Coxeter mirror normals
// must be unit-length for EVERY {P,Q} a scene file can carry, including
// Euclidean/hyperbolic symbols (1/P + 1/Q <= 1/2) where the pre-fix code
// produced a non-unit n3 and an expansive, divergent "reflection".

import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdShaderIR

@Suite("Coxeter domain robustness")
struct CoxeterDomainSuite {
    /// Reflections preserve length; a full-strength Coxeter fold is a
    /// composition of reflections, so |T(p)| == |p| for ANY symbol. With a
    /// non-unit mirror this fails immediately.
    @Test("Fold preserves |p| for spherical, Euclidean, and hyperbolic symbols")
    func normPreservation() {
        var rng = SplitMix64(seed: 0xC0C5E7E5)
        let symbols: [(Int, Int)] = [
            (3, 3), (4, 3), (5, 3), (3, 5),  // spherical
            (4, 4), (6, 3), (3, 6),          // Euclidean boundary
            (5, 4), (4, 5), (7, 3),          // hyperbolic
        ]
        for (p, q) in symbols {
            let op = ThreshWarpOp.coxeter(p: p, q: q, strength: 1)
            for _ in 0..<50 {
                let point = rng.point(in: -2...2)
                let (folded, dScale) = ReferenceOps.applyPointOps(point, ops: [op])
                #expect(
                    abs(simd_length(folded) - simd_length(point)) <= 1e-3 * max(1, simd_length(point)),
                    "{\(p),\(q)} fold changed |p|")
                #expect(dScale == 1, "{\(p),\(q)} fold reported non-isometric dScale")
                #expect(folded.x.isFinite && folded.y.isFinite && folded.z.isFinite)
            }
        }
    }
}
