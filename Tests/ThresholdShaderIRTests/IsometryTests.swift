// IsometryTests.swift — property tests for the ops docs/op-semantics.md
// stamps "Isometric at s = 1": Mirror, BoxFold (incl. Hall of Mirrors),
// PlaneFold, Kaleidoscope, Coxeter, MengerFold, OffsetFold, Tiling.
//
// Two properties per kind:
//   1. EXACT local isometry: for nearby point pairs in the SAME fold piece
//      (away from crease boundaries), |T(p)-T(q)| == |p-q| within 1e-3
//      relative. "Same piece" is decided by a per-kind branch signature —
//      pairs whose piecewise branch decisions differ straddle a crease and
//      are skipped.
//   2. Global 1-Lipschitz: |T(p)-T(q)| <= |p-q|·(1 + 1e-3) for ARBITRARY
//      pairs. (Every fold here is a composition of conditional reflections /
//      slope-±1 continuous per-axis maps, all non-expansive.)
//      EXCEPTION: Tiling's sawtooth jumps by one cell across cell boundaries,
//      so it is locally isometric but NOT globally Lipschitz; its arbitrary-
//      pair check is restricted to same-cell pairs (where it is exact).

import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdShaderIR

/// One isometric-op scenario: the op at s = 1, a branch signature that
/// identifies the fold piece containing a point (nil = discard the sample,
/// e.g. too close to a singular locus), and whether global Lipschitz holds
/// for arbitrary pairs.
private struct IsoCase {
    let name: String
    let op: ThreshWarpOp
    let signature: (SIMD3<Float>) -> [Int]?
    let globallyLipschitz: Bool
}

private func gmod(_ x: Float, _ m: Float) -> Float { x - m * floorf(x / m) }

private func makeCases() -> [IsoCase] {
    var cases: [IsoCase] = []

    // Mirror — creases at the coordinate planes; piece = sign pattern.
    cases.append(IsoCase(
        name: "mirror",
        op: .mirror(strength: 1),
        signature: { p in [p.x < 0 ? 0 : 1, p.y < 0 ? 0 : 1, p.z < 0 ? 0 : 1] },
        globallyLipschitz: true))

    // BoxFold — creases at ±L per axis; piece = per-axis region index.
    let boxLimit: Float = 1.0
    cases.append(IsoCase(
        name: "boxFold",
        op: .boxFold(limit: boxLimit, strength: 1),
        signature: { p in
            (0..<3).map { i in
                let x = p[i]
                if x < -boxLimit { return 0 }
                if x > boxLimit { return 2 }
                return 1
            }
        },
        globallyLipschitz: true))

    // BoxFold Hall of Mirrors — triangle wave, period 4L; piece = per-axis
    // (cell index, side of the |·| kink).
    let homLimit: Float = 0.8
    cases.append(IsoCase(
        name: "boxFoldHallOfMirrors",
        op: .boxFold(limit: homLimit, hallOfMirrors: true, strength: 1),
        signature: { p in
            var sig: [Int] = []
            for i in 0..<3 {
                let period = 4 * homLimit
                sig.append(Int(floorf((p[i] + homLimit) / period)))
                sig.append(gmod(p[i] + homLimit, period) < 2 * homLimit ? 0 : 1)
            }
            return sig
        },
        globallyLipschitz: true))

    // PlaneFold — one crease at the plane; piece = side.
    let planeNormal = simd_normalize(SIMD3<Float>(0.3, 0.8, -0.5))
    let planeDist: Float = 0.25
    cases.append(IsoCase(
        name: "planeFold",
        op: .planeFold(normal: planeNormal, distance: planeDist, strength: 1),
        signature: { p in [simd_dot(p, planeNormal) - planeDist < 0 ? 0 : 1] },
        globallyLipschitz: true))

    // Kaleidoscope — creases at multiples of the wedge angle w = π/N; piece =
    // (wedge index, side of the fold). Points near the y-axis (tiny r.xz) are
    // discarded: the polar angle is numerically unstable there.
    for segments in [3, 5] {
        let w = Float.pi / Float(segments)
        cases.append(IsoCase(
            name: "kaleidoscope(N=\(segments))",
            op: .kaleidoscope(segments: segments, strength: 1),
            signature: { p in
                let rXZ = simd_length(SIMD2(p.x, p.z))
                guard rXZ > 0.15 else { return nil }
                let theta = atan2f(p.z, p.x)
                let cell = Int(floorf((theta + w) / (2 * w)))
                let side = gmod(theta + w, 2 * w) < w ? 0 : 1
                return [cell, side]
            },
            globallyLipschitz: true))
    }

    // Coxeter — the fold piece is the exact sequence of reflections the
    // iteration performs; equal sequences mean both points underwent the
    // same composed isometry. Spherical {P,Q} symbols keep the Gram-derived
    // n3 a unit vector.
    for (symP, symQ) in [(4, 3), (3, 5)] {
        let sinP = sinf(.pi / Float(symP))
        let n1 = SIMD3<Float>(1, 0, 0)
        let n2 = SIMD3<Float>(-cosf(.pi / Float(symP)), sinP, 0)
        let c = cosf(.pi / Float(symQ)) / sinP
        let n3 = SIMD3<Float>(0, -c, sqrtf(max(1e-6, 1 - c * c)))
        cases.append(IsoCase(
            name: "coxeter{\(symP),\(symQ)}",
            op: .coxeter(p: symP, q: symQ, strength: 1),
            signature: { p in
                var q = p
                var path: [Int] = []
                for _ in 0..<24 {
                    var reflected = false
                    for (index, n) in [n1, n2, n3].enumerated() {
                        let d = simd_dot(q, n)
                        if d < 0 {
                            q -= 2 * d * n
                            path.append(index)
                            reflected = true
                        } else {
                            path.append(-1)
                        }
                    }
                    if !reflected { break }
                }
                return path
            },
            globallyLipschitz: true))
    }

    // MengerFold — creases at the coordinate planes AND at |p_i| == |p_j|
    // (sort ties); piece = sign pattern + descending-order permutation.
    // Samples with near-tied magnitudes are discarded (they sit on a crease).
    cases.append(IsoCase(
        name: "mengerFold",
        op: .mengerFold(strength: 1),
        signature: { p in
            let q = simd_abs(p)
            let tieMargin: Float = 0.03
            if abs(q.x - q.y) < tieMargin || abs(q.x - q.z) < tieMargin
                || abs(q.y - q.z) < tieMargin { return nil }
            let order = [0, 1, 2].sorted { q[$0] > q[$1] }
            return [p.x < 0 ? 0 : 1, p.y < 0 ? 0 : 1, p.z < 0 ? 0 : 1] + order
        },
        globallyLipschitz: true))

    // OffsetFold — creases at the shifted planes p_i == c_i.
    let offsetCenter = SIMD3<Float>(0.4, -0.2, 0.7)
    cases.append(IsoCase(
        name: "offsetFold",
        op: .offsetFold(center: offsetCenter, strength: 1),
        signature: { p in
            let d = p - offsetCenter
            return [d.x < 0 ? 0 : 1, d.y < 0 ? 0 : 1, d.z < 0 ? 0 : 1]
        },
        globallyLipschitz: true))

    // Tiling — piece = lattice cell per enabled axis. The sawtooth jumps a
    // full cell across boundaries, so global Lipschitz does NOT hold; the
    // arbitrary-pair check is restricted to same-cell pairs.
    let cell: Float = 1.5
    cases.append(IsoCase(
        name: "tiling",
        op: .tiling(cellSize: cell, strength: 1),
        signature: { p in
            (0..<3).map { Int(floorf((p[$0] + cell / 2) / cell)) }
        },
        globallyLipschitz: false))

    return cases
}

@Suite("Isometry at s = 1")
struct IsometryTests {
    @Test("nearby same-piece pairs preserve distance exactly; dScale stays 1")
    func localIsometry() {
        for (caseIndex, isoCase) in makeCases().enumerated() {
            var rng = SplitMix64(seed: 0xA11CE + UInt64(caseIndex))
            let map = pointMap(isoCase.op)
            var accepted = 0
            var attempts = 0
            while accepted < 60 && attempts < 4000 {
                attempts += 1
                let p = rng.point(in: -3...3)
                let separation = rng.float(in: 2e-3...8e-3)
                let q = p + rng.unitVector() * separation
                guard let sigP = isoCase.signature(p),
                      let sigQ = isoCase.signature(q),
                      sigP == sigQ
                else { continue }
                accepted += 1

                let din = simd_length(p - q)
                let dout = simd_length(map(p) - map(q))
                #expect(
                    abs(dout - din) <= 1e-3 * din,
                    "\(isoCase.name): |T(p)-T(q)|=\(dout) vs |p-q|=\(din) at p=\(p)")

                // Isometric ops contribute no dScale term.
                #expect(reportedDScale(isoCase.op, at: p) == 1,
                        "\(isoCase.name): isometric op must not scale distance")
            }
            #expect(accepted >= 60,
                    "\(isoCase.name): only \(accepted) same-piece pairs in \(attempts) attempts")
        }
    }

    @Test("arbitrary pairs satisfy the 1-Lipschitz inequality")
    func globalLipschitz() {
        for (caseIndex, isoCase) in makeCases().enumerated() {
            var rng = SplitMix64(seed: 0xB0B + UInt64(caseIndex))
            let map = pointMap(isoCase.op)
            var checked = 0
            var attempts = 0
            while checked < 200 && attempts < 20000 {
                attempts += 1
                let p = rng.point(in: -3...3)
                let q = rng.point(in: -3...3)
                if !isoCase.globallyLipschitz {
                    // Tiling: restrict to same-cell pairs (see header note).
                    guard let sigP = isoCase.signature(p),
                          let sigQ = isoCase.signature(q),
                          sigP == sigQ
                    else { continue }
                }
                checked += 1
                let din = simd_length(p - q)
                let dout = simd_length(map(p) - map(q))
                #expect(
                    dout <= din * (1 + 1e-3) + 1e-6,
                    "\(isoCase.name): expansion \(dout / max(din, 1e-9)) at p=\(p), q=\(q)")
            }
            #expect(checked >= 100, "\(isoCase.name): only \(checked) pairs checked")
        }
    }
}
