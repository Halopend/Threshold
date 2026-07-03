<!-- Generated 2026-07-03 by a multi-agent comparative audit (legacy MetalRaymarch-main vs current rebuild). 45 agents; each delta adversarially verified against the live render path. Companion to docs/perf-notes.md. -->


# Why "Threshold" renders ~3x slower than legacy "MetalRaymarch-main" — port plan

## 1. Bottom line

The single biggest cause of the gap is that the current megakernel evaluates a **fully generalized, runtime-parameterized distance-estimator loop on an ALU/register-bound kernel that legacy specializes away at compile time.** Concretely: every built-in DE reads its fold-loop trip count from device memory (`int iterations = int(ctx.params[ctx.paramCount-1])`, `RaymarchCore.metal:338`) so the loop never unrolls, and the primary march is a strictly *conservative* sphere trace (`t += dm.x * stepSafety` with `stepSafety=0.9`, `RaymarchCore.metal:712` / `RenderRequest.swift:118`) — actually taking *shorter* steps than plain tracing, versus legacy's over-relaxation up to omega=1.6. Both defects are multiplied ~10x per shaded pixel because `mapScene` runs once per march step plus 4 normal taps + 5 AO taps, and those secondary taps run at **full iterations** (legacy runs them at 1/3–2/5). The three highest-leverage ports, all small-to-medium effort: **(1) bake iteration count as a function constant so the DE loop unrolls; (2) reduce normal/AO iterations to ~40% and unroll them via the same constant; (3) add over-relaxed sphere tracing with the overstep-retreat guard.** Perf blocks 1–5 already ported DE-call devirtualization, the resolution governor, and MetalFX temporal — so the remaining wins are squarely in per-pixel ALU, not the frame loop.

## 2. Ranked port plan

Leverage = (impact × confidence) / effort. Merged rows collapse the duplicate iteration-baking and over-relaxation findings that appeared under multiple audit dimensions.

| Rank | Item | Dimension | Impact | Confidence | Effort | Risk | Verdict |
|------|------|-----------|--------|-----------|--------|------|---------|
| 1 | **Bake fractal iteration count as a function constant → unroll the DE fold loop** (merges `iteration-loop-not-unrolled`, `iterations-not-baked`, `bake-iteration-count-fc`, `loop-bounds-from-memory-block-unroll`) | de-eval / specialization / data-layout | High | High | Small | Low (identical image) | confirmed |
| 2 | **Reduced-iteration normals & AO** (merges `secondary-rays-full-iters-runtime-loop`, `reduced-secondary-iterations`) — depends on #1 | shading | High | High | Small–Med | Low–Med (softer high-freq detail) | confirmed |
| 3 | **Over-relaxed sphere tracing (omega + overstep retreat)** (merges `no-over-relaxation`, `over-relaxed-sphere-tracing`) | raymarch-loop | High | High | Medium | Med (tunneling if caps mis-set) | confirmed |
| 4 | Per-ray bounding-sphere / safety-bubble early-out (`no-bounding-sphere-early-out`) | raymarch-loop | High | High | Medium | Med (needs per-scene radius) | confirmed |
| 5 | Bake `maxSteps` as a function constant (merges `max-ray-steps-not-baked`, `runtime-maxsteps-not-specialized`) — free rider on #1's seam | specialization | Low | High | Trivial | None (image-identical) | partially-confirmed |
| 6 | Half-precision shading tail (`f32-everywhere-vs-half-secondary`) | shading | Medium | High | Medium | Med (banding if applied to DE) | confirmed |
| 7 | Coarse-prepass / warm-start leading-empty-space skip (`no-warm-start-coarse-prepass`) | raymarch-loop | High | High | Large | High (ghosting/disocclusion) | confirmed |
| 8 | Distance-LOD iteration falloff (`no-distance-lod-falloff`) | raymarch-loop | Medium | High | Medium | Med (distant bulge/tunnel) | confirmed |
| 9 | `THRESH_HAS_WARP` function-constant gate on the op interpreter (merges `warp-interpreter-not-dce`, `runtime-op-loop-vs-codegen-unroll`) | data-layout | Low–Med | High | Small | Low (image-identical when empty) | confirmed |
| 10 | Specialize the visionOS raster path (`raster-path-no-specialization`) | specialization | Medium (visionOS only) | High | Medium | Med (render-pipeline cache) | confirmed |
| 11 | Cached/Jacobian normal fast path (`no-orbit-cache-jacobian-normals`) | shading | Medium | High | Large | Med (flat shading if wrong) | confirmed |
| 12 | MTLBinaryArchive + build-time metallib for built-ins (`no-binary-archive-and-runtime-source-recompile`) | specialization | Medium (cold-launch latency) | High | Large | Blocked by external-DE design | confirmed |
| 13 | Preset pipeline warm-up on scene load (`no-preset-pipeline-warmup`) | specialization | Medium (transient) | High | Medium | Low | confirmed |
| 14 | Pre-allocated params/ops ring vs per-frame `makeBuffer` (`per-frame-buffer-alloc`) | frameloop | Low (CPU hitch, not ALU) | High | Small | Low | confirmed |

## 3. Per-item detail

Legacy's own rule applies to every item: **land behind a toggle, measure before/after on the Stress-test scene (19.4ms baseline), change one lever per measurement.** The only real numbers are 19.4ms stress / ~40ms Bulatov / ~70% ALU on legacy — do not invent others.

### Item 1 — Bake iteration count → unroll the DE fold loop

- **Legacy:** `constant int FC_FRACTAL_ITERATIONS [[function_constant(0)]]` (`Shaders.metal:91`); `Map` reads `const int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations` (`Shaders.metal:1197`), baked at `RendererPipelineCache.swift:856` and keyed at `:341-351`. Shadow/dist loop uses `FC_SHADOW_ITERATIONS` (`Shaders.metal:1231`).
- **Current:** every DE reads a runtime bound — `const int iterations = int(ctx.params[ctx.paramCount - 1]);` then `for (int i = 0; i < iterations; ++i)` (`RaymarchCore.metal:338/345` mandelbox, `:366/372` mandelbulb, `:397/403` kleinian, `:424/430` menger, `:453/459` quaternion_julia, `:485/492` mandelbulb_julia). The only function constant in the shader is `thresh_aux_defined` (`RaymarchCore.metal:770`). Specialization bakes only `#define THRESH_SPEC_DE` (`Specialization.swift:52`) — not the count.
- **GPU mechanism:** a runtime trip count forces a live loop counter + per-iteration compare/exit branch and blocks constant-folding of per-iteration invariants (`pow(r,power-1)`, `fR2/mR2`). A compile-time bound lets the back-end unroll, hoist invariants, keep `z`/`dr`/`trap` in registers across the unroll, and drop the induction variable — the exact register-pressure lever a 70%-ALU kernel lives on. Multiplied ~10x/pixel (march + 4 normal + 5 AO taps).
- **Port steps:** add `constant int FC_ITERATIONS [[function_constant(1)]]` mirroring `thresh_aux_defined`; in each DE use `is_function_constant_defined(FC_ITERATIONS) ? FC_ITERATIONS : int(ctx.params[ctx.paramCount-1])` as the bound; set the constant via `MTLFunctionConstantValues` in `makeSpecializedMarch` (`Specialization.swift:42-75`, alongside the existing `GPUContext.swift:198-200` aux pattern); extend the `SpecializationCache` key to `(deName, iterations, aux)`. Surface the DE's iteration count from `DERegistry` to the CPU side. Fall back to the generic dynamic-bound pipeline while the variant compiles (cache already returns nil→generic).
- **Risk:** image-identical for a given count, so `SpecializationTests` must re-assert byte parity. **Caveat:** iterations flows through the resolve/governor lane — confirm it is *not* smoothly modulated per frame, or the cache will thrash with ~100–400ms recompiles. Quantize/bucket counts (defaults are 12/DE) to bound variant explosion.
- **Honest scope:** most DEs keep a data-dependent escape `break` (`:355, :374, :471, :494`), so the loop won't collapse to pure straight-line FMA — the win is register relief + invariant hoisting, real but not "critical."

### Item 2 — Reduced-iteration normals & AO (depends on Item 1)

- **Legacy:** `ReducedSecondaryIterations` (`Shaders.metal:1874-1882`) caps normal/shadow/AO iterations to `(iters*2)/5` (box-fold) or `(iters+1)/3` (Mandelbulb), floored 2–3; applied at `Shaders.metal:1903/1946/1963`. Marked STATUS active on all live paths in `PERF_TECHNIQUES.md:50`.
- **Current:** `calcNormal` (`RaymarchCore.metal:623-634`) does 4 tetrahedron `mapScene` probes and `cheapAO` (`:639-654`) does 5 more — all at the **same full iteration count** as the primary march. `iterations` is a single value (`RenderRequest.swift:143`, `SessionCore.swift:177`) used identically by primary and secondary rays. No reduced-iteration path exists (grep for `reduced/secondaryIter/normalIter` = zero hits).
- **GPU mechanism:** 9 secondary DE evals per hit pixel at full iters dominate the per-hit shading tail. Cutting to ~40% removes ~6×N fold iterations of ALU per hit pixel — pure ALU removal on the exact bottleneck.
- **Port steps:** add a reduced-secondary-iters value (a second engine slot, e.g. `THRESH_SLOT_SECONDARY_ITER`, or a `ctx` field) and thread it into `calcNormal`/`cheapAO`; bake it as a companion function constant to Item 1 so the secondary loops *also* unroll. Floor at 2–3 like legacy.
- **Risk:** deliberately changes the secondary DE result → softer high-frequency shading. Legacy accepted this; re-baseline the sampled-equivalence tests (`Tests/ThresholdRenderTests`). **Note:** the current shader has **no shadow march** at all — `marchShade` is Lambert + `cheapAO` only — so the largest legacy beneficiary (shadow iters) does not exist here yet; the win is confined to 4 normal + 5 AO taps.

### Item 3 — Over-relaxed sphere tracing

- **Legacy:** `omega = clamp(stepMultiplier, 1, relaxedOmegaCap(type))` (`Shaders.metal:2227`); `stepLen = h*omega` with overstep-failure retreat (`relaxedStepUpdate`, `:2062-2068`); per-fractal caps `relaxedOmegaCap` (`:2081-2105`): 1.6 box/fold, 1.2 Kleinian, 1.1 log-DE, 1.0 Bulatov. Smart-advance gradient lead-ahead up to ~2.8 (`:2144-2170`). STATUS active, executive-summary pillar #3.
- **Current:** `t += dm.x * stepSafety` (`RaymarchCore.metal:712`), `stepSafety` default 0.9 hard-capped ≤1.0 (`RenderRequest.swift:118`, `Catalog.swift:167-171`). No omega, no retreat, no `sorFail` guard (whole-tree grep confirms none). At 0.9 the kernel takes ~11% *shorter* steps than plain omega=1 — strictly worse.
- **GPU mechanism:** each march step is one full `mapScene`/DE-fold (the dominant ALU block). Omega=1.6 covers ~60% more empty-space distance per step, cutting `mapScene` calls per ray near-proportionally on an ALU-bound kernel.
- **Port steps:** raise `stepSafety` toward 1.0 first (guarded) to stop the current pessimization and measure. Then add omega with the **overstep-failure retreat** (re-evaluate and roll `t` back when a relaxed step overshoots the unbounding sphere) and the `!sorFail` hit guard; wire the per-fractal `relaxedOmegaCap` as a function constant per DE via the specialization seam (matching legacy's table).
- **Risk:** naive omega without retreat cracks/holes thin surfaces; Bulatov needs omega=1 (zero benefit there — and it's the ~40ms worst case). Visual regression if caps mis-set — the retreat logic makes it hit-safe.

### Item 4 — Per-ray bounding-sphere early-out

- **Legacy:** `rayIntersectBoundingSphere` jumps `t` to the sphere entry and returns a **zero-`mapScene` miss** when `sphereT<0` (`Shaders.metal:2200-2208`), gated by `FC_SAFETY_BUBBLE_ENABLED` (`:97, :994`). Tile version tests center+4 corners to skip 8×8 tiles (`:3021-3041`).
- **Current:** no bounding volume anywhere; every ray runs the full `maxSteps` loop (default 256, `RenderRequest.swift:116`) until hit/`maxDist`/exhaustion. A ray at empty sky pays the entire step budget of full DE evals. The ABI has no radius slot (engine slots 0–15, `ThresholdShaderABI.h:118-139`).
- **GPU mechanism:** converts miss-rays from up-to-256 full DE evals into one cheap analytic ray-sphere test — a direct ALU cut scaling with the frame's background fraction.
- **Port steps:** add a radius engine slot to the ABI; compute a conservative per-scene bounding radius CPU-side; add `rayIntersectBoundingSphere` before the march loop in `marchShade`, gated on `radius>0` so golden/offscreen output is unchanged when `radius==0`. Do the per-ray version first; treat the tile version (needs threadgroup restructuring) as a separate follow-on.
- **Risk:** too-tight a radius clips real geometry; the analytic jump itself is exact. Scene-dependent — a viewport-filling fractal sees little benefit.

### Item 5 — Bake `maxSteps` as a function constant (free rider on Item 1)

- **Legacy:** `baseMaxSteps = is_function_constant_defined(FC_MAX_RAY_STEPS) ? FC_MAX_RAY_STEPS : maxStepsParam` (`Shaders.metal:2214`), `FC_MAX_RAY_STEPS [[function_constant(6)]]`.
- **Current:** `const int maxSteps = int(params[THRESH_SLOT_MAX_STEPS]); for (int i = 0; i < maxSteps; ++i)` (`RaymarchCore.metal:688/704`).
- **Reality check (why Low, not High):** the loop has 3 data-dependent breaks — NaN/inf (`:708`), hit (`:711`), `t>maxDist` (`:713`) — so it can't fully unroll regardless of the bound; and **legacy itself computes `maxSteps = baseMaxSteps*quality` at runtime** (`Shaders.metal:~2215`), so it never had a compile-time march bound either. Expected win: ~one register + minor prologue scheduling.
- **Port steps:** add `#define THRESH_SPEC_MAX_STEPS N` alongside `THRESH_SPEC_DE` and `#ifdef`-gate the read. Trivial once Item 1's seam exists. Do **not** prioritize as a 3x lever.

### Item 6 — Half-precision shading tail

- **Legacy:** color/post pipeline in `half3/half4` (`applyFog :287`, `acesFilm :324`, etc.); coarse continuation DE in half (`MapContinuous :1269-1301`, `MAP_ITERATION_HALF :43-70`) — 193 `half` occurrences.
- **Current:** zero `half` tokens in `RaymarchCore.metal` — `mapScene`, `calcNormal`, `cheapAO`, `samplePalette`, `applyGrading`, and the whole shade block (`:716-747`) are f32.
- **GPU mechanism:** f16 issues at ~2x rate and halves register footprint on Apple GPUs, raising occupancy on exactly the named bottleneck.
- **Port steps:** half the **shade tail only first** (palette sample, Lambert, AO combine, grading) — low risk, once-per-hit-pixel. Then, separately, half the continuation-DE march math with retuned hit thresholds, keeping the distance accumulator `t` in f32 to preserve convergence.
- **Risk:** half in the fine DE fold causes banding/tunneling — confine to coarse/shade passes as legacy does. A blind find-replace would break convergence.

### Item 7 — Coarse-prepass / warm-start empty-space skip

- **Legacy:** `if (warmStartT > t) t = warmStartT;` (`Shaders.metal:2194`) from a coarse cone prepass (`FC_COARSE_WARM_START :148`) or temporal reprojection (`FC_WARM_START :132`, `computeWarmStartT :3848`); coherent-packet restart (`:2944-2984`) with a reduced step budget (`stepScale 0.25`, `:2301`); threadgroup coarse pass marks empty tiles (`:3004+`).
- **Current:** `float t = 0.0f;` (`RaymarchCore.metal:697`) — every ray cold-starts at the camera every frame. No warm-start, coarse pass, tile skip, or history. The aux path writes depth+motion (`:826-852`) but only as MetalFX inputs; the march loop has no `access::read` on depth and no history buffer.
- **Port steps:** **split this** — do the frame-local, non-temporal **coarse cone/tile prepass first** (lower risk, helps single frames, suits an ALU-bound kernel). Defer temporal reprojection (needs prev-depth history + disocclusion/backoff policy) as higher-risk.
- **Risk:** Large effort; temporal variants ghost/tunnel at silhouettes and do nothing for static golden renders. Realized gain is scene/motion-dependent (biggest with a large empty foreground).

### Item 8 — Distance-LOD iteration falloff

- **Legacy:** `int effIter = (distanceLODFalloff > 0) ? max(2, iterations - int(t*distanceLODFalloff)) : iterations;` then `MapUnified` runs with `effIter` (`Shaders.metal:2251-2252`).
- **Current:** every DE runs the fixed full iteration count with no `t`-dependence; `ctx.lodScale` is passed (`RaymarchCore.metal:533`) but no DE consumes it, and it's a per-frame constant (always 1, `CameraMath:50/61`) that couldn't express `t`-dependence anyway.
- **Port steps:** add `distanceLODFalloff` to the ABI; compute `effIter = max(2, iterations - int(t*falloff))` **per march step inside `marchShade`**; thread a per-step cap into `ctx` so every DE loop honors it. Apply falloff **only in the stepping map, not in `calcNormal`/`cheapAO`** (those need full detail at the hit point).
- **Risk:** too-aggressive falloff bulges distant surfaces or tunnels overestimating DEs; floor at 2. Only helps distant/background samples.

### Item 9 — `THRESH_HAS_WARP` gate on the op interpreter

- **Legacy:** `FC_HAS_SPACEWARP [[function_constant(3)]]` DCEs the entire warp seam to identity for empty stacks (`Shaders.metal:860/870/881`); `THRESHOLD_CODEGEN_SPACEWARP_STACK` replaces the loop with straight-line codegen when non-empty.
- **Current:** `applyPointOps`/`applyDistanceOps` are unconditional runtime `for`-loops over a device buffer with a 22-case switch, called from `mapScene` every step (`RaymarchCore.metal:527/547`, defs `:72-268/:276-320`). Op count is a runtime uniform (`U.meta.x`), never a compile-time constant.
- **Reality check (Low–Med):** for the common **empty-stack** case the loop body never executes — only a count read + not-taken branch remains, which the compiler hoists (loop-invariant). The residual cost is static register/occupancy from the fat switch inflating the pipeline's peak footprint. Heaviest scenes are DE-bound, not op-bound.
- **Port steps:** add `constant bool thresh_has_ops [[function_constant(N)]]`, wrap the two `apply*Ops` calls, bake it in `makeSpecializedMarch` keyed on `ops.isEmpty`. Fold `dScale` to a constant when no warp. The full op-stack codegen is a larger, count>0-only follow-on — skip initially.
- **Risk:** image-identical when empty. Extend sampled-equivalence tests to the gated variant.

### Items 10–14 (brief)

- **10. Raster-path specialization:** `ViewPassEncoder` builds one generic `thresh_march_fragment` pipeline with a `visible_function_table` and no function constants (`ViewPass.swift:129-177`); `CompositorSession` never consults `SpecializationCache`. Perf-block-1's direct-call win is **compute-only**. Port a render-pipeline specialization builder + lookup/swap in `ViewPassEncoder` mirroring `SpecializationCache` (handle color/depth formats + vertex amplification). Affects visionOS device perf, **not** the Mac 3x ground-truth. `CompositorParityTests` guards correctness.
- **11. Cached/Jacobian normals:** `calcNormal` unconditionally does 4 full DE calls (`RaymarchCore.metal:623-634`); the march discards its final hit DE state. Legacy `GetNormal` (`Shaders.metal:1923-1995`): analytic Jacobian = 0 extra calls (Mandelbox), `ApproximateMandelbulbNormal` = 2 probes, or cached-center 3-probe at reduced iters. Large effort (new OrbitCache/Jacobian struct threaded through `marchShade`'s result); the reduced-iter 3-probe fallback is the pragmatic first subset. Normals only, sub-ms to ~1.5ms of a 2–3ms tail — Medium.
- **12. Binary archive + metallib:** current compiles the megakernel from `.metal` source at runtime (`GPUContext.swift:119-134`) with each specialization a full ~100–400ms front-end compile (`Specialization.swift:48-62`); no `MTLBinaryArchive` (grep confirms). Legacy ships a `default.metallib` + per-GPU archive (`RendererPipelineHelpers.swift:7`, `PipelineBinaryArchive.swift:124-168`). Does **not** change steady-state ALU — it's cold-launch/respecialize latency and an enabling constraint on how many specialization axes are affordable. Blocked by the deliberate "same runtime-source path as external DEs" design; needs a dual path.
- **13. Preset warm-up:** purely lazy first-use — `SpecializationCache.lookup` compiles on the first frame that needs a DE and renders generic until it lands (`Specialization.swift:98-124`, `InteractiveSession.swift:470`). No warm-up at session start. Legacy `precompilePresetPipelines()` prebuilds every preset off-thread (`RendererPipelineCache.swift:396-462`). Enumerate `DERegistry.builtin` (+ aux twin) and call `makeSpecializedMarch` off-thread at session start. Transient window only — Medium.
- **14. Per-frame buffer alloc:** `makeFloatBuffer`/`makeOpsBuffer` do `device.makeBuffer(bytes:)` every frame (`InteractiveSession.swift:420-423`, `ViewPass.swift:231-234`, `GPUContext.swift:258-271`). Pre-allocate a `maxBuffersInFlight` ring written via `.contents()`, mirroring the existing stats ring. **CPU hitch item, orthogonal to the ALU gap** — sequence last.

## 4. Already handled / refuted — do not re-litigate

- **Perf block 1 (DE devirtualization) works and is live at steady state.** The `visible_function_table` indirect call (`RaymarchCore.metal:544`) is replaced by the direct inlined `THRESH_SPEC_DE` call (`:542`) on the Mac/iOS compute path once the variant is warm (`InteractiveSession.swift:466-480`). The VFT path survives only as a warm-up transient and for external DEs. The DEs are native straight-line MSL, **not** an op-interpreter — the "interpreter" is only the user-warp `applyPointOps`/`applyDistanceOps`, orthogonal to DE dispatch.
- **Warp interpreter is count-gated.** For an empty warp stack `U.meta.x == ops.count == 0`, so the `for` loops execute **zero** times (`InteractiveSession.swift:418`, `RaymarchCore.metal:75/279`) — no per-step device op read or switch. The 1-element dummy buffer is only to satisfy Metal's non-null binding. (Item 9 remains a minor occupancy win, not the "always-on device loop" the audit first claimed.)
- **CPU precompute of transcendentals (`absScalePow`, inverse radii) buys nothing here.** Current `de_mandelbox` returns `length(z)/fabs(dr)` (`:357`) — a different, transcendental-free formulation with no `absScalePow` term. `mR2`/`fR2` (`:339-340`) are already loop-invariant `const` values the compiler hoists. The real Mandelbulb win is **fast-math intrinsics** (`fast::`/`powr`), a *separate* dimension.
- **MetalFX temporal is near-parity and on the hot path** (`InteractiveSession.swift:451-538`, THRESH_AUX variant, Halton(2,3) jitter). The "missing output/3 up-clamp" cannot fire because the Mac floor `minRenderScale=0.35 > 1/3` (`QualityGovernor.swift:43`, `SessionCore.swift:151`). Only gap is a spatial fallback for MetalFX-unsupported devices — coverage, not perf.
- **Governor tuning is a non-issue.** AIMD (`QualityGovernor.swift:57-76`) is resolution-only, armed (`ThresholdApp.swift:62-67`), fed real command-buffer timings — comparable to legacy's cooldown controller. A resolution governor cannot change per-pixel ALU.
- **Frames-in-flight 3 vs 2 is latency, not ms.** Depth-3 is deliberate (matches `maximumDrawableCount`, `InteractiveSession.swift:317-326`). The "staler governor sample" claim is false — `FrameStatsSlot` is a single-slot latest-value store. Don't change it to chase the ALU gap.
- **FrameUniforms sizing is correct.** 64B (`ThreshFrameUniforms`) and 48B (`ThreshWarpOp`) are static-asserted (`ThresholdShaderABI.h:222-223`); the legacy 272B occupancy collapse cannot recur. No sizing work warranted.
- **Cone-march epsilon:** the distance-proportional cone epsilon is already ported (`hitEps = epsBase * t`, `RaymarchCore.metal:709`). Legacy's `coneMarchScale` defaults **off** and its `(1-quality)*0.003` slack is zero in the fast baseline (legacy hardcodes `quality=1.0`), so neither is part of the measured 3x. The governor's threshold-loosening lever was a **deliberate** measured rejection (`QualityGovernor.swift:8-12`).
- **Resolution-aware epsilon** is an **unshipped backlog idea in legacy too** (`PERF_PUSH.md` item #5) — not a fast-vs-slow gap. Low priority, Mandelbox-only, unmeasured even in legacy.
- **Shadows / separate color-iteration budget:** current has **no shadow march at all** — it does *less* work than legacy on this axis. This is a forward-looking guardrail (if shadows are added later, use a stripped geometry-only DE at reduced iters), not a current cost. `THRESH_SLOT_SHADOW_SOFT` is a dead, CPU-written-but-GPU-unread slot.

## 5. Sequencing

The kernel is ALU/register-bound at ~70% ALU, and the specialization compile seam is the enabler for the biggest wins. Order:

1. **Item 1 (bake iterations → unroll)** *first* — it is the single largest ALU/register lever, small effort, and its function-constant seam is a **prerequisite** for Items 2 and 5. Measure on Stress-test before touching anything else. This is the pivot; everything cheaper hangs off it.
2. **Item 2 (reduced secondary iters)** *immediately after* — reuses Item 1's seam, pure ALU removal on every hit pixel, small effort. Re-baseline goldens.
3. **Item 5 (bake maxSteps)** — trivial free rider on the same seam; bundle into the same measurement session but as its **own** before/after (it's a micro-opt, don't let it hide Item 1's signal).
4. **Item 3 (over-relaxation)** — highest remaining raw impact after the cheap wins are banked. Start by un-pessimizing `stepSafety` (guarded 0.9→~1.0) and measure, *then* layer omega + the overstep-retreat guard + per-fractal caps (via the specialization seam Item 1 established).
5. **Item 4 (bounding-sphere early-out)** — independent of the above; medium effort, gated on `radius>0` so it's a safe additive toggle.
6. **Item 9 (`THRESH_HAS_WARP` gate)** — small, low-risk occupancy win once the specialization key already carries multiple axes; cheap to fold in.
7. **Item 6 (half shade tail)** — low-risk half of the precision work; defer half-DE-march to a later, carefully-thresholded pass.
8. **Item 8 (distance-LOD falloff)** and **Item 11 (cached/Jacobian normals)** — medium/large, scene-dependent; do after the cheap ALU wins are measured so their marginal contribution is visible.
9. **Item 7 (coarse prepass)** — large; port the frame-local coarse/tile prepass before any temporal warm-start.
10. **Item 10 (raster specialization)** — needed for visionOS device perf but off the Mac 3x critical path; sequence when visionOS is the target.
11. **Items 12–14** last: 12/13 are launch-latency (not steady-state ms); 14 is a CPU-hitch smoothness fix orthogonal to the ALU gap.

**Key dependency:** Item 1's function-constant + cache-key infrastructure is a prerequisite for Items 2, 5, and the per-DE omega cap in Item 3. Build it once, correctly, and the three cheapest high-confidence ALU wins all land on top of it.