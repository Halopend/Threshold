# Research: raymarch + Metal shader optimization

Deep-research pass (2026-07-03) on sphere-tracing acceleration and Apple
GPU/Metal shader optimization, scoped to Threshold's SDF fractal raymarcher.
106 subagents, 24 primary sources fetched, 109 claims extracted, 25
adversarially verified (20 confirmed / 5 refuted). Two files:

- [raymarch-sphere-tracing.md](raymarch-sphere-tracing.md) — algorithmic
  step-acceleration techniques (over-relaxation, segment tracing, normals).
  Platform-agnostic; numbers below were measured on Nvidia/AMD, not Metal.
- [metal-apple-gpu-optimization.md](metal-apple-gpu-optimization.md) —
  Apple Silicon/TBDR architecture, register pressure, math modes, argument
  buffers, visionOS stereo rendering.

Cross-reference: [../perf-notes.md](../perf-notes.md) has Threshold's own
measured baselines and the "known levers not yet pulled" list this research
was aimed at (over-relaxed sphere tracing, cone marching, warp-stack
specialization). PLAN.md §"Rail: Budget · Acceleration" is the product-level
list of acceleration toggles (over-relaxation, cone marching, LOD, smart
advance, self-shadows, foveation, coherent packet).

## Headline takeaway

Step-acceleration techniques (over-relaxation, enhanced/segment tracing,
auto-relaxation) give real speedups on generic scenes, but the one paper
that tested a **fractal** (Mandelbulb) found the advantage mostly evaporates
— enhanced/relaxed/basic sphere tracing were statistically on par. Don't
assume published percentages transfer to Threshold's DEs without measuring
on the actual fractal geometry.

On the Metal side, register-pressure reduction (specialization, 16-bit
types) and math-mode choice are the best-evidenced, most directly
actionable levers — and both connect to decisions Threshold has already
made (specialization win, precise-math policy). See the "Tension with
Threshold's precise-math policy" note in the Metal file before touching
math modes.

## What this pass did NOT find (open questions, not "no effect")

No primary source surfaced for these — they need a separate targeted pass,
not extrapolation from what's here:

- Cone marching / conservative cone tracing numbers (soft shadows, faster
  convergence) — one GDC talk title surfaced ("Cone Marching in VR") but
  wasn't fetched/verified this pass.
- Foveated raymarching (variable step budget by eccentricity) on visionOS
  or any VR headset — no source addressed this directly.
- Self-shadow approximation that avoids a full secondary raymarch.
- Coherent ray packets / warp-coherent marching for SIMD efficiency.
- Spatial acceleration structures (octrees/BVH) for many/complex SDFs.
- Indirect command buffers for GPU-driven raymarching.
- Whether vertex amplification/multiview shares or reduces any raymarch
  cost between the two eyes, or whether DE evaluation is necessarily fully
  duplicated per eye.
- Metal shader-compiler caching/precompilation behavior (Threshold already
  measured this itself — see perf-notes.md "Startup" — so lower priority).

## Refuted claims (checked and killed — don't resurrect)

Adversarial verification (3-vote) killed these; they showed up in source
extraction but didn't survive cross-checking against the primary text:

1. "Enhanced sphere tracing shows up to 50% better performance than basic
   and up to 1.5x better than relaxed sphere tracing" — overstated framing
   of the Balint/Csebfalvi numbers (0-3).
2. "On Mandelbulb geometry, enhanced/relaxed sphere tracing are
   statistically on par with basic" as a *strong* claim — the underlying
   near-parity finding is real (see raymarch file), but this exact framing
   overreached and was refuted (0-3). Read the qualified version in the
   raymarch file, not this one.
3. "Segment tracing's step-growth factor k ≈ 2 is the optimal/practical
   value" — not supported as stated (1-2).
4. "Central-differences normal computation costs 6 SDF evaluations" as a
   flat claim — refuted on exact framing (1-2); the tetrahedron-technique
   comparison (4 vs 6) in the raymarch file is the verified version.
5. "MSL has a `[[function_groups]]` compiler hint for narrowing
   visible-function-table dispatch targets" — no such attribute was
   confirmed to exist as described (1-2). Don't go looking for it.

## Source quality caveats

- Balint/Csebfalvi 2018 ("enhanced sphere tracing" v2) is a 4-page
  Eurographics *short* paper, averaged over only 3 scenes, on an Nvidia
  1080Ti — not Apple Silicon.
- Ban & Valasek 2023 (auto-relaxed) is also a short paper, tested on AMD
  RX 5700 via DX12/Falcor — not Metal.
- Segment Tracing's GPU number (6 Hz → 67 Hz) is one illustrative data
  point from an *unoptimized* OpenGL 4.3 shader on Nvidia hardware.
- All WWDC sessions cited (2020–2025) describe stable TBDR/Metal
  architecture fundamentals, not raymarching-specific benchmarks — treat
  register-pressure/math-mode numbers as general shader guidance, not
  raymarch-validated.
