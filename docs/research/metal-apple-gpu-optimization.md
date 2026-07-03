# Metal / Apple GPU shader optimization

Sourced from Apple primary docs and WWDC sessions (2020–2025) plus the
current MSL spec (v4.1). These describe stable TBDR/Metal architecture
fundamentals — none are raymarching-specific benchmarks. See
[README.md](README.md) for the visionOS-specific vs. general split and
source caveats.

## TBDR architecture (general Apple Silicon, not visionOS-specific)

[WWDC20 10632](https://developer.apple.com/videos/play/wwdc2020/10632/) — confidence: high, 2-1 verified, corroborated by current docs and independent AGX reverse-engineering.

- All Apple Silicon/AGX-family GPUs (including Vision Pro's) use tile-based
  deferred rendering: geometry is binned into screen-aligned tiles at the
  vertex stage, and the GPU rasterizes everything in a tile using fast
  on-chip tile memory before shading any pixels — eliminates overdraw,
  reduces system memory traffic.
- **Relevant asymmetry for Threshold:** a full-screen raymarch fragment
  shader gets essentially none of TBDR's overdraw-elimination benefit,
  since there's no overdraw to eliminate (one shaded fragment per pixel
  either way). This is a real consideration when choosing compute vs.
  fragment shader for the raymarch pass, but no source in this pass
  directly benchmarked that specific choice for raymarching — treat as an
  architectural inference, not a measured result.

## Register pressure / occupancy — the most directly actionable finding

[WWDC20 10632](https://developer.apple.com/videos/play/wwdc2020/10632/), [WWDC21 10148](https://developer.apple.com/videos/play/wwdc2021/10148/) — confidence: high, verified verbatim against primary transcripts.

- Apple GPUs are register-optimized for 16-bit types: `half`/`short`
  instead of `float`/`int` reduces register allocation, increases
  occupancy, and in most cases uses faster ALU instructions. `half`↔`float`
  conversions are "typically free."
- **Case studies:**
  - *Baldur's Gate 3*: split a 4,500+ instruction uber-shader (with runtime
    conditional branching) into dedicated specialized shader variants —
    84% fewer instructions, 90% fewer branches, 25% fewer registers, 92%
    fewer texture reads, ~8ms average frame-time savings.
  - *Divinity: Original Sin 2*: mixing F32/F16 in the ambient-occlusion
    shader gave 30% shader-execution-time improvement, occupancy nearly
    doubled.
- **Directly relevant to Threshold:** register pressure/occupancy are
  named by Apple as first-order performance levers, and this is
  *architecturally the same mechanism* as Threshold's already-shipped
  pipeline specialization (direct-call DE variants vs. visible-function-
  table dispatch, measured 8–11% win — see [perf-notes.md](../perf-notes.md)).
  BG3's win is the same technique applied harder (full instruction-count
  reduction via variant splitting, not just call-site inlining) — suggests
  headroom beyond what's already shipped.
- **Tension with Threshold's precise-math/determinism policy:** half
  precision trades away precision, which the project has deliberately
  avoided (see `mathMode .safe` in perf-notes.md). Any half-precision
  experiment on DE evaluation needs empirical validation against the
  golden-image corpus before it's usable — this is a real accuracy
  trade-off, not a free win.

## Math modes: fast / relaxed / safe, and per-call-site override

[MSL Specification v4.1 (PDF)](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf), [WWDC21 10148](https://developer.apple.com/videos/play/wwdc2021/10148/) — confidence: high, 3-0 verified against current spec.

- `-fmetal-math-mode` has three levels:
  - `fast` (default) — aggressive FP optimizations, no IEEE guarantees.
  - `relaxed` — aggressive optimizations but honors INFs/NaNs.
  - `safe` — disables all unsafe FP optimizations, FP contract "on",
    IEEE-correct. (This is what Threshold uses.)
- MSL also exposes explicit `metal::precise` and `metal::fast` namespaces —
  lets a developer force the precise or fast variant of a *specific* math
  function at a single call site, independent of the global compiler flag.
  **This means Threshold doesn't have to choose one policy globally**: DE
  evaluation and step-size logic can stay on safe/precise math for
  determinism while non-critical operations (e.g. coloring, orbit-trap
  cosmetics) selectively opt into `metal::fast`. This is an inference from
  documented capability, not benchmarked for raymarching specifically —
  needs empirical validation, but it's a concrete, low-risk thing to try
  next given the existing precise-math constraint.
- **Case study:** enabling fast-math for Metro Exodus's Metal translation
  layer (previously defaulted to precise/IEEE math) produced a measured
  21% frame-time decrease in Apple's internal benchmark. Order-of-magnitude
  sense of what's on the table if selective fast-math is applied
  aggressively — not a number to expect wholesale given Threshold's
  determinism requirement.

## Argument buffers

[WWDC21 10286](https://developer.apple.com/videos/play/wwdc2021/10286/), [Apple docs — Managing Groups of Resources with Argument Buffers](https://developer.apple.com/documentation/metal/buffers/managing_groups_of_resources_with_argument_buffers) — confidence: high.

- Full bindless resource binding (Tier 2) requires Apple6/Mac2 GPU family
  (includes all Apple Silicon) and works from both rasterization and
  ray-tracing shaders.
- **Pitfall (verified 3-0, real footgun):** setting an argument buffer as a
  single shader argument does *not* automatically make its resources
  GPU-accessible. The app must explicitly call
  `useResource(_:usage:stages:)` on every resource referenced inside the
  argument buffer, or risk silent GPU faults / command buffer failures.
- Relevance to Threshold is moderate — matters if/when Threshold moves
  toward bindless binding for multiple DE variants or per-eye resources.
  Not directly about raymarch step-count or register pressure, but worth
  remembering if argument-buffer usage expands (Threshold already uses
  argument buffers for op/DE-handle encoding per PLAN.md — the residency
  call is the thing to double-check there, not a new architecture).

## visionOS-specific: stereo texture layout

[WWDC23 10089](https://developer.apple.com/videos/play/wwdc2023/10089/) — confidence: medium, 2-1 verified. **This is the only visionOS-specific finding in this pass** — everything else above is general Apple Silicon/Metal, not unique to Vision Pro.

- Three stereo rendering configurations for CompositorServices:
  - **Dedicated** — two separate textures, two full render passes (one per
    eye).
  - **Shared** — one texture, one array slice, two viewports; single-pass
    capable but doesn't readily support foveation.
  - **Layered** — one texture, two array slices, two viewports. Apple's
    stated *optimal* configuration: single-pass rendering while still
    supporting foveated rendering.
- Does **not** say anything about per-eye raymarch cost reduction, vertex
  amplification mechanics for a raymarch fragment shader specifically, or
  foveated raymarching step budgets — those are open questions (see
  README).

## What this pass did not resolve

Cone marching, self-shadow approximation, coherent ray packets, spatial
acceleration structures, indirect command buffers for GPU-driven
raymarching, and whether vertex amplification shares/reduces per-eye
raymarch cost — none were substantiated by a fetched primary source this
round. See README's open-questions list before assuming any of these are
either wins or non-wins.
