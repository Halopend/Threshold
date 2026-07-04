// ReferenceOps.swift — the CPU reference implementation of the warp op
// semantics. docs/op-semantics.md is NORMATIVE: this file and the MSL
// interpreter (ThresholdRender/MSL/RaymarchCore.metal) both implement
// that document independently and are cross-checked by sampled-equivalence
// tests. If this file disagrees with the document, this file is wrong.
//
// This is the oracle for the simplifier tests, for golden-image triage, and
// for Invariant 7 (normals/secondary rays reuse applyOps — proven by testing
// the GPU against this).
//
// Pipeline per march step (docs/op-semantics.md):
//
//   (p', dScale) = applyPointOps(worldP, ops)
//   d = de_main(p', ctx).x / dScale
//   d = applyDistanceOps(worldP, d, ops)
//
// dScale accumulation: isometric ops contribute nothing; conformal ops
// multiply the EXACT factor unclamped (sphere inversion inside the sphere
// legitimately shrinks the estimate); Lipschitz-approximated ops multiply
// `max(1, factor)`.

import simd
import ThresholdShaderABI

public enum ReferenceOps {
    // MARK: - Public API

    /// Apply all POINT ops (kind < 64) in stack order to `p`. Distance ops,
    /// `None`, and unknown kinds are skipped (unknown = forward-compatible
    /// no-op). Returns the transformed point and the accumulated
    /// distance-scale divisor (initialized 1).
    public static func applyPointOps(
        _ p: SIMD3<Float>,
        ops: [ThreshWarpOp]
    ) -> (p: SIMD3<Float>, dScale: Float) {
        var q = p
        var dScale: Float = 1
        for op in ops {
            guard let kind = op.warpKind, kind.isPointOp else { continue }
            q = applyPointOp(kind, op, q, &dScale)
        }
        return (q, dScale)
    }

    /// Apply all DISTANCE ops (kind >= 64) in stack order to the resolved SDF
    /// value `distance`. Receives the ORIGINAL world-space point — a hand is
    /// at a world position; it must not be dragged through the folds.
    public static func applyDistanceOps(
        _ worldP: SIMD3<Float>,
        distance: Float,
        ops: [ThreshWarpOp]
    ) -> Float {
        var d = distance
        for op in ops {
            guard let kind = op.warpKind, kind.isDistanceOp else { continue }
            switch kind {
            case .handAttract:
                d = handAttract(worldP, d, op)
            case .forearmCarve:
                d = forearmCarve(worldP, d, op)
            case .bounding:
                // Only FIXED bounds (OPTION_B) are world-space distance ops;
                // in-stack bounds are captured during the point walk (see
                // `mapBounds`). Skip in-stack bounds here to avoid double apply.
                if op.warpFlags.contains(.optionB) {
                    d = boundingFixed(worldP, d, op)
                }
            default:
                break
            }
        }
        return d
    }

    /// CPU oracle for the IN-STACK Bounding fold (§66). Replays the point-op
    /// walk (modelScale = 1, dScale seeded 1) to capture each in-stack bound's
    /// world-space distance in its transformed frame — `sdSolid(p)/dScale`,
    /// the same conversion as `d = de.x/dScale` — then folds them into
    /// `baseDistance` in stack order. Mirrors the GPU `eval_bounds` kernel and
    /// the in-stack path of `mapScene`. FIXED bounds (OPTION_B) are skipped
    /// here — they are world-space distance ops (`applyDistanceOps`).
    public static func mapBounds(
        _ worldP: SIMD3<Float>,
        baseDistance: Float,
        ops: [ThreshWarpOp]
    ) -> Float {
        var p = worldP
        var dScale: Float = 1
        var captures: [(bw: Float, soft: Float, strength: Float, subtract: Bool)] = []
        for op in ops {
            guard let kind = op.warpKind else { continue }
            if kind == .bounding {
                if !op.warpFlags.contains(.optionB) {
                    let bw = sdSolid(p, op.a.y, op.a.x) / dScale
                    captures.append((bw, max(op.a.z, 1e-4), op.strength,
                                     op.warpFlags.contains(.optionA)))
                }
                continue
            }
            guard kind.isPointOp else { continue }
            p = applyPointOp(kind, op, p, &dScale)
        }
        var d = baseDistance
        for c in captures {
            let csg = smax(d, c.subtract ? -c.bw : c.bw, c.soft)
            d = lerpScalar(d, csg, c.strength)
        }
        return d
    }

    // MARK: - Point op dispatch

    private static func applyPointOp(
        _ kind: WarpKind,
        _ op: ThreshWarpOp,
        _ p: SIMD3<Float>,
        _ dScale: inout Float
    ) -> SIMD3<Float> {
        let s = op.strength
        switch kind {
        case .twist:
            // t = dot(p, n̂); p' = rot(p, n̂, s·t); dScale *= max(1, √(1+(s·r⊥)²))
            let n = normalizedAxis(op.a.xyz)
            let t = dot(p, n)
            let out = rot(p, n, s * t)
            let rPerp = length(p - n * t)
            dScale *= max(1, (1 + (s * rPerp) * (s * rPerp)).squareRoot())
            return out

        case .bend:
            // θ = s·dot(p, ĉ); p' = rot(p, n̂, θ); r⊥ over the full perpendicular
            let n = normalizedAxis(op.a.xyz)
            let c = perpOf(n)
            let theta = s * dot(p, c)
            let out = rot(p, n, theta)
            let rPerp = length(p - n * dot(p, n))
            dScale *= max(1, (1 + (s * rPerp) * (s * rPerp)).squareRoot())
            return out

        case .ripple:
            // p' = p + n̂·s·sin(f·dot(p, ĉ)); dScale *= 1 + |s·f|
            let n = normalizedAxis(op.a.xyz)
            let c = perpOf(n)
            let f = op.a.w
            let out = p + n * (s * sin(f * dot(p, c)))
            dScale *= 1 + abs(s * f)
            return out

        case .mirror:
            // p' = lerp(p, |p|, s). Isometric at s = 1.
            return lerp(p, abs(p), s)

        case .boxFold:
            // Classic fold or Hall-of-Mirrors triangle wave (flag OPTION_A).
            let limit = op.a.x
            let folded: SIMD3<Float>
            if op.warpFlags.contains(.optionA) {
                folded = SIMD3(
                    hallOfMirrors(p.x, limit),
                    hallOfMirrors(p.y, limit),
                    hallOfMirrors(p.z, limit)
                )
            } else {
                let l3 = SIMD3<Float>(repeating: limit)
                folded = simd_clamp(p, -l3, l3) * 2 - p
            }
            return lerp(p, folded, s) // isometric at s = 1, no dScale term

        case .planeFold:
            // Reflect points behind the plane dot(p, n̂) = dist.
            let n = normalizedAxis(op.a.xyz)
            let h = dot(p, n) - op.a.w
            guard h < 0 else { return p }
            return lerp(p, p - 2 * h * n, s)

        case .kaleidoscope:
            // Fold the polar angle of p.xz into one wedge of width 2π/N.
            let segments = op.a.x
            let theta = atan2f(p.z, p.x)
            let r = length(SIMD2(p.x, p.z))
            let w = Float.pi / segments
            let thetaF = abs(fmodFloor(theta + w, 2 * w) - w)
            let thetaP = lerpScalar(theta, thetaF, s)
            return SIMD3(r * cosf(thetaP), p.y, r * sinf(thetaP))

        case .coxeter:
            // {P,Q} rank-3 reflection-group fold, mirror normals from the
            // Gram matrix; iterate up to 24 times with early stop.
            let symP = op.a.x
            let symQ = op.a.y
            let sinP = sinf(.pi / symP)
            let n1 = SIMD3<Float>(1, 0, 0)
            let n2 = SIMD3<Float>(-cosf(.pi / symP), sinP, 0)
            let c = cosf(.pi / symQ) / sinP
            // Normalized (op-semantics): for Euclidean/hyperbolic {P,Q}
            // (c > 1) the ε-clamp yields a NON-unit vector, and a non-unit
            // mirror makes the "reflection" expansive — the fold loop can
            // diverge. Normalized, every reflection is a true isometry for
            // ANY payload a scene file can carry.
            let n3 = simd_normalize(SIMD3<Float>(0, -c, (max(1e-6, 1 - c * c)).squareRoot()))
            var q = p
            for _ in 0..<24 {
                var reflected = false
                let d1 = dot(q, n1)
                if d1 < 0 { q -= 2 * d1 * n1; reflected = true }
                let d2 = dot(q, n2)
                if d2 < 0 { q -= 2 * d2 * n2; reflected = true }
                let d3 = dot(q, n3)
                if d3 < 0 { q -= 2 * d3 * n3; reflected = true }
                if !reflected { break }
            }
            return lerp(p, q, s) // isometric at s = 1

        case .mengerFold:
            // q = |p| sorted descending; p' = lerp(p, q, s).
            var q = abs(p)
            if q.x < q.y { let t = q.x; q.x = q.y; q.y = t }
            if q.x < q.z { let t = q.x; q.x = q.z; q.z = t }
            if q.y < q.z { let t = q.y; q.y = q.z; q.z = t }
            return lerp(p, q, s)

        case .offsetFold:
            // p' = lerp(p, |p - c| + c, s).
            let c = op.a.xyz
            return lerp(p, abs(p - c) + c, s)

        case .sphereFold:
            // Mandelbox sphere fold — conformal in each region, EXACT,
            // UNCLAMPED dScale.
            let k = lerpScalar(1, sphereFoldFactor(r2: dot(p, p), minR: op.a.x, fixedR: op.a.y), s)
            dScale *= k
            return p * k

        case .sphereInvert:
            // Conformal inversion — exact, unclamped.
            let radius = op.a.x
            let r2 = max(dot(p, p), 1e-12)
            let k = lerpScalar(1, radius * radius / r2, s)
            dScale *= k
            return p * k

        case .tubeFold:
            // SphereFold restricted to the XZ plane — non-conformal
            // (in-plane only): Lipschitz, clamped.
            let r2 = p.x * p.x + p.z * p.z
            let k = lerpScalar(1, sphereFoldFactor(r2: r2, minR: op.a.x, fixedR: op.a.y), s)
            dScale *= max(1, k)
            return SIMD3(p.x * k, p.y, p.z * k)

        case .shells:
            // Fold radius to the nearest concentric shell. No dScale term.
            let spacing = op.a.x
            let r = length(p)
            let rF = abs(fmodFloor(r, 2 * spacing) - spacing)
            let k = lerpScalar(1, rF / max(r, 1e-9), s)
            return p * k

        case .scaleRepeat:
            // Log-radial Droste: m = k^(n·s). Conformal — exact, unclamped
            // (1/m: for r > 1, m > 1 → the estimate GROWS; that is the point
            // of Droste zoom).
            let factor = op.a.x
            let r = length(p)
            let n = floorf(logf(max(r, 1e-9)) / logf(factor))
            let m = powf(factor, n * s)
            dScale *= 1 / m
            return p / m

        case .tiling:
            // Infinite lattice repeat, per enabled axis (mask ≥ 0.5).
            let cell = op.a.x
            var q = p
            if op.b.x >= 0.5 { q.x = fmodFloor(p.x + cell / 2, cell) - cell / 2 }
            if op.b.y >= 0.5 { q.y = fmodFloor(p.y + cell / 2, cell) - cell / 2 }
            if op.b.z >= 0.5 { q.z = fmodFloor(p.z + cell / 2, cell) - cell / 2 }
            return lerp(p, q, s) // isometric at s = 1

        case .scale:
            // Uniform domain scale — conformal, exact, unclamped.
            let m = lerpScalar(1, op.a.x, s)
            dScale *= 1 / m
            return p / m

        case .sphereProject:
            // Radial compression toward the shell — Lipschitz, clamped.
            let radius = op.a.x
            let r = length(p)
            let rP = lerpScalar(r, radius, s)
            let ratio = rP / max(r, 1e-9)
            dScale *= max(1, ratio)
            return p * ratio

        case .none, .handAttract, .forearmCarve, .bounding:
            return p // unreachable through applyPointOps' guard
        }
    }

    /// Shared Mandelbox sphere-fold region rule:
    /// fR²/mR² inside minRadius, fR²/r² in the shell, 1 outside.
    private static func sphereFoldFactor(r2: Float, minR: Float, fixedR: Float) -> Float {
        let mR2 = minR * minR
        let fR2 = fixedR * fixedR
        if r2 < mR2 { return fR2 / mR2 }
        if r2 < fR2 { return fR2 / r2 }
        return 1
    }

    // MARK: - Distance ops

    private static func handAttract(_ p: SIMD3<Float>, _ d: Float, _ op: ThreshWarpOp) -> Float {
        let s = op.strength
        let center = op.a.xyz
        let radius = op.a.w
        let sphere = length(p - center) - radius * op.b.x
        let k = max(op.b.y, 1e-4)
        var out = d
        if s > 0 {
            out = lerpScalar(d, smin(d, sphere, k), s)
        } else if s < 0 {
            out = lerpScalar(d, smax(d, -sphere, k), -s)
        }
        // Pocket: flag set AND attracting.
        if op.warpFlags.contains(.optionA) && s > 0 {
            let pocket = length(p - center) - radius * op.b.z
            out = lerpScalar(out, smax(out, -pocket, max(op.b.w, 1e-4)), s)
        }
        return out
    }

    private static func forearmCarve(_ p: SIMD3<Float>, _ d: Float, _ op: ThreshWarpOp) -> Float {
        // ALWAYS subtractive; |s| is the amount (no sign field, structurally).
        let pa = p - op.a.xyz
        let ba = op.b.xyz - op.a.xyz
        let h = simd_clamp(dot(pa, ba) / max(dot(ba, ba), 1e-9), 0, 1)
        let cap = length(pa - ba * h) - op.a.w
        return lerpScalar(d, smax(d, -cap, max(op.b.w, 1e-4)), abs(op.strength))
    }

    /// FIXED (world-space) Bounding op: CSG the fractal against a solid at
    /// `b.xyz`. `a.x` shape, `a.y` scale, `a.z` softness; OPTION_A = subtract
    /// (carve out) vs intersect (keep inside). `strength` blends identity→full.
    /// Mirrors the MSL `ThreshWarpKindBounding` case in `applyDistanceOps`.
    static func boundingFixed(_ p: SIMD3<Float>, _ d: Float, _ op: ThreshWarpOp) -> Float {
        let bw = sdSolid(p - op.b.xyz, op.a.y, op.a.x)
        let k = max(op.a.z, 1e-4)
        let s = op.strength
        if op.warpFlags.contains(.optionA) {
            return lerpScalar(d, smax(d, -bw, k), s)   // subtract
        } else {
            return lerpScalar(d, smax(d,  bw, k), s)   // intersect
        }
    }

    // MARK: - Bounding solid SDF (docs/op-semantics.md §66)

    /// Signed distance to an axis-aligned cube of half-extent `r` (IQ box SDF).
    /// Mirrors the MSL `bubbleCube`.
    static func boxSDF(_ p: SIMD3<Float>, _ r: Float) -> Float {
        let d = abs(p) - SIMD3<Float>(repeating: r)
        let outside = SIMD3<Float>(max(d.x, 0), max(d.y, 0), max(d.z, 0))
        return length(outside) + min(max(d.x, max(d.y, d.z)), 0)
    }

    /// Signed distance to a shape centred at the origin, half-extent `r`.
    /// Mirrors the MSL `sdSolid` EXACTLY (same constants + `int(clamp(shape +
    /// 0.5, 2, 6))` dispatch) — the CPU oracle for the Bounding warp op and the
    /// safety bubble. `shape` 0..1 morphs sphere→cube; 2..6 select platonic
    /// solids (tetra / rounded-cube / octa / icosa / dodeca).
    static func sdSolid(_ p: SIMD3<Float>, _ r: Float, _ shape: Float) -> Float {
        let sphereDist = length(p) - r
        let cubeDist = boxSDF(p, r)
        if shape <= 1 {
            return lerpScalar(sphereDist, cubeDist, simd_clamp(shape, 0, 1))
        }
        let invSqrt3: Float = 0.5773502691896258
        let phi: Float = 1.618033988749895
        let invPhiLen: Float = 0.5257311121191336
        let axisScale: Float = 0.85065080835204
        let q = abs(p)
        switch Int(simd_clamp(shape + 0.5, 2, 6)) {
        case 2:   // tetrahedron
            let faceOffset = r * invSqrt3
            let d1 = dot(p, SIMD3<Float>( invSqrt3,  invSqrt3,  invSqrt3))
            let d2 = dot(p, SIMD3<Float>( invSqrt3, -invSqrt3, -invSqrt3))
            let d3 = dot(p, SIMD3<Float>(-invSqrt3,  invSqrt3, -invSqrt3))
            let d4 = dot(p, SIMD3<Float>(-invSqrt3, -invSqrt3,  invSqrt3))
            return max(max(d1, d2), max(d3, d4)) - faceOffset
        case 3:   // rounded ("negative") cube via superquadric
            let exponent: Float = 0.65
            let s = q / max(r, 1e-4)
            let sd = powf(powf(s.x, exponent) + powf(s.y, exponent) + powf(s.z, exponent),
                          1 / exponent)
            return (sd - 1) * r
        case 4:   // octahedron
            return (q.x + q.y + q.z - r) * invSqrt3
        case 5:   // icosahedron
            let d1 = dot(q, SIMD3<Float>(1, 1, 1) * invSqrt3)
            let d2 = dot(q, SIMD3<Float>(0, 1, phi) * invPhiLen)
            let d3 = dot(q, SIMD3<Float>(1, phi, 0) * invPhiLen)
            let d4 = dot(q, SIMD3<Float>(phi, 0, 1) * invPhiLen)
            return max(max(d1, d2), max(d3, d4)) - r * axisScale
        case 6:   // dodecahedron
            let d1 = dot(q, SIMD3<Float>(phi, 1, 0) * invPhiLen)
            let d2 = dot(q, SIMD3<Float>(1, 0, phi) * invPhiLen)
            let d3 = dot(q, SIMD3<Float>(0, phi, 1) * invPhiLen)
            return max(d1, max(d2, d3)) - r * axisScale
        default:
            return cubeDist
        }
    }

    // MARK: - Common helpers (docs/op-semantics.md "Common helpers")

    /// Payload axes are stored unnormalized; normalize on read and treat
    /// near-zero axes (|axis| < 1e-6) as +Y.
    static func normalizedAxis(_ raw: SIMD3<Float>) -> SIMD3<Float> {
        let len = length(raw)
        guard len >= 1e-6 else { return SIMD3(0, 1, 0) }
        return raw / len
    }

    /// Deterministic perpendicular to unit axis n:
    /// `normalize(cross(n, |n.y| < 0.9 ? (0,1,0) : (1,0,0)))`.
    static func perpOf(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let ref: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        return normalize(cross(n, ref))
    }

    /// Rodrigues rotation of `v` around unit axis `n` by angle `t`.
    static func rot(_ v: SIMD3<Float>, _ n: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let cosT = cosf(t)
        let sinT = sinf(t)
        return v * cosT + cross(n, v) * sinT + n * (dot(n, v) * (1 - cosT))
    }

    /// Polynomial smooth min (IQ), k > 0:
    /// `h = max(k - |x - y|, 0)/k; min(x, y) - h²k/4`.
    static func smin(_ x: Float, _ y: Float, _ k: Float) -> Float {
        let h = max(k - abs(x - y), 0) / k
        return min(x, y) - h * h * k / 4
    }

    /// `smax(x, y, k) = -smin(-x, -y, k)`.
    static func smax(_ x: Float, _ y: Float, _ k: Float) -> Float {
        -smin(-x, -y, k)
    }

    /// GLSL-style floored mod (result in [0, m) for m > 0).
    static func fmodFloor(_ x: Float, _ m: Float) -> Float {
        x - m * floorf(x / m)
    }

    /// Hall of Mirrors per-axis triangle wave, period 4L, range [-L, L]:
    /// `|mod(x + L, 4L) - 2L| - L`.
    static func hallOfMirrors(_ x: Float, _ limit: Float) -> Float {
        abs(fmodFloor(x + limit, 4 * limit) - 2 * limit) - limit
    }

    /// `lerp(x, y, t) = x + (y - x)t`.
    static func lerp(_ x: SIMD3<Float>, _ y: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        x + (y - x) * t
    }

    static func lerpScalar(_ x: Float, _ y: Float, _ t: Float) -> Float {
        x + (y - x) * t
    }
}
