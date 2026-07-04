// TestSupport.swift — shared fixtures for ThresholdRender tests.
//
// SplitMix64: tiny deterministic PRNG — every "random" test is reproducible
// from its seed; SystemRandomNumberGenerator is never used.

import Foundation
import Metal
import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdRender

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

    /// Random point in the cube, nudged off the exact origin (several ops
    /// have 1e-9/1e-12 guards there; the guards themselves are exercised by
    /// dedicated payload edge cases, not by lottery).
    mutating func point(in range: ClosedRange<Float> = -2.5...2.5) -> SIMD3<Float> {
        var p = SIMD3(float(in: range), float(in: range), float(in: range))
        if simd_length(p) < 1e-3 { p.x += 0.25 }
        return p
    }

    mutating func unitVector() -> SIMD3<Float> {
        var v = SIMD3<Float>.zero
        repeat {
            v = SIMD3(float(in: -1...1), float(in: -1...1), float(in: -1...1))
        } while simd_length(v) < 1e-3
        return simd_normalize(v)
    }
}

// MARK: - Shared GPU fixture
//
// One runtime shader compile per process; GPUContext is (audited) Sendable so
// a static let is legal under strict concurrency. Tests that need the GPU are
// gated with `.enabled(if: GPU.available)` — on a machine with no Metal
// device they record as skipped, not failed.

enum GPU {
    static let available: Bool = MTLCreateSystemDefaultDevice() != nil
    static let context: Result<GPUContext, any Error> = Result { try GPUContext() }
    static func ctx() throws -> GPUContext { try context.get() }
}

// MARK: - Warp op construction
//
// ThresholdShaderIR's typed builders are the app-facing API; the tests build
// raw ABI structs directly so the GPU interpreter is exercised against the
// exact bytes the encoder would produce.

/// Raw kind values (ThreshWarpKind imports with a platform-dependent
/// RawValue integer type; pin UInt32 once here).
enum WK {
    static let none = UInt32(ThreshWarpKindNone.rawValue)
    static let twist = UInt32(ThreshWarpKindTwist.rawValue)
    static let bend = UInt32(ThreshWarpKindBend.rawValue)
    static let ripple = UInt32(ThreshWarpKindRipple.rawValue)
    static let mirror = UInt32(ThreshWarpKindMirror.rawValue)
    static let boxFold = UInt32(ThreshWarpKindBoxFold.rawValue)
    static let planeFold = UInt32(ThreshWarpKindPlaneFold.rawValue)
    static let kaleidoscope = UInt32(ThreshWarpKindKaleidoscope.rawValue)
    static let coxeter = UInt32(ThreshWarpKindCoxeter.rawValue)
    static let mengerFold = UInt32(ThreshWarpKindMengerFold.rawValue)
    static let offsetFold = UInt32(ThreshWarpKindOffsetFold.rawValue)
    static let sphereFold = UInt32(ThreshWarpKindSphereFold.rawValue)
    static let sphereInvert = UInt32(ThreshWarpKindSphereInvert.rawValue)
    static let tubeFold = UInt32(ThreshWarpKindTubeFold.rawValue)
    static let shells = UInt32(ThreshWarpKindShells.rawValue)
    static let scaleRepeat = UInt32(ThreshWarpKindScaleRepeat.rawValue)
    static let tiling = UInt32(ThreshWarpKindTiling.rawValue)
    static let scale = UInt32(ThreshWarpKindScale.rawValue)
    static let sphereProject = UInt32(ThreshWarpKindSphereProject.rawValue)
    static let handAttract = UInt32(ThreshWarpKindHandAttract.rawValue)
    static let forearmCarve = UInt32(ThreshWarpKindForearmCarve.rawValue)
    static let bounding = UInt32(ThreshWarpKindBounding.rawValue)

    /// THRESH_WARP_FLAG_OPTION_A — the shifted-literal macro does not import
    /// into Swift; value pinned here (BoxFold: HoM, HandAttract: pocket,
    /// Bounding: subtract).
    static let flagOptionA: UInt32 = 1 << 0
    /// THRESH_WARP_FLAG_OPTION_B — Bounding: FIXED world-space placement.
    static let flagOptionB: UInt32 = 1 << 3

    static let allPointKinds: [UInt32] = [
        twist, bend, ripple, mirror, boxFold, planeFold, kaleidoscope, coxeter,
        mengerFold, offsetFold, sphereFold, sphereInvert, tubeFold, shells,
        scaleRepeat, tiling, scale, sphereProject,
    ]
}

func makeOp(_ kind: UInt32, s: Float,
            a: SIMD4<Float> = .zero, b: SIMD4<Float> = .zero,
            flags: UInt32 = 0) -> ThreshWarpOp {
    ThreshWarpOp(kind: kind, flags: flags, strength: s, _pad0: 0, a: a, b: b)
}

/// Random valid payload per point-op kind (docs/op-semantics.md payload
/// domains). Spherical-only Coxeter symbols: at the Euclidean boundary
/// (1/P + 1/Q = 1/2) the third mirror normal degenerates to the spec's
/// unspecified epsilon, which is exactly the kind of implementation-defined
/// corner the equivalence tests must not sample.
func randomPointOp(_ kind: UInt32, _ rng: inout SplitMix64) -> ThreshWarpOp {
    switch kind {
    case WK.twist, WK.bend:
        let axis = rng.unitVector() * rng.float(in: 0.5...2)
        return makeOp(kind, s: rng.float(in: -1.2...1.2), a: SIMD4(axis, 0))
    case WK.ripple:
        let axis = rng.unitVector() * rng.float(in: 0.5...2)
        return makeOp(kind, s: rng.float(in: -0.8...0.8),
                      a: SIMD4(axis, rng.float(in: 0.5...4)))
    case WK.mirror, WK.mengerFold:
        return makeOp(kind, s: rng.float(in: 0...1))
    case WK.boxFold:
        let flags: UInt32 = rng.bool(probability: 0.4) ? WK.flagOptionA : 0
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(rng.float(in: 0.3...2), 0, 0, 0), flags: flags)
    case WK.planeFold:
        let n = rng.unitVector() * rng.float(in: 0.5...2)
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(n, rng.float(in: -1...1)))
    case WK.kaleidoscope:
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(Float(rng.int(in: 1...12)), 0, 0, 0))
    case WK.coxeter:
        let symbols: [(Float, Float)] = [
            (2, 2), (2, 3), (2, 4), (2, 5), (2, 6),
            (3, 3), (3, 4), (4, 3), (3, 5), (5, 3),
        ]
        let (p, q) = symbols[rng.int(in: 0...(symbols.count - 1))]
        return makeOp(kind, s: rng.float(in: 0...1), a: SIMD4(p, q, 0, 0))
    case WK.offsetFold:
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(rng.point(in: -1...1), 0))
    case WK.sphereFold, WK.tubeFold:
        let minR = rng.float(in: 0.1...0.9)
        let fixR = minR + rng.float(in: 0.1...1.2)
        return makeOp(kind, s: rng.float(in: 0...1), a: SIMD4(minR, fixR, 0, 0))
    case WK.sphereInvert:
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(rng.float(in: 0.2...2), 0, 0, 0))
    case WK.shells:
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(rng.float(in: 0.2...1.5), 0, 0, 0))
    case WK.scaleRepeat:
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(rng.float(in: 1.5...3), 0, 0, 0))
    case WK.tiling:
        let mask = SIMD3<Float>(rng.bool() ? 1 : 0, rng.bool() ? 1 : 0,
                                rng.bool() ? 1 : 0)
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(rng.float(in: 0.5...2), 0, 0, 0), b: SIMD4(mask, 0))
    case WK.scale:
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(rng.float(in: 0.3...3), 0, 0, 0))
    case WK.sphereProject:
        return makeOp(kind, s: rng.float(in: 0...1),
                      a: SIMD4(rng.float(in: 0.5...2), 0, 0, 0))
    default:
        Issue.record("randomPointOp: unhandled kind \(kind)")
        return makeOp(WK.none, s: 0)
    }
}

// MARK: - Tolerances

/// Mixed relative/absolute closeness: below magnitude 1 the tolerance is
/// absolute (pure relative compare is meaningless next to 0).
func relClose(_ a: Float, _ b: Float, rel: Float) -> Bool {
    if a.isNaN || b.isNaN { return false }
    return abs(a - b) <= rel * max(1, abs(a), abs(b))
}

func relClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, rel: Float) -> Bool {
    if a.x.isNaN || a.y.isNaN || a.z.isNaN || b.x.isNaN || b.y.isNaN || b.z.isNaN {
        return false
    }
    return simd_length(a - b) <= rel * max(1, simd_length(a), simd_length(b))
}
