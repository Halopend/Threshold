# ADR-002: WarpOp widens from 32 to 48 bytes

**Status:** Proposed
**Date:** 2026-07-02
**Deciders:** Jean
**Relates to:** ARCHITECTURE.md §4, plan §5.2/§4.4

## Context

The shipping format is a 32-byte op (`type, strength, p1, p2, axisX/Y/Z, _pad`).
The plan's rebuild sketch shows `uint kind; float strength; float4 a, b` and flags the
size increase as an open trade. Hand ops (`handAttract`, `forearmCarve`) need
center(3) + radius + 4 shaping params; Coxeter already packs 3 mirror normals into the
32-byte layout at the ceiling. Today, behavior is encoded in conventions: strength
*sign* selects attract/repel, toggles hide in `p2`.

## Decision

```c
typedef struct {
    uint32_t kind; uint32_t flags; float strength; float _pad;
    simd_float4 a, b;
} WarpOp;   // 48 B, 16-aligned, _Static_assert both
```

`flags` carries per-kind booleans (isometric, pocketEnabled, hallOfMirrors, …).
Sign-encodes-behavior and toggle-in-payload conventions are retired.

## Options Considered

### Option A: 48 B with explicit flags (chosen)
| Dimension | Assessment |
|---|---|
| Memory/bandwidth | 8–16 ops × 48 B ≤ 768 B/frame — negligible on every target GPU |
| Complexity | Low; explicit flags *reduce* per-kind decode logic |
| Migration | One-time translation in the scene migration table |

**Pros:** room for hand ops and Coxeter without packing games; self-documenting flags;
16-byte alignment matches `simd_float4` naturally.
**Cons:** legacy op arrays need a (trivial, table-driven) migration; 50% larger buffer
(irrelevant at this scale).

### Option B: Keep 32 B + side "extended payload" buffer for fat ops
**Pros:** legacy format unchanged.
**Cons:** two buffers to keep in sync, indexed indirection in the march inner loop,
simplifier must reason about both — reintroduces exactly the parallel-structure
disease the rebuild exists to kill.

### Option C: Keep 32 B, keep packing conventions
**Cons:** hand ops don't fit without further convention-stacking; rejected.

## Trade-off Analysis

The only real cost of A is a migration entry; the only real benefit of B/C is avoiding
that entry. Migration machinery must exist anyway (plan §7.3).

## Consequences

- Ports of the 17 existing kinds re-map payloads once, in one table, unit-tested
  against the legacy corpus.
- The simplifier ports unchanged (it reasons about kinds and strengths, not layout).
- ABI CI check updates to `sizeof(WarpOp) == 48`.

## Action Items

1. [ ] Write the 32→48 payload remap table alongside the op-kind enum (Phase 2).
2. [ ] Add legacy-op fixtures to `Corpus/` before Phase 3 persistence work.
