# Performance notes

Measurements drive optimization here; this file records the baselines, what
was tried, and what the numbers said. Re-measure before trusting old numbers
(machine: Apple silicon dev Mac, release build, 1024×1024, 30–60 frames,
`threshold-render --stats`).

## Baselines — 2026-07-03

| Scene | GPU median | Steps/frame | ns/step |
|---|---|---|---|
| default-bulb | 10.3 ms | 20.6 M | 0.46 |
| Blue hero (legacy mandelbox) | ~19 ms | — | — |
| warped-bulb (kaleido + 2 twists) | 49.7 ms | 57.5 M | 0.67 |

Reading: the warped scene costs 4× the plain one via BOTH more steps (2.8× —
twist ops shrink safe step sizes; inherent to the content) and higher cost
per step (+45% — warp interpreter + extra transform math per map call).

## Startup (shader compile)

Full CLI process, default-bulb, 8×8 render: **0.35 s cold / 0.09 s warm.**
`makeLibrary(source:)` hits the OS Metal compiler cache keyed by source, so a
custom on-disk shader cache would buy nothing. Decision: don't build one.

## Pipeline specialization (SHIPPED — Specialization.swift)

The generic march dispatches every DE evaluation through a visible function
table: an indirect call per march step that blocks inlining. A pipeline
variant compiled with `#define THRESH_SPEC_DE de_<name>` calls the built-in
directly (same translation unit → inlined through the march loop).

A/B, same requests, images byte-identical (SpecializationTests):

| Scene | generic | specialized | win |
|---|---|---|---|
| default-bulb | 10.33 ms | 9.16 ms | ~11% |
| warped-bulb | 49.69 ms | 45.78 ms | ~8% |

Live sessions compile variants asynchronously (SpecializationCache — render
thread never blocks, generic until the variant lands); the CLI takes
`--specialize`. Built-ins only; externals keep their per-program pipeline.

## Stutter diagnosis + fixes — 2026-07-03 (perf block 2)

Question: "why does the live app stutter?" Method: FrameProfiler hitch
attribution (per-spike phase breakdown, new in this block) + governed A/B
runs on a 120 Hz Mac display at a 4.5 Mpx window, `THRESHOLD_PROFILE=1`.

Diagnosis (measured, not guessed):

- **GPU-bound, decisively.** CPU orchestration is innocent: step ≈ 0.03 ms,
  encode ≈ 0.15 ms, drawable-wait ≈ 0.003 ms against 20–85 ms GPU frames.
- **The stutter is vsync quantization.** Hitch gaps land at exact multiples
  of the refresh interval, correlated with the previous frame's GPU time —
  a 1.2-interval GPU frame slips a whole vsync. GPU time also swings 2–3×
  frame-to-frame at constant content, so cadence oscillates (60↔20 fps
  reads as stutter, not slowness).
- **Frames-in-flight was unbounded** (defect): CAMetalDisplayLink keeps
  delivering drawables when the GPU is behind; the callback ran at 35 fps
  while the GPU delivered 18 fps until makeCommandBuffer blocked at its own
  ~64 limit — seconds of present latency. The "drawable backpressure caps
  at 3" assumption in SessionGPUEncoder was false in practice.

Fixes (this block, all in the live path only — goldens untouched):

1. **In-flight cap**: DispatchSemaphore(3) paces encode to the GPU
   (InteractiveSession). Encode-block went 21 ms → ~0.15 ms and latency is
   bounded at 3 frames.
2. **Render-scale lever**: governor factor → resolution scale
   (`max(sqrt(factor), 0.5)`, quantized 1/20ths); march into a cached
   intermediate texture, `upscale_bilinear` into the drawable. Pixels are
   the linear cost driver — steps/iterations floor alone couldn't rescue
   high-res windows (56 ms GPU at factor floor; scale gets it under budget).
3. **Governor ON by default** in the app shell (8 ms target; sidebar toggle
   disables; `THRESHOLD_GOVERNOR=<ms>` overrides for profiling).

A/B at 4.5 Mpx, 120 Hz display, mandelbulb:

| | before | after |
|---|---|---|
| real fps | 23–37 | 104–120 locked |
| GPU/frame | 55–85 ms | 6.5–10 ms |
| hitches / 60 frames | 16–24 | 0–2 (mostly 0) |

Equilibrium render scale ≈ 0.55–0.6 at that window size — the honest
trade: softness under load instead of judder. An external 79 ms GPU spike
mid-run backed off and recovered within ~1 s (AIMD doing its job).

Profiler additions (RenderTelemetry): per-hitch lines (`HITCH frame N
inter=… step/drawable/encode/gpuPrev`) whenever a frame exceeds
max(1.5×EMA, EMA+4 ms) of the recent cadence, hitch counts per summary
window, and an os_signpost "hitch" event for Instruments correlation.
Capture recipe: `launchctl setenv THRESHOLD_PROFILE 1` (+ `_FILE`), `open`
the bundle, `xcrun xctrace record --template 'Metal System Trace' --attach
<pid>`; note CAMetalDisplayLink throttles hard when the window is occluded
— foreground the window or the numbers are garbage.

## Math-mode A/B + legacy audit — 2026-07-03 (perf block 3)

`THRESHOLD_MATH_MODE=fast|relaxed|safe` (GPUContext measurement seam,
default unchanged .safe; specialization follows the same mode). 1024²,
40 frames, `--specialize`, corpus scenes; two runs each (machine-load
variance in absolutes, ratios stable):

| Scene | safe | relaxed | fast | win |
|---|---|---|---|---|
| default-bulb | 7.3 / 8.7 ms | 5.2 ms | 5.5 / 7.1 ms | ~19–29% |
| warped-bulb | 37.6 / 38.9 ms | 26.9 ms | 24.8 / 29.6 ms | ~24–34% |
| Stress_test (legacy, 1080p) | 223 ms | — | 151 ms | ~32% |

- `relaxed` and `fast` produce **byte-identical images** on these scenes —
  if we ever leave .safe, relaxed (keeps INF/NaN semantics) is free.
- Image delta vs safe: 0.07–0.34% of pixels change, mean Δ ≈ 0.005/255,
  but max Δ up to 174/255 (silhouette pixels flipping hit/miss) — this is
  why goldens are only valid under .safe.
- Decision unchanged: .safe stays the default (determinism/CPU-equivalence).
  The compatible route to part of this win is per-call-site `metal::fast`
  on non-DE math (coloring/tonemap), NOT the global flag. The 19–34% above
  is the ceiling for the whole-shader switch.

Legacy-renderer audit (docs/research/legacy-renderer-techniques.md): the
old app rendered the same stress scene in **19.6 ms @1080p** with its
acceleration stack on (52.3 ms off — measured 2.67× from over-relaxation
ω≤1.6 + cone-march coarse prepass + distance LOD + bounding-sphere skip)
vs our 223/151 ms. Math mode explains ~1.5× of the gap; the rest is
step-count acceleration + orbit-cache shading we haven't built. That file
has the ranked port list; the per-DE-type ω caps (mandelbulb only
tolerates 1.1 — log-DE overestimates defeat the overshoot guard) are the
piece of design worth lifting verbatim.

## Platform quality settings — 2026-07-03 (perf block 4)

Ported the original app's platform-native resolution levers, driven by the
existing ADR-003 quality governor. One governor, one `renderScale` signal
(SessionCore, from prior-frame GPU ms), applied through each platform's best
mechanism:

- **visionOS (CompositorSession)** — the compositor's `renderQuality` API
  (visionOS 26, our min target). `maxRenderQuality = 0.8` at layer config
  (memory/thermal ceiling, Apple guidance + original app's measured choice);
  per frame, `layer.renderQuality = <governor renderScale>` set BEFORE
  `queryDrawables` so the drawable itself shrinks — the march runs fewer
  fragments and the compositor upscales natively, **foveation-aware**, over
  its own smoothed ramp. Applied one frame late (prior-frame target), which
  is immaterial against the compositor's multi-frame tween. This is the lever
  the original app credited for holding 90 fps; the rebuild's Compositor
  shell had none of it before. NOT the Mac intermediate-texture path —
  `renderScale` here only sizes the drawable.
- **macOS/iOS (InteractiveSession)** — unchanged from block 2 (intermediate
  texture + bilinear upscale). The "Mac equivalent" already existed.

Both real-app composition roots now ARM the governor (they didn't before —
only the SwiftPM dev shell did, so the shipping Xcode app on BOTH platforms
ran with no adaptive quality, which is a direct cause of the reported
stutter). `AppModelShared.defaultGovernor`: 8 ms target on Mac
(120 Hz-friendly), 10 ms on Vision Pro (under the 11.1 ms/90 fps budget with
present headroom). The Auto Quality toggle (default on) still flips it.

Verified: full test suite (372) green; `ThresholdRender` and the whole
`Threshold` app both build clean for the visionOS simulator SDK. On-device
`renderQuality` behavior + the right floor still need a Vision Pro sweep
(no headset numbers yet — the original app's PERF_LOG rule stands: device
numbers are the only citable Vision Pro perf).

Open tuning (needs device): the shared `renderScale` floor is 0.5 (Mac
bilinear-tuned). The compositor upscaler degrades more gracefully, so Vision
Pro may want a lower floor — a one-line change once a sweep says so. Also
still open: MetalFX spatial upscale on Mac (sharper than bilinear at equal
input scale — the original app's `MacSpatialUpscaler` is the reference), and
making resolution the governor's PRIMARY lever over iteration reduction
(iteration drops change the fractal silhouette; resolution drops only soften
— cleaner under load, especially in-headset).

## Resolution-only governor + MetalFX temporal — 2026-07-03 (perf block 5)

Three decisions, one unification:

1. **The governor no longer touches iterations/maxSteps.** Live testing
   showed the multiplicative iteration factor visibly reshaping the DE (the
   mandelbulb's detail threshold jumped discontinuously and the recovery
   oscillated). The governor now emits ONE signal — `renderScale` — carried
   on the frame request. Resolution softens; it never reshapes the fractal
   (ADR-003 update).
2. **Mac/iOS resolution mechanism = MetalFX temporal upscaling** (the
   bilinear spatial kernel is deleted). The march kernel gained a
   function-constant aux variant (THRESH_AUX, buffer 7 / textures 1–2 —
   private live-path contract, NOT ABI) that writes linear depth + motion
   vectors (reprojection through the previous frame's camera, computed
   in-kernel from hit t — no separate motion pass, unlike the original
   app's fragment path) and jitters ray-gen by a Halton(2,3) sub-pixel
   offset. The offscreen/golden path compiles with the constant false —
   codegen unchanged, corpus byte-identical (verified: full suite green).
3. **visionOS resolution mechanism = compositor renderQuality** (block 4,
   unchanged). One governor, one signal, two platform mechanisms; floors
   come from `QualityGovernorConfig.platformDefault` (Mac 0.35 — MetalFX
   temporal reconstructs well below half res, max 3×/axis; visionOS 0.5).

TemporalUpscaler (ThresholdRender) is ported from the original app's
MacTemporalUpscaler with its two hard-won details (size-keyed LRU pool;
reset-before-texture-assignment) plus one fix the old app didn't have:
**scaler builds are async** (SpecializationCache pattern). Measured on the
render thread before the fix: 1960 ms first MetalFX build, 165–368 ms per
size revisited during the governor's descent — every scale change was a
hitch. After: `prepare` returns the nearest READY configuration (or nil →
full-res direct) while the exact size builds off-thread; descent frames
encode in ~0.1–0.2 ms.

Verified: 372 tests green (incl. golden corpus → aux=false byte-identical),
Metal validation layer clean through the temporal path, visionOS
ThresholdRender builds, live run holds ~52 fps at 1.5 Mpx mid-descent.
NOT yet verified (needs eyes on a visible window): temporal image quality —
ghosting/shimmer would indicate a motion-vector or jitter sign error; the
math follows Apple's convention (projection-translate emulated in ray-gen,
motion = previous − current in input pixels, y-down).

Known gaps: external DEs have no aux pipeline variant yet — they render at
full resolution regardless of the governor (correct, just ungoverned). The
CLI `--specialize` path keeps aux=false (byte-identical contract with the
generic offscreen pipeline preserved).

## Measured non-problems (decided against, with reasons)

- **Per-frame CPU allocations** (SessionGPUEncoder's params/ops MTLBuffers):
  two ~1 KB shared-storage allocations per frame, tens of µs against 10–50 ms
  GPU frames. A buffer ring would be churn without a measurable win. Revisit
  only if profiling shows render-thread jitter attributable to allocation.
- **Custom shader disk cache**: see startup above — the OS already does it.

## Known levers not yet pulled

- **Warp-stack specialization**: extend the THRESH_SPEC seam to bake the op
  KIND sequence (codegen an unrolled applyPointOps per stack signature).
  Expected single-digit % on warped scenes — part of the +45%/step gap is
  legitimate twist math, not dispatch. Do after profiling says dispatch still
  matters.
- **Step-count reduction** (over-relaxed sphere tracing, cone marching):
  changes images → golden regeneration + quality review. The big lever for
  warped scenes (2.8× steps), but not a free one.
- **Compositor shell**: the raster path does not yet use specialization
  (ViewPassEncoder builds the generic fragment pipeline). Same seam applies
  when the headset needs the headroom.
- **mathMode .safe**: deliberate (determinism/CPU-equivalence, GPUContext
  doc). Any fast-math experiment must re-run the full golden corpus.
