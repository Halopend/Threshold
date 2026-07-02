// Simplifier.swift — the warp-stack simplifier (docs/op-semantics.md
// "Simplifier contract", normative; a port of the shipping rules).
//
// EXACT fusion ONLY, adjacent-only, applied repeatedly until fixpoint:
//
//   1. Drop no-ops: strength == 0, or kind == None.
//   2. Coalesce idempotent adjacent duplicates at FULL strength (s == 1)
//      with identical payloads: Mirror and ScaleRepeat only.
//   3. Sum adjacent parallel Twists (normalized-axis dot > 1 - 1e-6):
//      strengths add, single op remains.
//
// Load-bearing EXCLUSIONS — never coalesce: Kaleidoscope and BoxFold (look
// idempotent but are not), Coxeter (not exactly idempotent when
// non-convergent), and Shells (under the op-semantics formula a double
// application is the IDENTITY on the fundamental domain — an involution,
// not idempotent; the shipping app's contract listed it, the math here
// vetoes it). No approximate rules, ever. Any new rule must come with a
// sampled-equivalence proof test against `ReferenceOps`.

import simd
import ThresholdShaderABI

public enum WarpSimplifier {
    /// Simplify a warp stack. Pure function; runs CPU-side on stack change,
    /// producing the buffer the GPU sees (plan §5.2).
    public static func simplify(_ ops: [ThreshWarpOp]) -> [ThreshWarpOp] {
        var current = ops
        // Each changing pass strictly shrinks the stack (drops and merges both
        // remove one op), so this terminates in at most `ops.count` passes.
        while true {
            let (next, changed) = pass(current)
            if !changed { return next }
            current = next
        }
    }

    // MARK: - One adjacent-only pass

    private static func pass(_ ops: [ThreshWarpOp]) -> ([ThreshWarpOp], Bool) {
        var out: [ThreshWarpOp] = []
        out.reserveCapacity(ops.count)
        var changed = false
        for op in ops {
            // Rule 1 — drop no-ops.
            if op.strength == 0 || op.kind == WarpKind.none.rawValue {
                changed = true
                continue
            }
            // Rules 2/3 — merge into the immediately preceding survivor.
            // (Adjacent-only: dropping a no-op between two ops makes them
            // adjacent, which is exact — the no-op was the identity.)
            if let last = out.last, let merged = merge(last, op) {
                out[out.count - 1] = merged
                changed = true
                continue
            }
            out.append(op)
        }
        return (out, changed)
    }

    /// Exact adjacent fusion of `second` into `first`, or nil.
    private static func merge(_ first: ThreshWarpOp, _ second: ThreshWarpOp) -> ThreshWarpOp? {
        guard first.kind == second.kind,
              first.flags == second.flags,
              let kind = WarpKind(rawValue: first.kind)
        else { return nil }

        switch kind {
        case .mirror, .scaleRepeat:
            // Rule 2 — idempotent duplicates at FULL strength with identical
            // payloads collapse to one. (NOT Shells — see header: involution,
            // double-apply is the identity, so collapsing would be wrong.)
            guard first.strength == 1, second.strength == 1,
                  first.a == second.a, first.b == second.b
            else { return nil }
            return first

        case .twist:
            // Rule 3 — parallel twists: rotation angles about the same axis
            // add exactly (the axial coordinate is rotation-invariant), so
            // strengths sum. A zero sum is dropped by rule 1 next pass.
            let n1 = ReferenceOps.normalizedAxis(first.a.xyz)
            let n2 = ReferenceOps.normalizedAxis(second.a.xyz)
            guard dot(n1, n2) > 1 - 1e-6 else { return nil }
            var merged = first
            merged.strength = first.strength + second.strength
            return merged

        default:
            // Everything else — including the load-bearing exclusions
            // Kaleidoscope, BoxFold, Coxeter — is never touched.
            return nil
        }
    }
}
