// TestSupport.swift — shared helpers for the ThresholdShaderIR test suite.
//
// SplitMix64: tiny deterministic PRNG. We never use
// SystemRandomNumberGenerator — every property-style test is reproducible
// from its seed.

import simd
import ThresholdShaderABI
@testable import ThresholdShaderIR

// MARK: - Deterministic PRNG

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        Float.random(in: range, using: &self)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func bool(probability: Double = 0.5) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }

    mutating func point(in range: ClosedRange<Float>) -> SIMD3<Float> {
        SIMD3(float(in: range), float(in: range), float(in: range))
    }

    /// Uniform-ish random unit vector (rejection-free: normalize a cube
    /// sample away from zero).
    mutating func unitVector() -> SIMD3<Float> {
        var v = point(in: -1...1)
        while simd_length(v) < 1e-3 { v = point(in: -1...1) }
        return simd_normalize(v)
    }
}

// MARK: - Numeric differentiation

/// Columns of the numeric Jacobian of `f` at `p` (central differences).
func jacobianColumns(
    of f: (SIMD3<Float>) -> SIMD3<Float>,
    at p: SIMD3<Float>,
    h: Float = 1e-3
) -> [SIMD3<Float>] {
    (0..<3).map { i in
        var lo = p, hi = p
        hi[i] += h
        lo[i] -= h
        return (f(hi) - f(lo)) / (2 * h)
    }
}

/// Directional expansion |J v| / |v| via central differences.
func directionalExpansion(
    of f: (SIMD3<Float>) -> SIMD3<Float>,
    at p: SIMD3<Float>,
    along v: SIMD3<Float>,
    h: Float = 1e-3
) -> Float {
    let u = simd_normalize(v)
    return simd_length(f(p + u * h) - f(p - u * h)) / (2 * h)
}

/// Max directional expansion over the canonical axes plus `extra` sampled
/// random directions — a sampled lower bound on the Jacobian spectral norm.
func sampledMaxExpansion(
    of f: (SIMD3<Float>) -> SIMD3<Float>,
    at p: SIMD3<Float>,
    rng: inout SplitMix64,
    extraDirections extra: Int = 12
) -> Float {
    var dirs: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
    for _ in 0..<extra { dirs.append(rng.unitVector()) }
    return dirs.map { directionalExpansion(of: f, at: p, along: $0) }.max()!
}

// MARK: - Comparison helpers

/// Hybrid absolute/relative closeness: |x - y| <= tol · max(1, |x|, |y|).
func close(_ x: Float, _ y: Float, tol: Float = 1e-3) -> Bool {
    abs(x - y) <= tol * max(1, max(abs(x), abs(y)))
}

func close(_ x: SIMD3<Float>, _ y: SIMD3<Float>, tol: Float = 1e-3) -> Bool {
    simd_length(x - y) <= tol * max(1, max(simd_length(x), simd_length(y)))
}

// MARK: - Op evaluation shorthand

/// The point map of a single op (for Jacobian probing).
func pointMap(_ op: ThreshWarpOp) -> (SIMD3<Float>) -> SIMD3<Float> {
    { ReferenceOps.applyPointOps($0, ops: [op]).p }
}

/// The reported dScale of a single op at `p`.
func reportedDScale(_ op: ThreshWarpOp, at p: SIMD3<Float>) -> Float {
    ReferenceOps.applyPointOps(p, ops: [op]).dScale
}
