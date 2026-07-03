# Legacy renderer audit — why the old Metal side was fast

Scan of the pre-rebuild app (`Polinate/TEMP/MetalRaymarch-main`, 2026-07-03).
The old codebase was messy but its render core was heavily optimized and,
unusually, kept honest perf records: `PERF_LOG.md` (device numbers only),
`PERF_PUSH.md` (scored backlog), `PERF_TECHNIQUES.md` (252-technique catalog
with trust warnings), `Baselines/*.json` (Mac harness). Where numbers appear
below they are the old repo's *measured* ones, not its estimates.

## The headline measurement

`Baselines/mac-stress-1080p-accel-{off,on}.json`, same Mac, same scene
(Stress test, fractalType 17, 6 iters, 168 max steps, shadows on, 1080p):

| config | gpuMsAvg |
|---|---|
| acceleration stack OFF | 52.3 ms |
| acceleration stack ON | **19.6 ms (2.67×)** |

The ON stack = bounding-sphere skip + cone-march coarse prepass
(`coneMarchStrength 1`) + distance LOD (`0.98`) + over-relaxation
(`ωmax 1.6`). Smart advance, coherent packets, foveation, tiling all OFF in
that baseline — the 2.67× is from four levers.

Cross-check against the rebuild (2026-07-03, same machine class, migrated
`Corpus/legacy/scenes/Stress_test.threshscene` @1080p, `--specialize`):
Threshold today renders it at **223 ms safe / 151 ms fast-math** vs the old
renderer's 19.6 ms. Scene-mapping differences make this inexact, but the
order-of-magnitude gap is real, and math mode explains only ~1.5× of it —
the rest is the acceleration stack + shading-path architecture below.

## Technique inventory (with status in the old code)

Algorithmic (march):

- **Relaxed sphere tracing (Keinert)** — `relaxedStepUpdate`: step `h·ω`,
  overshoot detected when consecutive unbounding spheres stop overlapping →
  retreat and pin ω=1 for the rest of the ray; hits suppressed on failed
  steps. ACTIVE on all live paths, ω ramps to 1.4 after geometry settles.
- **Per-DE-type ω caps** (`relaxedOmegaCap`) — the key safety insight:
  box/fold DEs (true lower bounds) tolerate 1.6; log-DE types
  (mandelbulb/julia) only 1.1 because they can locally OVERESTIMATE, which
  defeats the overshoot test (rays tunnel); Bulatov limit set pinned to 1.0;
  unknown/custom 1.2. Matches the research finding (Balint/Csebfalvi) that
  fractal DEs gain least from over-relaxation — the old project encoded the
  same reality as per-type caps.
- **Smart advance** — adaptive ω from the along-ray DE gradient
  `(h−prevH)/stepLen`: ~1 when converging head-on, boosted toward
  `1+(cap−1)×3` when grazing/receding; sticky give-up flag on overshoot.
  OFF in the measured baseline (unmeasured lever).
- **Cone-march coarse prepass warm start** — `SceneCoarse`: 24–28 steps,
  0.6× iterations, large epsilon; fine march starts from the coarse t.
  Part of the measured 2.67×.
- **Distance LOD** — `effIter = max(2, iterations − int(t × falloff))`:
  iteration count decays with ray distance (detail is sub-pixel anyway).
  Part of the measured 2.67×.
- **Bounding-sphere skip** — analytic ray/sphere to start the march at the
  fractal's bounding volume. Part of the measured 2.67×.
- **Orbit cache + analytic-Jacobian shading** — hit state captured once;
  normals/colors reconstructed without re-iterating the fractal (Mandelbox
  normals with ZERO extra Map() calls). One of the old repo's three pillars.
- **Temporal depth warm start** (visionOS) + **coherent packet marching** —
  present but gated/unmeasured.

Metal-side:

- **Fast math everywhere**: `MTL_FAST_MATH = YES` (precompiled lib) and
  `mathMode = .fast` on every runtime formula compile.
- **Function-constant specialization** on ~16 axes — fractal type,
  iterations, shadow iterations, max ray steps, quality mode, shadows
  on/off, mandelbulb power, warm-start/packet toggles. Iteration counts
  become compile-time loop bounds → full unroll of the DE loop. This is the
  same mechanism as Threshold's `THRESH_SPEC_DE` seam, applied to far more
  axes.
- **Half precision in the fold loops** (~190 uses): fold/sphere-fold
  iterations run in `half` where the hit threshold (>0.02) is well within
  half's precision; also shading/secondary rays. Old backlog ranked F16
  expansion as a top lever since the renderer measured **ALU-bound (~68–70%
  of GPU time)**.
- **MetalFX spatial + temporal upscalers** (Mac) — present but NOT in the
  default path (required resolutionScale < 1, not default).
- **CPU precompute of frame-uniform transcendentals**, `rsqrt` intrinsics,
  early miss-skip, shared shadow evaluation, reduced shadow iterations.

Old repo's own ground truth worth carrying forward:

- ALU-bound ~68–70% (windowed GPU counters) — not bandwidth, not
  buffer-starved. Register pressure + arithmetic are the ceiling.
- Shading tail flat 2–3 ms across scenes; shadows its biggest chunk.
- Mandelbox cost grows super-linearly with resolution (epsilon tightens
  with res → more steps) — an epsilon-policy artifact, not intrinsic.
- Measured-and-refuted on Bulatov (don't re-propose): MaxReflections cap,
  transcendental hoisting, secondary-ray step cap, shadow toggle alone.
- Its #1 unexecuted idea: **deferred shading** (split march → G-buffer →
  shade) to cut the megakernel's register footprint.

## What this means for Threshold (ranked)

1. **Over-relaxation with per-DE ω caps + the overshoot-retreat guard** is
   proven at 2.67× (stacked with 2–4) and the safety design is already
   worked out — port `relaxedStepUpdate` + `relaxedOmegaCap` semantics into
   RaymarchCore's march loop as a governor-controllable lever. Changes
   images → golden regeneration + quality review (perf-notes "levers not
   yet pulled" already flags this).
2. **Distance LOD on iterations** — trivial to add (one line in the march
   loop), part of the measured stack, and Threshold already pipes
   `lodScale` through ScaleContext.
3. **Bounding-sphere skip** — cheap, DE-registry metadata + a few lines.
4. **Cone-march coarse prepass** — bigger change, measured as part of the
   stack; the old implementation (0.6× iterations, per-type step counts,
   sphere-projection mirroring) is a working reference.
5. **Half-precision fold loops** — old code demonstrates it works within
   hit thresholds; conflicts with strict determinism, so needs the golden
   corpus + CPU-equivalence story first (ALU-bound ⇒ real ceiling here).
6. **Fast math**: measured on Threshold 2026-07-03 (perf block 3,
   perf-notes.md): 19–34% GPU depending on scene; `relaxed` and `fast`
   byte-identical on the corpus scenes. Whole-shader switch conflicts with
   the determinism policy; the per-call-site `metal::fast` namespace path
   (see metal-apple-gpu-optimization.md) is the compatible route.
7. **Deferred shading** — the old repo's top-ranked unexecuted lever;
   relevant once 1–4 land and the march loop's register footprint is the
   remaining ceiling.
