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

## Bakes on by default + over-relaxation A/B — 2026-07-03 (perf block 6)

`RenderTuning.envDefault` now enables ALL function-constant bakes
(iterations, maxSteps, warp-ops gate, color-map mode, AO gate). Measured
Stress_test @1080p, 30 frames, release CLI:

| Config | avg GPU | totalSteps |
|---|---|---|
| generic (no --specialize) | 182.9 ms | 6.42B |
| specialized, no bakes | 165.5 ms | 6.42B |
| specialized + all bakes | 153.4 ms | 6.42B |
| + ω=1.0 (`THRESHOLD_STEP_MULTIPLIER`) | 146.9 ms | 5.77B |
| + ω=1.2 | **130.4 ms** | 5.06B |
| + ω=1.6 | 147.6 ms | 5.83B |

- All-bakes output is **byte-identical** to generic (cmp on PNGs).
- The old 0.9 stepSafety default is a measured pessimization: plain ω=1.0
  is ~4% faster, ω=1.2 ~15% faster on this (Kleinian) scene. ω=1.6
  regresses Kleinian — matches the legacy per-DE cap table (1.2 for
  Kleinian, 1.6 box-fold, 1.1 log-DE). Next port step: per-DE ω caps in
  DERegistry + raise the default; needs a golden rebaseline since
  stepSafety changes marched output.

## Frame-time benchmark harness + 10 optimization rounds — 2026-07-03 (perf block 7)

New standing infrastructure:

- **`FrameBenchmark`** (ThresholdRender): warmup + measured frames →
  median/mean/p95/min/max GPU ms + median FPS. CLI: `--bench <n>`
  `--bench-warmup <n>` `--bench-json <path>`, plus `--max-steps <n>`
  (device-local, not scene-persisted) and measurement seams
  `THRESHOLD_EPS_SCALE`, `THRESHOLD_TG=WxH`.
- **`Scripts/bench-suite.sh`** — THE regression suite. bench-mandelbox scene
  (mandelbox, iterations 9), maxSteps 120, specialized, 1024²/1800²/2048².
  Goal: ≥ 30 fps at 2048². Appends to `bench-results/history.jsonl` with git
  rev. Run after every perf-relevant change; exits 1 on goal failure.

Rounds (warped-bulb 1024² specialized until the suite existed, then the
triplet). Medians:

| Round | Change | warped-bulb 1024² |
|---|---|---|
| 0 | baseline | 19.68 ms (50.8 fps) |
| 1 | specialized pipelines default .relaxed math | 16.14 ms |
| 2 | per-DE ω caps (DEDescriptor.stepRelaxation), default over-relaxed | 13.77 ms |
| 3 | AO 5→3 taps (rescaled decay) | 13.31 ms |
| 4 | mandelbulb single-pow (r^p = r^(p-1)·r) | 13.20 ms |
| 5 | hasDistanceOps function constant 6 → DCE dist-op loop | 11.44 ms |
| 6 | all spec bakes default ON in CLI | 11.46 ms |
| 7 | reduced-iteration normals (0.6×)/AO (0.5×) via ctx.lodScale | flat on bulb; −4.5 ms on mandelbox 2048² |
| 8 | mandelbulb ω 1.1→1.3 (retreat guard holds; meanΔ 0.5/255) | 10.11 ms |
| 9 | sqrt-free orbit traps (squared min, one sqrt at return) | −0.6 ms @2048² box |
| 10 | epsilonBase 1e-3 → 1.5e-3 (cone eps; near-surface crawl ∝ 1/ε) | −18% @2048² box |

Suite result (mandelbox iters=9 steps=120): 1024² **8.07 ms / 123.8 fps**,
1800² **23.70 ms / 42.2 fps**, 2048² **30.42 ms / 32.9 fps → goal PASS**.
Baseline before block: 2048² was 42.3 ms / 23.6 fps.

Measured dead ends: threadgroup shapes ≠ 8×8 all regress; ω > 1.6 regresses
mandelbox; maxSteps 120→60 and maxDist 64→16 both no-ops (cap rarely hit).

Fidelity notes (deliberate, FPS-first): specialized .relaxed is no longer
bit-identical to generic in principle (SpecializationTests now pin .safe to
test the mechanism); AO is 3-tap; normals/AO evaluate the DE at 0.6×/0.5×
iterations; epsilonBase 1.5e-3 slightly softens finest detail. Goldens run
the generic .safe pipeline and still pass (390/390).

## Suite hardening + rounds 11–14 — 2026-07-03 (perf block 8)

Suite upgrades (user ask: longer runs, CSV memory, consistency):

- 60 measured frames/resolution (was 20), `--frames N` to go longer.
- **`bench-results/history.csv`** — one row per (run, resolution) with a
  REQUIRED `-m "note"` describing what was tested. JSONL kept alongside.
- Consistency: the offscreen harness has NO quality governor / MetalFX /
  renderScale — auto-quality structurally cannot touch these numbers (the
  live app's HUD numbers are a different, governed path).
- Observed run-to-run variance at 2048²: one run mid-block read 29.3 ms vs
  24.9 on immediate re-run (thermal/system load). Trust re-runs; the CSV
  history makes outliers visible.

| Round | Change | 2048² median |
|---|---|---|
| (block 7 end) | | 30.4 ms / 32.9 fps |
| 11 | stats step-count atomic behind function_constant 7; bench bakes OFF | 26.8 ms / 37.3 fps |
| 12 | normals: 4-tap tetrahedron → 3-tap forward diff, center = march hitRadius | 25.0 ms / 40.0 fps |
| 13 | AO 3→2 taps | flat (kept) |
| 14 | grading identity fast paths (skip ACES at tonemap 0, pow at gamma 1) | flat (kept, exact at defaults) |

Block total (7+8): 2048² mandelbox 42.3 → 25.0 ms (23.6 → 40.1 fps).
390/390 tests green.

## Hierarchical cone-march prepass + CPU/precision rounds — 2026-07-03 (perf block 9)

**The headline: 2048² mandelbox 25.0 → 14.0 ms (40 → 71 fps). The suite goal
(30 fps @2048²) now passes at 2.4×.**

| Round | Change | 2048² median |
|---|---|---|
| 15a | tile cone-march IN-KERNEL (threadgroup mem + barrier) | 28.6 ms — REGRESSION, discarded |
| 15b | cone-march as SEPARATE COARSE DISPATCH | 12.9 ms (77.6 fps) |
| 15c | verify-panel safety fixes (see below) | 14.0 ms (71.2 fps) |
| 16 | CPU caching: output/cone/stats reuse, bench readback skip, env-read hoists | GPU flat; p95 tightened (alloc spikes gone), ~2-5 ms CPU/frame saved at 2048² |
| 17 | specialized mathMode .fast + bit-pattern NaN guards | ~2.5% (12.9→12.6-class, pre-15c) |
| 18 | sincos pairing in bulb DEs | 4.61→5.56 ms on warped-bulb — REGRESSION, reverted |

Cone-march design (RaymarchCore.metal march_cone_prepass + THRESH_CONE gate,
function constant 8, aux-style bool):

- One thread per 8×8 tile marches the tile's CENTRAL ray, accepting steps
  only while the DE clears the tile's whole angular footprint
  (coneK·t; coneK = 1.1 × max corner-ray deviation, corners pushed 1 px for
  jitter). Safe depth → r32float texture; the fine kernel starts there.
- The in-kernel threadgroup version LOST (63 idle threads behind a barrier
  while thread 0 marches); the separate coarse dispatch (fully parallel,
  64× fewer threads, no barrier) is the winning shape.
- Adversarial verification (3-agent panel) CONFIRMED the geometry (corner
  bound valid — quasi-convex angular deviation; step formula keeps the whole
  advanced segment inside the empty sphere) and found two real majors, both
  fixed: (1) prepass stop threshold now 3× the fine hit epsilon so edge
  pixels can't immediate-hit at the tile-shared depth (was: 8×8-quantized
  silhouettes); (2) poisoned-start recovery — warp-op dScale corrections are
  local bounds, so a center-ray overshoot INSIDE the surface froze a bad
  depth for all 64 pixels; the fine march now restarts from t=0 when its
  first sample at tileStart is already inside (negative distance). Plus a
  loop-top far-plane guard (prepass t=maxDist must miss, not sample there).
- Warped-bulb visual check cone on/off: indistinguishable, no tile blocks.
  Warped-bulb is now 4.8 ms @1024² (was 19.7 at block-7 baseline — 4.1×).
- Known accepted gaps: prepass steps aren't in totalSteps telemetry (gpuMs
  is the metric); live session never bakes coneMarch (encoder contract
  documented on MarchSpec.coneMarch); no unit test renders a cone variant
  (CLI bench is the gate); tile size 8 hardcoded in Swift + MSL (cross-ref
  comments at both sites).

Precision scout verdict (2-agent audit): half-precision shading/output is
below the noise floor on M1 Pro (skip; revisit for Vision Pro thermals);
MTLCompileOptions.mathFloatingPointFunctions already defaults .fast so
hand-written metal::fast:: qualifiers would be a no-op; sincos pairing
measured as a regression under .fast (compiler already optimal) — reverted.

CLI --specialize contract update: it is the PERF pipeline (fast math, cone
prepass, all bakes) and NO LONGER byte-identical to generic. Goldens gate
the generic .safe pipeline (unchanged, 390/390 green).

## Live-path cone prepass + perf-tracked commits — 2026-07-03 (perf block 10)

**Live port (Mac/iOS compute path):** `RenderTuning.conePrepass` (default ON
via envDefault; UI/A-B toggle like every bake), `SessionGPUEncoder` now
dispatches `march_cone_prepass` before the march when the specialized
variant carries it, with a 3-deep cone-texture ring parallel to the stats
ring (in-flight frames must not share the prepass texture) and a generic-
pipeline fallback if the texture allocation fails (a cone-baked pipeline
requires texture 3). The prepass sizes to the MARCH TARGET, so it composes
with MetalFX temporal (reduced-res input). New ConePrepassTests: offscreen
cone-variant render (tolerance + no-NaN-tile guard) and a real
CAMetalLayer-drawable live-encoder test that waits for the specialized cone
variant to land (392 tests green).

**visionOS Compositor NOT ported** (documented in RenderFeatureTable as
compute-shells-only): the raster path has no specialization seam at all yet
— porting needs specialized fragment pipelines + per-view (invProj-based)
prepass ray generation + a per-view cone texture array. Own block; the
compositor's win today is unchanged (renderQuality governor).

**Perf-tracked commit flow** (`Scripts/bench-commit.sh -m "..."`):
commit code → bench the CLEAN sha (CSV rows never say +dirty) → attach the
result table as a git note (refs/notes/bench) on the code commit → archive
CSV/JSONL + per-run sample JSONs to the results-only orphan branch
`bench-history` (each commit there names the measured main sha).
`bench-results/` is gitignored on main. Reading history:
`git log --oneline --notes=bench` (perf inline with code history) /
`git show bench-history:history.csv` (the full CSV) — a perf regression
bisects by walking either one.

## visionOS raster cone-march + specialization port — 2026-07-03 (perf block 11)

The stereo raster path (visionOS Compositor shell) had NO specialization seam
at all — it dispatched one generic table-dispatch fragment pipeline. This
block brings BOTH the specialization overlay (direct-call inlined DE, fast
math, all the bakes) AND the hierarchical cone-march prepass to it, so the
Vision Pro render path gains the same per-step + hierarchical wins the compute
shells got in blocks 7–10.

Mechanism:
- **Per-view cone prepass** (`march_cone_prepass_view` in RaymarchCore.metal):
  one compute thread per (tile, view). Rays are generated through
  `ThreshViewUniforms.invProj`/`orient` — the SAME unproject-two-points model
  the fragment uses (factored into `threshViewDirLocal`), NOT the compute
  path's pinhole `threshRayDir`. Writes each view's safe start depth to a
  `texture2d_array` slice. Everything is expressed in LOGICAL NDC, so
  foveation (variable rasterization rate) needs no rate-map decode: a tile is
  a fixed NDC rectangle, and the fragment's `in.ndc → tile` map is the exact
  inverse of the prepass's `texel → centerNdc` layout (adversarially verified —
  physical/logical mismatch never enters either side; at worst suboptimal tile
  sizing in the fovea, never incorrect).
- **Specialized raster pipeline** (`GPUContext.makeSpecializedRaster`): the
  `thresh_march_fragment` compiled from the THRESH_SPEC_DE library with
  function constants 0–8 (shared `specConstantValues` with the compute path),
  a fragment-stage DE table, and the per-view prepass compute pipeline +
  compute-stage table when `coneMarch` is set. `RasterSpecializationCache`
  (ViewPass.swift) is the async non-blocking cache — frames render generic
  until the variant lands off-thread, exactly like SpecializationCache.
- **ViewPassEncoder** dispatches the prepass (compute) before the render pass
  into a 3-deep cone-texture ring, binds it at fragment texture 3, and falls
  back to generic when the variant isn't ready or the prepass can't allocate.
  The generic fragment is now built via `makeFunction(constantValues:)` (empty)
  because it gained a THRESH_CONE-gated argument.
- `RenderTuning.conePrepass` flows to the raster path via `request.tuning`
  (CompositorSession.stampHandOps now preserves tuning + renderScale);
  `MarchSpec.from(tuning:params:opCount:)` is shared by the Mac and raster
  encoders. RenderFeatureTable: `march.conePrepass` now spans all three shells.

Verification: CompositorParityTests extended — a specialized+cone raster
render stays within tolerance of the generic raster render with no
NaN-sentinel tiles (the wiring gate: tile-map, prepass dispatch, texture-3
binding). 393 tests green; ThresholdRender AND the full app build clean for
the visionOS simulator SDK. A 3-agent adversarial panel (foveation tile-map,
2-view amplification/wiring, GPU hazards/lifetime) returned ZERO refutations.

NOT done here (honest gaps):
- **No device numbers.** Vision Pro perf is device-only (PERF_LOG rule). The
  Mac parity path proves CORRECTNESS (raster ≡ compute, cone ≡ non-cone within
  tolerance); the FPS win must be measured in-headset. Expect the compute
  path's ~2× step-bound win to translate, less the raster/fragment overheads.
- **2-view amplified + foveated tile mapping** run only on device (the Mac
  test is single-view, maxViewCount=1). The slice indexing (prepass write
  slice gid.z ↔ fragment read slice ampIndex ↔ views[] index) was verified by
  inspection, not execution.
- **Dedicated (no-foveation) layout** encodes twice/frame over the 3-deep cone
  ring — ~1.5 frames of headroom, the same marginal contract the stats ring
  already carries; safe by GPU hazard ordering (only a pipelining cost). The
  device default (layered + foveation) has full 3-frame headroom.
- External DEs still render generic on the raster path (built-ins only — spike
  scope, unchanged).

## Cone-prepass UI controls + stability lever — 2026-07-03 (perf block 12)

The cone prepass (blocks 9–11) is a large step-count win but its tile-shared
start depths shimmer at silhouettes (tile-quantized starts jitter frame-to-
frame). Exposed two live controls in the Pipeline panel (ThresholdUI
PipelineSection), plus the underlying shimmer lever:

- **"Cone Prepass" toggle** → `RenderTuning.conePrepass` (function_constant 8,
  already existed). The definitive shimmer kill-switch / A-B.
- **"Cone Stability" segmented picker** (Fast / Balanced / Stable) →
  `RenderTuning.coneStability` → `MarchSpec.coneMargin` → new
  **function_constant 9** (`thresh_cone_margin`). The prepass stop threshold
  is `margin × epsBase × t` (was a hardcoded 3×); higher backs the shared
  start depth further off the surface so the per-pixel march refines more and
  fewer edge pixels immediate-hit at the tile depth — less shimmer, a few more
  steps. Levels: Fast 3× (the block-9 default), Balanced 6×, Stable 12×.

Function-constant decision (the question was whether to use one): the on/off
gate stays a function constant (structural — gates the prepass dispatch + the
fragment cone argument). The margin is ALSO a function constant, but a
**discrete** one — a continuous slider would recompile a pipeline variant per
tick (compile storm), whereas 3 levels are 3 cached variants. A continuous
value would have needed a new engine param slot (ABI change); the discrete
function constant reuses the existing MarchSpec→specConstantValues→cache
machinery with zero ABI surface. CLI A-B: `THRESHOLD_CONE_MARGIN=<int>`.

Measured (2048² mandelbox, same session, thermally elevated): margin 3 →
16.69 ms, 6 → 17.24, 12 → 17.79 — monotone, ~3% per doubling, confirming the
shimmer↔speed trade is real and small. Default (nil / .fast) is BYTE-IDENTICAL
to the block-9 baseline (shader maps the -1 sentinel to 3.0); goldens and the
395-test suite unchanged. visionOS raster path picks this up for free —
MarchSpec.from feeds both encoders, so the picker drives the Vision Pro shell
too (device shimmer/perf still needs an on-headset sweep).

## Render Quality ceiling + compute backend option — 2026-07-03 (perf block 13)

**Render Quality in the UI (ADR-003 made true):** `manualRenderScale` was
IGNORED whenever Auto Quality was on, contradicting ADR-003's "quality
sliders stay the user's ceiling". SessionCore now clamps the governor's
adaptive scale to the user's setting in both modes: governor on → adaptive in
[minRenderScale, ceiling]; off → the ceiling IS the scale. The Pipeline panel
slider is renamed "Render Quality" (works always), and "Effective quality" —
what the encoder actually rendered at — is shown unconditionally. On Vision
Pro the same value caps the compositor renderQuality; on Mac it caps the
MetalFX input scale. New SessionCore test locks the ceiling semantics.

**Compute-vs-fragment backend (ADR-001 "compute phase 2"):** the compositor
shell gains a selectable rendering backend — Settings ▸ Rendering (visionOS),
persisted in UserDefaults (`threshold.render.backend`), applied at layer
configuration when the immersive space next opens:

- `fragment` (default): the shipping foveated raster path, unchanged.
- `compute` (experimental): NEW `march_view_compute` kernel — the identical
  per-view ray model and presentation semantics as the fragment (shared
  `threshViewDirLocal`, same clip-depth formula, miss = transparent),
  dispatched as a compute grid (w, h, viewCount) into intermediate color +
  r32Float depth ARRAYS, then blitted into the drawable (color: sRGB-variant
  copy, compute writes linear → hardware encodes; depth: r32Float →
  depth32Float, the copy-compatible pair — proven bit-exact by a new
  round-trip test on real hardware, not assumed from docs). Full
  specialization + cone-prepass support via `SpecializedViewCompute` /
  `ViewComputeSpecializationCache` (ViewCompute.swift), reusing
  march_cone_prepass_view and the same MarchSpec machinery.

Why an option, not a default: compute cannot consume rasterization rate
maps, so foveation is unavailable (the config gates it off for compute) and
two blit copies are added. What compute may win back: threadgroup-coherent
march scheduling, no fragment-interlock overhead — and it is the shape that
could later host threadgroup-shared refinement. The honest expectation is
fragment+foveation wins on device; the picker exists to MEASURE that
(PERF_LOG rule: device numbers only). Everywhere else compute already IS the
path (ADR-001) — no change on Mac/iOS/offscreen.

Verification: compute-backend ≡ raster-backend parity on Mac (same tolerance
contract as fragment≡compute), specialized+cone compute variant renders
sentinel-free, depth-blit round trip bit-exact, 398 tests green, visionOS
full app + Mac app build clean. Diagnostics: the panel shows
"Compute (visionOS)" when the backend is active.

NOT measured: Vision Pro FPS for either backend (device-only). The compute
backend also has no resolution lever yet (renderQuality is foveation-gated;
an internal-scale intermediate would be its equivalent — add if the device
A/B makes compute worth keeping).

## Backend decision + Render Quality placement — 2026-07-03 (perf block 14)

**DECISION: fragment + foveation is the visionOS backend.** Losing foveation
is not worth compute's theoretical wins on this hardware. The compute backend
stays in the tree as a device-A/B instrument only (Settings caption says so
explicitly); fragment remains the default and the recommendation.

**Device datapoint (user-reported, Vision Pro):** the raster path's
[[depth(any)]] writes are confirmed working in-headset — a passthrough hand
entering the fractal is occluded when it crosses the marched surface. That
validates the projection-consistent depth formula (view.proj through the hit
t) end-to-end on device, including under the cone prepass.

**Render Quality moved to the Session card** (next to Auto Quality, where a
user looks for quality) instead of the bottom of the Shader Pipeline card:
slider (the ADR-003 ceiling) + a live "now N%" effective-quality readout, with
the caption switching between ceiling/exact-scale wording based on the Auto
Quality state. Pipeline card stays the shader-internals surface (bakes, cone
controls, pipeline readout).

## Distance-LOD iteration falloff — REFUTED — 2026-07-03 (perf block 15)

Audit item 8 (the last unclaimed "Medium impact / High confidence" ALU lever
from docs/perf-port-audit.md) ported and MEASURED AS A PESSIMIZATION on this
kernel. The port: function_constant 10 (`thresh_lod_falloff`, MarchSpec
`lodFalloff`, A/B seam `THRESHOLD_LOD_FALLOFF=<int>`) sheds F/16 fold
iterations per MODEL unit of ray distance in the primary march's mapScene
only (effIter = max(2, n − t·modelScale·F/16)) via the existing lodScale
seam — normals/AO keep their own reduced scales, cone prepass stays
full-iteration.

Measured, 1024² bench-mandelbox (iters 9, maxSteps 120, specialized+cone,
median of 30):

    off   4.01 ms   1.72 M march steps (512² stats run)
    F=16  4.09 ms   1.72 M   (visible t too shallow to shed 1 iter)
    F=32  4.46 ms   1.83 M
    F=64  6.05 ms   2.54 M

Monotone LOSS. Why legacy's win doesn't transfer: (1) the fold loop is
already unrolled at a baked count — shortening the runtime trip count saves
some unrolled-body ALU but re-introduces the dynamic bound the bake existed
to remove; (2) the march is over-relaxed (mandelbox ω=1.6) — a t-varying
iteration count makes the DE value jump between adjacent samples, so the
sphere-overlap check (radius+prevRadius < stepLength) fails spuriously and
the retreat drops ω to 1 for the rest of the ray: step counts EXPLODE
(+47% at F=64) faster than per-step cost falls. Legacy marched at fixed
ω-caps with a plain conservative fallback, and its fold loop was
runtime-bounded anyway — different trade surface.

Disposition: the seam stays (default OFF — the -1 sentinel folds the whole
computation out at pipeline-specialization time; off-state re-verified
bit-identical and bench-neutral), as a cheap re-test hook for future heavy
DEs where iteration cost dominates and ω is already 1 (Bulatov-class). Do
NOT wire it into RenderTuning/UI. With this, every confirmed item of the
original 3x audit is either PORTED (1,2,3,5,7,9,10 + fast-math), REFUTED
(8), or REMAINS by design (4: redundant with the cone prepass's empty-space
skip; 6/11: sub-ms hit-shading tail, revisit only if a scene shows a
shading-bound profile; 12–14: launch-latency, not steady-state ms).

## Instrumentation — 2026-07-07 (ADR-006 Phase 0)

Before optimizing the sphere-tracer hard, the harness was made to answer *why*
a number moved, not just *that* it moved. Three additions, all in
`bench-suite.sh` + `FrameBenchmark`/`threshold-render`:

**ns/step is back, without contaminating the timing pass.** `--bench` without
`--stats` bakes `statsEnabled = false` (function_constant 7), so the measured
frames run atomic-free and GPU-ms is clean — but that left `totalSteps: 0` and
no way to separate "fewer steps" from "faster steps." Fix: after the timing
loop, the CLI builds a stats-ON *twin* of the exact same `MarchSpec` and renders
a few frames through it to recover the deterministic per-frame step count (same
pixels every frame ⇒ constant), then reports `ns/step = medianMs·1e6 /
stepsPerFrame`. The timing samples are byte-for-byte unchanged (the probe runs
after them), so history stays comparable. Generic runs already count inline and
skip the twin.

**Noise band + thermal.** Every run now records `cov% = σ/mean` (sample stdev)
and `ProcessInfo.thermalState`. A regression has to clear the noise band to be
real; a `serious`/`critical` thermal tag explains a slow run instead of letting
it masquerade as a regression. (Observed: cov ≈ 1–6 % at 1024²–2048²/260 f; it
balloons at tiny frame counts — trust ≥120 f.)

**Baseline Δ.** `--set-baseline` snapshots the per-res medians to
`bench-results/baseline.json`; subsequent runs print `Δ%` vs it.
`--strict-baseline [--tol N]` (default 3 %) trips the suite on a median
regression at ANY resolution — orthogonal to the existing absolute 2048² ≥70 fps
floor. All of this lands in `history.jsonl` (additive keys) + the console;
`history.csv` keeps its legacy 16-column schema. `BENCH_RESULTS_DIR=…` redirects
the sink for scratch/CI runs.

**Still manual — the ALU-bound premise (item 2).** The "≈70 % ALU" figure that
justifies the whole ALU-first optimization plan is inherited from the *legacy*
renderer (`perf-port-audit.md`) and has **never been re-measured on this
kernel**. The harness has no GPU counters and adding a robust headless
`MTLCounterSampleBuffer` path is device/OS-gated and fragile, so this stays a
one-time manual capture, to be done before Phase 2:

1. Build the app via Xcode; run a stress scene (warped-bulb or Stress_test) at
   2048².
2. Xcode ▸ Debug ▸ Capture GPU Frame (or Instruments ▸ Metal System Trace).
3. Select the `march_offscreen` / specialized march kernel; open the Shader
   Profiler → **limiter/occupancy** view. Read the ALU vs memory vs
   control-flow breakdown and the achieved occupancy.
4. Record the numbers here with the scene + device. If the kernel is *not*
   ALU-bound, the Phase-2 lever ordering (occupancy/DCE first) is re-prioritized
   before any march-math micro-opt.

## SkipVolume A/B — 2026-07-07 (measured, decisive)

First real measurement of the world-space empty-space skip volume (ADR-006
Phase 2). Isolation design: `noskip`/`hash`/`dense` are ALL generic (no cone, no
specialization, atomic-on) so steps AND ms are comparable; `spec+cone` is the
shipping reference. 1024², 120 f, grid 64. Δ vs `generic, no skip`.

| Scene | config | median ms | steps/frame | ns/step | Δsteps | Δms |
|---|---|---|---|---|---|---|
| default-bulb | generic no-skip | 6.10 | 18.86 M | 0.32 | — | — |
| | + skip hashed | 11.97 | 16.28 M | 0.74 | −13.7% | **+96.4%** |
| | + skip dense | 9.95 | 16.28 M | 0.61 | −13.7% | **+63.2%** |
| | spec+cone (ref) | 1.85 | 4.52 M | 0.41 | −76.1% | −69.6% |
| bench-mandelbox | generic no-skip | 11.02 | 15.94 M | 0.69 | — | — |
| | + skip hashed | 12.71 | 15.94 M | 0.80 | +0.0% | +15.3% |
| | + skip dense | 11.46 | 15.94 M | 0.72 | +0.0% | +4.0% |
| | spec+cone (ref) | 4.22 | 6.22 M | 0.68 | −61.0% | −61.7% |
| menger-sponge | generic no-skip | 6.54 | 17.69 M | 0.37 | — | — |
| | + skip hashed | 9.40 | 16.23 M | 0.58 | −8.2% | +43.6% |
| | + skip dense | 8.52 | 16.23 M | 0.52 | −8.2% | +30.2% |
| | spec+cone (ref) | 1.83 | 7.61 M | 0.24 | −57.0% | −72.0% |

Findings:
- **Step-shedding is real but modest and content-dependent** — −13.7% bulb,
  −8.2% menger, **0.0% mandelbox** (matches the SkipVolumeTests hint: box-fold
  DEs never over-estimate enough for a brick to prove empty). Occupancy data is
  identical for hashed vs dense (same emptiness proof), only the lookup differs.
- **Wall-clock LOSS on every scene (+4% … +96%).** ns/step is the tell: the
  skip probe roughly *doubles* per-step cost (bulb 0.32 → 0.74 hashed / 0.61
  dense). A 14% step cut at 2× cost/step is a net loss. Dense beats hashed
  everywhere (cheaper indexed read vs CAS linear probe), as the file's own note
  predicted.
- **The cone prepass already wins this job.** It sheds **57–76%** of steps
  (4–9× more than skip) and runs **3–6× faster** — because skip forces the
  generic march and gates the cone prepass OUT (`OffscreenRenderer` exclusivity).
  Skip isn't just failing to help; it's replacing a strictly better empty-space
  mechanism with a weaker one.

Disposition: **stays OFF** (already opt-in; goldens/benches untouched). The only
surviving path is ADR-006 Phase 2's condition — compose skip WITH specialized +
cone so it targets the *mid-ray interior* empty pockets cone's per-tile
start-depth can't catch — and only if a sparse / deep-zoom content class shows
cone leaving such pockets. Absent that demonstration this is a **shelve/cut**, not
an invest: on the tested corpus cone dominates. Do NOT wire skip into
RenderTuning/UI.
