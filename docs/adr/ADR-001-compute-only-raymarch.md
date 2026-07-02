# ADR-001: Compute-only raymarch on all platforms

**Status:** Proposed
**Date:** 2026-07-02
**Deciders:** Jean (solo) — sign-off = merging this doc
**Relates to:** ARCHITECTURE.md §4, plan §6.1

## Context

The rebuild plan proposed two march shells: a fragment shader for Mac/iPad and a
tiled compute kernel for visionOS, both wrapping one MSL `RaymarchCore.h`. The plan's
Invariant 8 says a feature must never exist on only one path, enforced by a
feature-table CI check. ARCHITECTURE.md §4 collapses this to a single compute shell
everywhere, with presentation-only differences (blit on Mac/iPad, Compositor Services
drawable on visionOS, texture readback in the harness).

The DE ABI depends on Metal function pointers (`[[visible]]` functions +
`MTLVisibleFunctionTable`), which constrains which pipeline types are viable.

## Decision

One compute kernel family is the only march path. Fragment shells may be added later
behind the same `marchAndShade` core only if a concrete measured need appears.

## Options Considered

### Option A: Compute-only (chosen)

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low — one shell, one feature matrix, Invariant 8 nearly free |
| Function-pointer support | Best case — visible function tables originated in compute; fewest feature-set caveats |
| Perf ceiling | Equal or better for a full-screen raymarcher (no rasterizer benefit to give up); threadgroup memory + tile-level adaptivity available |
| Risk | visionOS foveation (see trade-offs) |

**Pros**
- Adaptive/hierarchical tiling, in-kernel step counters (device atomics), packet
  coherence, and per-tile early-out are all compute-native.
- Harness, Mac, iPad, visionOS all dispatch the identical kernel — golden images on a
  Mac genuinely validate the visionOS visual path.
- One PSO family keeps the binary-archive cache small.

**Cons**
- **Hardware foveation on visionOS is a raster-pipeline feature.** Rasterization rate
  maps give fragment shaders reduced-resolution rendering for free; a compute kernel
  must instead *sample* the rate map and implement variable ray density + upsample
  itself. This is real extra work — but it is the same mechanism as the adaptive
  tiling we need anyway, so the cost is incremental, not a second system. It must be
  validated on device early (see Action Items).
- No hardware early-z / depth interactions if we ever composite rasterized geometry
  (e.g. RealityKit content) with the fractal. Depth output to a texture covers the
  known cases (portal pass, passthrough occlusion) but is manual.

### Option B: Fragment (Mac/iPad) + compute (visionOS) — the plan's original

**Pros:** MTKView integration is the beaten path; hardware foveation would still not
apply (Mac/iPad don't foveate); slightly simpler first pixel on Mac.
**Cons:** Two shells to keep at parity forever; function pointers in fragment
pipelines carry more feature-set caveats; the feature-table CI check exists *because*
this option creates the divergence risk. History of this exact codebase (zoom-fog on
one path only) argues against it.

### Option C: Fragment everywhere

Rejected outright: Compositor Services + adaptive tiling + step-count instrumentation
push visionOS strongly toward compute; forcing fragment there fights the platform.

## Trade-off Analysis

The decision trades a known, bounded engineering cost (manual foveation via rate-map
sampling inside the tiling system we already require) against a permanent structural
cost (dual-path parity maintenance, which this project has already paid for once and
documented as a top-tier failure mode). Bounded one-time cost beats unbounded
recurring cost.

## Consequences

- Invariant 15 (one shell family) becomes enforceable by inspection.
- Foveation quality on visionOS is our code, not the OS's — needs a device validation
  spike before Phase 7 work is scheduled.
- If Apple ships compute-incompatible display features we care about, revisit; the
  `marchAndShade` core boundary is the escape hatch.

## Action Items

1. [ ] Spike (device): compute kernel writing `LayerRenderer.Drawable` color texture
   directly, confirm format/usage flags permit compute writes on Vision Pro.
2. [ ] Spike (device): sample the layer's rasterization rate map from compute; measure
   variable-ray-density + upsample vs. full-res cost on a stress scene.
3. [ ] Confirm visible function tables + `MTLBinaryArchive` interaction for the
   built-in-DE PSO cache on all three platforms.
