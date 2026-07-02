// SimplifierTests.swift — the simplifier contract (docs/op-semantics.md):
// explicit per-rule tests plus sampled point-map equivalence over seeded
// random stacks crafted to trigger each rule.
//
// dScale note: twist fusion is exact for the POINT map (rotation angles about
// a shared axis add), but the documented dScale bound √(1+(s·r⊥)²) is not
// multiplicative in s, so a fused twist legitimately reports a different
// (single-op) bound than the two-op product. Sampled dScale equivalence is
// therefore asserted only for stacks without twist fusion; point-map
// equivalence is asserted for all stacks.
//
// Shells note: the shipping app's contract listed Shells as coalescible, but
// under the op-semantics Shells formula (r' = |mod(r, 2t) − t|) a double
// application is the IDENTITY on the fundamental domain (an involution), so
// collapsing a pair to one op is mathematically wrong. The contract was
// corrected to exclude Shells; the structural test below pins the EXCLUSION,
// and the random-stack sampled-equivalence generator may freely emit
// adjacent Shells pairs (they must survive simplification unchanged).

import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdShaderIR

// MARK: - Explicit rule tests

@Suite("Simplifier rules")
struct SimplifierRuleTests {
    @Test("rule 1: zero-strength ops and kind None are dropped")
    func dropsNoOps() {
        let keep = ThreshWarpOp.twist(axis: SIMD3(0, 1, 0), strength: 0.5)
        var none = ThreshWarpOp()
        none.kind = WarpKind.none.rawValue
        none.strength = 1
        let stack: [ThreshWarpOp] = [
            .mirror(strength: 0),
            keep,
            none,
            .boxFold(limit: 1, strength: 0),
            .handAttract(center: .zero, radius: 0.3, ballScale: 1, softness: 0.1,
                         pocketSize: 0.3, pocketSoftness: 0.1, pocketEnabled: false,
                         strength: 0),
        ]
        let simplified = WarpSimplifier.simplify(stack)
        #expect(simplified.count == 1)
        #expect(simplified.first?.kind == WarpKind.twist.rawValue)
        #expect(simplified.first?.strength == 0.5)
    }

    @Test("rule 2: adjacent identical full-strength Mirror pair collapses")
    func mirrorPairCollapses() {
        let stack: [ThreshWarpOp] = [.mirror(strength: 1), .mirror(strength: 1)]
        let simplified = WarpSimplifier.simplify(stack)
        #expect(simplified.count == 1)
        #expect(simplified.first?.kind == WarpKind.mirror.rawValue)
        // Runs collapse too.
        #expect(WarpSimplifier.simplify([.mirror(strength: 1), .mirror(strength: 1),
                                         .mirror(strength: 1)]).count == 1)
    }

    @Test("rule 2: ScaleRepeat pairs collapse; Shells pairs are excluded (involution)")
    func idempotentPairsCollapse() {
        let sr: [ThreshWarpOp] = [.scaleRepeat(factor: 2, strength: 1),
                                  .scaleRepeat(factor: 2, strength: 1)]
        #expect(WarpSimplifier.simplify(sr).count == 1)
        // Shells∘Shells == identity on the fundamental domain, NOT Shells —
        // collapsing would change the geometry. Must survive unchanged.
        let sh: [ThreshWarpOp] = [.shells(spacing: 0.8, strength: 1),
                                  .shells(spacing: 0.8, strength: 1)]
        #expect(WarpSimplifier.simplify(sh).count == 2)
        // Different payloads do NOT collapse.
        let mixed: [ThreshWarpOp] = [.scaleRepeat(factor: 2, strength: 1),
                                     .scaleRepeat(factor: 3, strength: 1)]
        #expect(WarpSimplifier.simplify(mixed).count == 2)
        // Partial strength does NOT collapse.
        let partial: [ThreshWarpOp] = [.mirror(strength: 0.5), .mirror(strength: 0.5)]
        #expect(WarpSimplifier.simplify(partial).count == 2)
    }

    @Test("rule 3: adjacent parallel twists sum strengths into one op")
    func parallelTwistsSum() {
        let axis = SIMD3<Float>(0, 2, 0) // unnormalized on purpose
        let stack: [ThreshWarpOp] = [.twist(axis: axis, strength: 0.3),
                                     .twist(axis: SIMD3(0, 0.5, 0), strength: 0.45)]
        let simplified = WarpSimplifier.simplify(stack)
        #expect(simplified.count == 1)
        #expect(simplified.first?.kind == WarpKind.twist.rawValue)
        #expect(abs((simplified.first?.strength ?? 0) - 0.75) < 1e-6)

        // Non-parallel axes do not merge.
        let skewed: [ThreshWarpOp] = [.twist(axis: SIMD3(0, 1, 0), strength: 0.3),
                                      .twist(axis: SIMD3(0.1, 1, 0), strength: 0.3)]
        #expect(WarpSimplifier.simplify(skewed).count == 2)
        // Antiparallel axes do not merge (dot = -1).
        let anti: [ThreshWarpOp] = [.twist(axis: SIMD3(0, 1, 0), strength: 0.3),
                                    .twist(axis: SIMD3(0, -1, 0), strength: 0.3)]
        #expect(WarpSimplifier.simplify(anti).count == 2)
    }

    @Test("fixpoint: cancelling parallel twists vanish entirely")
    func fixpointCancellation() {
        let stack: [ThreshWarpOp] = [.twist(axis: SIMD3(1, 0, 0), strength: 0.6),
                                     .twist(axis: SIMD3(1, 0, 0), strength: -0.6)]
        #expect(WarpSimplifier.simplify(stack).isEmpty)
        // Dropping an interleaved no-op exposes an adjacent merge (fixpoint).
        let gapped: [ThreshWarpOp] = [.mirror(strength: 1),
                                      .twist(axis: SIMD3(0, 1, 0), strength: 0),
                                      .mirror(strength: 1)]
        #expect(WarpSimplifier.simplify(gapped).count == 1)
    }

    @Test("exclusions: Kaleidoscope/BoxFold/Coxeter duplicates are NEVER merged")
    func loadBearingExclusions() {
        let kal: [ThreshWarpOp] = [.kaleidoscope(segments: 6, strength: 1),
                                   .kaleidoscope(segments: 6, strength: 1)]
        #expect(WarpSimplifier.simplify(kal).count == 2)
        let box: [ThreshWarpOp] = [.boxFold(limit: 1, strength: 1),
                                   .boxFold(limit: 1, strength: 1)]
        #expect(WarpSimplifier.simplify(box).count == 2)
        let cox: [ThreshWarpOp] = [.coxeter(p: 4, q: 3, strength: 1),
                                   .coxeter(p: 4, q: 3, strength: 1)]
        #expect(WarpSimplifier.simplify(cox).count == 2)
    }

    @Test("non-adjacent duplicates are NOT merged (adjacent-only contract)")
    func nonAdjacentNotMerged() {
        let stack: [ThreshWarpOp] = [
            .mirror(strength: 1),
            .twist(axis: SIMD3(0, 1, 0), strength: 0.4),
            .mirror(strength: 1),
        ]
        let simplified = WarpSimplifier.simplify(stack)
        #expect(simplified.count == 3)
        // Same for twists separated by a real op.
        let twists: [ThreshWarpOp] = [
            .twist(axis: SIMD3(0, 1, 0), strength: 0.4),
            .mirror(strength: 1),
            .twist(axis: SIMD3(0, 1, 0), strength: 0.4),
        ]
        #expect(WarpSimplifier.simplify(twists).count == 3)
    }

    @Test("simplify is idempotent")
    func simplifyIdempotent() {
        var rng = SplitMix64(seed: 41)
        for _ in 0..<50 {
            let stack = randomStack(&rng).ops
            let once = WarpSimplifier.simplify(stack)
            let twice = WarpSimplifier.simplify(once)
            #expect(once.count == twice.count)
            for (a, b) in zip(once, twice) {
                #expect(a.kind == b.kind && a.strength == b.strength && a.a == b.a && a.b == b.b)
            }
        }
    }
}

// MARK: - Sampled equivalence

@Suite("Simplifier sampled equivalence")
struct SimplifierEquivalenceTests {
    @Test("100 seeded random stacks: original ≅ simplified over 50 points")
    func sampledEquivalence() {
        var rng = SplitMix64(seed: 0x51D)
        var totalCompared = 0
        for stackIndex in 0..<100 {
            let (stack, hasTwistFusion) = randomStack(&rng)
            let simplified = WarpSimplifier.simplify(stack)

            for _ in 0..<50 {
                let p = rng.point(in: -2...2)
                let orig = ReferenceOps.applyPointOps(p, ops: stack)

                // Discontinuity filter: both maps share the same crease set
                // mathematically, but float rounding right AT a fold boundary
                // is unspecified. Skip points where the original map jumps
                // under a tiny probe displacement.
                let probe = p + SIMD3<Float>(1e-4, 1.3e-4, -0.7e-4)
                let probed = ReferenceOps.applyPointOps(probe, ops: stack)
                if simd_length(probed.p - orig.p) > 0.05 { continue }
                if !close(probed.dScale, orig.dScale, tol: 0.01) { continue }

                totalCompared += 1
                let simp = ReferenceOps.applyPointOps(p, ops: simplified)
                #expect(close(orig.p, simp.p, tol: 1e-3),
                        "stack \(stackIndex): p' \(orig.p) vs \(simp.p) at \(p)")
                if !hasTwistFusion {
                    #expect(close(orig.dScale, simp.dScale, tol: 1e-3),
                            "stack \(stackIndex): dScale \(orig.dScale) vs \(simp.dScale) at \(p)")
                }
            }
        }
        // The filter must not hollow the property out.
        #expect(totalCompared >= 3500, "only \(totalCompared) of 5000 points compared")
    }

    @Test("distance-op equivalence: dropped zero-strength hand ops change nothing")
    func distanceEquivalence() {
        var rng = SplitMix64(seed: 0x51E)
        for _ in 0..<50 {
            let (stack, _) = randomStack(&rng)
            let simplified = WarpSimplifier.simplify(stack)
            for _ in 0..<10 {
                let p = rng.point(in: -2...2)
                let d = rng.float(in: -0.5...2)
                let orig = ReferenceOps.applyDistanceOps(p, distance: d, ops: stack)
                let simp = ReferenceOps.applyDistanceOps(p, distance: d, ops: simplified)
                #expect(close(orig, simp, tol: 1e-3))
            }
        }
    }
}

// MARK: - Random stack generator (crafted to trigger each rule)

/// Builds a random stack of length 1...8 from segments that exercise every
/// simplifier rule: no-ops (rule 1), full-strength Mirror/ScaleRepeat pairs
/// (rule 2), parallel twist pairs (rule 3), and the excluded
/// Kaleidoscope/BoxFold/Coxeter/Shells duplicates (which must NOT fuse —
/// sampled equivalence holds for them trivially because they pass through
/// simplification unchanged).
func randomStack(_ rng: inout SplitMix64) -> (ops: [ThreshWarpOp], hasTwistFusion: Bool) {
    var ops: [ThreshWarpOp] = []
    var hasTwistFusion = false
    let target = rng.int(in: 1...8)
    while ops.count < target {
        switch rng.int(in: 0...9) {
        case 0: // rule 1 trigger: zero-strength op
            var op = randomSingleOp(&rng)
            op.strength = 0
            ops.append(op)
        case 1: // rule 2 trigger: identical full-strength mirror pair
            ops.append(.mirror(strength: 1))
            ops.append(.mirror(strength: 1))
        case 2: // rule 2 trigger: identical full-strength scaleRepeat pair
            let factor = rng.float(in: 1.5...3)
            ops.append(.scaleRepeat(factor: factor, strength: 1))
            ops.append(.scaleRepeat(factor: factor, strength: 1))
        case 3: // rule 3 trigger: adjacent parallel twists
            let axis = rng.unitVector()
            let s1 = rng.float(in: -0.8...0.8)
            let s2 = rng.float(in: -0.8...0.8)
            ops.append(.twist(axis: axis, strength: s1))
            ops.append(.twist(axis: axis * rng.float(in: 0.5...2), strength: s2))
            if s1 != 0 && s2 != 0 { hasTwistFusion = true }
        case 4: // exclusion triggers: duplicates that must NOT merge
            switch rng.int(in: 0...3) {
            case 0:
                let op = ThreshWarpOp.kaleidoscope(segments: rng.int(in: 2...7), strength: 1)
                ops.append(op)
                ops.append(op)
            case 1:
                let op = ThreshWarpOp.boxFold(limit: rng.float(in: 0.6...1.5), strength: 1)
                ops.append(op)
                ops.append(op)
            case 2:
                let op = ThreshWarpOp.coxeter(p: 4, q: 3, strength: 1)
                ops.append(op)
                ops.append(op)
            default:
                // Shells: excluded involution — the pair must survive and
                // still satisfy sampled equivalence (trivially, unchanged).
                let op = ThreshWarpOp.shells(spacing: rng.float(in: 0.5...1.2), strength: 1)
                ops.append(op)
                ops.append(op)
            }
        case 5: // rule 1 trigger: kind None
            var none = ThreshWarpOp()
            none.kind = WarpKind.none.rawValue
            none.strength = rng.float(in: 0...1)
            ops.append(none)
        case 6: // zero-strength distance op (dropped; invisible to point path)
            ops.append(.handAttract(
                center: rng.point(in: -1...1), radius: rng.float(in: 0.1...0.5),
                ballScale: 1, softness: 0.1, pocketSize: 0.3, pocketSoftness: 0.1,
                pocketEnabled: rng.bool(), strength: 0))
        default:
            ops.append(randomSingleOp(&rng))
        }
    }
    return (ops, hasTwistFusion)
}

/// A single random op with moderate parameters (numerically tame region).
private func randomSingleOp(_ rng: inout SplitMix64) -> ThreshWarpOp {
    switch rng.int(in: 0...12) {
    case 0: return .twist(axis: rng.unitVector(), strength: rng.float(in: -0.8...0.8))
    case 1: return .bend(axis: rng.unitVector(), strength: rng.float(in: -0.5...0.5))
    case 2: return .ripple(axis: rng.unitVector(), frequency: rng.float(in: 0.5...4),
                           strength: rng.float(in: -0.5...0.5))
    case 3: return .mirror(strength: rng.float(in: 0.2...1))
    case 4: return .boxFold(limit: rng.float(in: 0.6...1.5),
                            hallOfMirrors: rng.bool(),
                            strength: rng.float(in: 0.2...1))
    case 5: return .planeFold(normal: rng.unitVector(), distance: rng.float(in: -0.5...0.5),
                              strength: rng.float(in: 0.2...1))
    case 6: return .mengerFold(strength: rng.float(in: 0.2...1))
    case 7: return .offsetFold(center: rng.point(in: -0.5...0.5), strength: rng.float(in: 0.2...1))
    case 8: return .sphereFold(minRadius: rng.float(in: 0.3...0.6),
                               fixedRadius: rng.float(in: 1.0...1.8),
                               strength: rng.float(in: 0.2...1))
    case 9: return .sphereInvert(radius: rng.float(in: 0.5...1.5), strength: rng.float(in: 0.2...1))
    case 10: return .shells(spacing: rng.float(in: 0.5...1.5), strength: rng.float(in: 0.2...1))
    case 11: return .scale(factor: rng.float(in: 0.5...2), strength: rng.float(in: 0.2...1))
    default: return .tiling(cellSize: rng.float(in: 1...2),
                            repeatX: rng.bool(), repeatY: rng.bool(), repeatZ: rng.bool(),
                            strength: rng.float(in: 0.2...1))
    }
}
