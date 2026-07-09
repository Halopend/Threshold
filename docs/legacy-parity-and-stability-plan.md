# Legacy parity and stability plan

Status: draft, 2026-07-09

## 1. Objective

Make the rebuild the simplest and fastest way to run the largest practical subset of
the original MetalRaymarch scene library, without importing the original app's shared
state, duplicated render paths, or parameter wiring.

Success means:

- legacy content either renders faithfully or reports a precise unsupported feature;
- one parameter catalog, modulation engine, shader IR, and render core remain the only
  paths into a frame;
- crashes and user-visible hangs are reproducible, attributable, and release-blocking;
- performance work is measured against named scenes and target frame budgets.

## 2. Current evidence

### Compatibility foundation already present

- The rebuild contains 43 legacy scenes, 13 animations, and 18 binding maps.
- `SceneCodec` has versioned migration and preserves unknown keys instead of deleting
  data that may become supported later.
- The migration already covers core camera conversion, common engine and color values,
  Mandelbox variants, Kleinian values, gradients, the legacy warp stack, safety bubble,
  custom embedded Metal formulas, animations, and music maps.
- The shader IR contains all 17 legacy space-warp kinds, sphere projection, and separate
  hand-attract, forearm-carve, and bounding operations.
- Seven built-in distance estimators are native in the rebuild. Legacy custom formulas
  use the external-DE adapter; the corpus currently includes 15 custom scenes.

The remaining question is visual and behavioral fidelity, not basic JSON readability.
The current corpus test proves that files decode, apply, and round-trip, but it does not
prove that every preserved legacy field affects the rendered image.

### Crash evidence and attribution

The only matching macOS diagnostic report found during this audit is
`Threshold-2026-07-09-122549.ips`. It is an `EXC_CRASH/SIGABRT` inside the
MetalFX/MPSGraph optimization stack while building a temporal scaler. The triggered
stack reaches `ANEPropertiesRegistry::registerProperties` and aborts while locking an
internal C++ mutex.

That report references `MacTemporalUpscaler.swift`, so it came from the original
project, not the rebuild's `TemporalUpscaler.swift`. It must not be counted as proof of
a rebuild crash. It is still directly relevant because the rebuild's temporal scaler
was ported from that implementation and has the same size-keyed construction model.

Apple recommends creating MetalFX effects at launch or when display resolution changes
and reusing them. MetalFX also defaults to compiling the final scaler internally in the
background unless `requiresSynchronousInitialization` is enabled. A matching Apple
Developer Forums report describes repeated temporal-scaler construction failing inside
MPSGraph. This supports treating scaler lifetime and construction as the first shared
risk to eliminate, while collecting a diagnostic from the rebuild itself.

References:

- [MetalFX overview](https://developer.apple.com/documentation/metalfx)
- [Temporal scaler initialization behavior](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/requiressynchronousinitialization)
- [Temporal scaler descriptor and device support](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor)
- [Metal command-buffer error details](https://developer.apple.com/documentation/metal/mtlcommandbuffer/error)
- [Command-buffer debugging](https://developer.apple.com/documentation/metal/command-buffer-debugging)
- [MetricKit diagnostics](https://developer.apple.com/documentation/metrickit)
- [MetalFX developer reports](https://developer.apple.com/forums/tags/metalfx)

### Rebuild lockup risks visible in source

1. `InteractiveSession.stop()` can wait five seconds for startup and another five
   seconds for shutdown. Its own comments say it usually runs on the main thread. The
   waits are bounded, but a five-to-ten-second UI freeze is still a lockup to a user.
2. MetalFX construction is serialized on a private queue, which protects the Swift
   cooperative pool, but the implementation can still construct multiple size-keyed
   scaler instances over time and leaves MetalFX's internal asynchronous compilation
   enabled.
3. Compute, raster, and view specialization still use `Task.detached`. Rapid scene,
   formula, quality, or display changes can produce overlapping compiler work and can
   starve unrelated cooperative tasks even when each cache deduplicates identical keys.
4. The frame loop has a useful one-second in-flight GPU timeout, but command-buffer
   errors are not yet a complete crash record with encoder execution status, scene
   identity, feature state, and pipeline identity.
5. The hang watchdog detects main-thread latency but cannot identify the blocked stack
   or distinguish main-thread work, render-thread teardown, compiler pressure, and a GPU
   stall on its own.

## 3. Working rules

1. Do not copy legacy feature classes into the rebuild. Port behavior into the catalog,
   signal/binding model, shader IR, or a deliberately separate renderer.
2. A feature cannot add a direct UI-to-render mutation path. Structural changes use the
   command mailbox; continuous values use lanes; output leaves through snapshots.
3. A legacy field is never silently ignored. It is classified as exact, approximate,
   preserved/no-op, or unsupported with a reason.
4. Every renderer feature has a headless path. UI-only proof is insufficient.
5. Every expensive or driver-sensitive feature has a runtime kill switch until its soak
   gate passes.
6. Performance changes land one at a time with named corpus scenes and before/after GPU
   measurements.

## 4. Phase 0: establish attributable stability

Duration target: one focused iteration.

### Build identity and breadcrumbs

- Give the original and rebuild distinct bundle identifiers, process display names, and
  log prefixes so macOS reports cannot be misattributed.
- Emit build identity, scene filename/hash, DE key, external-DE hash, output/input size,
  render scale, active warp count, MetalFX state, specialization key, and last completed
  frame number at session start and whenever one of them changes.
- Persist a small rolling breadcrumb file and mark whether the prior session exited
  cleanly. Keep it bounded and avoid per-frame filesystem writes.
- Add MetricKit diagnostic ingestion for crash and hang call-stack reports on supported
  macOS, iOS, and visionOS versions. Use the current `DiagnosticReport` API where the
  deployment target provides it, with the older payload API only as compatibility code.

### Isolation switches

Add persistent developer switches for:

- MetalFX temporal upscaling;
- compute/raster specialization;
- external DE compilation;
- animation playback;
- audio and hand inputs;
- scene transitions.

The switches are diagnostic boundaries, not permanent user-facing settings.

### Reproduction matrix

Run the same short sequence with each switch on and off:

1. launch and open the default scene;
2. switch repeatedly across built-in and custom scenes;
3. drag render quality continuously;
4. resize the window continuously;
5. start and stop animation and audio inputs;
6. close and reopen the render surface;
7. sleep/wake or background/foreground where the platform supports it.

Record crash signature, longest main-thread stall, longest frame stall, and the last
breadcrumb. Do not port more features until every observed failure belongs to a named
bucket.

### Exit gate

- Every crash report identifies original versus rebuild unambiguously.
- Every hang over 250 ms leaves a timestamped event; every hang over two seconds is
  paired with a system or MetricKit stack capture.
- A 30-minute developer soak produces no unexplained crash and no unexplained stall over
  two seconds.

## 5. Phase 1: remove likely crash and lockup causes

### 5.1 MetalFX lifetime

1. Replace the per-input-size scaler pool with the smallest viable number of long-lived
   scalers, ideally one per output/display configuration.
2. Evaluate MetalFX dynamic-input-content support so render-scale changes update content
   dimensions without rebuilding the scaler.
3. Set `requiresSynchronousInitialization = true` on the dedicated builder queue. This
   makes the expensive compilation explicit and serialized instead of allowing the
   framework to start additional hidden background compilation.
4. Debounce output-size changes. Do not build for transient resize dimensions.
5. Keep full-resolution direct rendering as the guaranteed fallback. Consider a spatial
   scaler fallback only after the temporal path is stable.
6. Add a session-level circuit breaker: after one scaler build failure or excessive
   build time, disable temporal scaling for the rest of that session rather than retrying
   indefinitely.

Acceptance: repeated render-quality drags and window resizes create a bounded number of
scalers, never overlap construction, and survive a 60-minute soak with Metal diagnostics
both disabled and enabled.

### 5.2 Bounded compilation scheduler

- Replace `Task.detached` pipeline builds with one dedicated, bounded scheduler shared by
  compute, raster, and view specialization.
- Coalesce latest-wins requests and cap concurrent Metal compiler work to one until data
  proves a higher limit safe.
- Compile built-in shaders into a shipped metallib and use a binary archive or pipeline
  dataset for known variants. Keep runtime source compilation only for external DEs.
- Give external-DE compilation its own timeout, cancellation-by-obsolescence, and
  session circuit breaker. A stale scene must never publish its completed pipeline.

Acceptance: a scene-switch storm cannot occupy the Swift cooperative pool, and UI work,
export completion, and diagnostics continue while pipelines compile.

### 5.3 Nonblocking session teardown

- Move render-thread joining off the main actor. The main thread should request stop,
  detach the presentation surface, and remain responsive while a lifecycle coordinator
  observes completion.
- Preserve bounded timeouts, but report a leaked session as a fault rather than blocking
  the UI for five or ten seconds.
- Make display-link invalidation, in-flight command buffers, capture/export work, and
  scaler/pipeline jobs explicit members of the shutdown state machine.

Acceptance: closing/reopening a window or changing render surfaces never blocks the main
thread longer than one display frame.

### 5.4 GPU failure record

- In diagnostic builds, request command-buffer encoder execution status and include the
  failing encoder information from `MTLCommandBuffer.error.userInfo`.
- Label every command buffer and encoder with frame, scene, pass, DE, and specialization
  identity.
- Keep the existing one-second in-flight timeout, but suppress repeated logs and trip a
  fallback/circuit breaker after a small consecutive-stall threshold.

## 6. Phase 2: build an executable compatibility scorecard

Create one generated row per legacy scene with these columns:

| Column | Meaning |
|---|---|
| Decode/apply | File migrates without process termination |
| DE | Native exact, external exact, approximate, or unsupported |
| Formula params | Count mapped versus preserved/no-op |
| Camera/zoom | Pose and scale semantics match |
| Warps | Kind, order, flags, and payload match |
| Palette/grading | Stops, mapping, and grade match |
| Effects | Static and dynamic effects match |
| Animation | Tracks, loop, phase, and interpolation match |
| Bindings | Music/gesture targets and response curves match |
| Golden | Perceptual image comparison status |
| Performance | CPU/GPU frame time at the reference setup |

### Golden procedure

- Render the original and rebuild at a fixed resolution, camera, time, and deterministic
  math mode.
- Disable live audio, hand, and device-local state unless the test specifically targets
  them.
- Compare exact pixels where semantics are intended to be exact. Otherwise use a
  perceptual metric plus a reviewed difference image.
- Store the original image, rebuild image, diff, render metadata, and accepted tolerance.
- Select a small smoke set covering Mandelbox, Mandelbulb, projected Mandelbox,
  Kleinian, a multi-warp scene, a custom embedded formula, animation, and music mapping.
  Run the full 43-scene matrix less frequently.

This scorecard becomes the source of truth. Existing migration tests remain necessary,
but “round-trips” and “renders faithfully” are separate gates.

## 7. Feature-port order

### Wave A: maximize scene fidelity inside the existing core

1. Complete formula-param migration for every legacy `fractalType` represented in the
   corpus. Prefer a native DE when it is broadly reused; use the external-DE shim for
   one-off custom formulas.
2. Close visual gaps revealed by the scorecard in camera/zoom, gradients, lighting,
   atmosphere, dynamic color, safety/bounding behavior, and scene transitions.
3. Complete per-kind warp payload metadata and editors. Strength-only UI is not enough
   to author or repair migrated stacks.
4. Make animation and binding migrations target every newly supported catalog param.

Wave A is complete when all 43 files have an explicit status and the high-value smoke
set is visually accepted.

### Wave B: interaction and authoring

1. Finish visionOS hand diagnostics and default hand profiles.
2. Port relative gestures, two-hand guardrails, per-parameter sensitivity, menu-toggle
   gestures, and per-finger tap behavior through the generalized input resolver.
3. Route macOS mouse/keyboard and iPad touch through the same input/action seam.
4. Add scene thumbnails, categories, edited badges, overwrite protection, and complete
   export/share flows without changing the render architecture.

### Wave C: high-value independent subsystems

Port these as clients of the core, not fields added to `SessionCore`:

1. Quick Look rendering through the headless/offscreen renderer.
2. Apple Music and system-audio acquisition feeding the existing audio signals.
3. Environment/room SDF effects as a bounded resource plus a declared warp/render
   feature, with synthetic headless fixtures.
4. Core Motion tilt as another normalized input source.
5. Optional cloud scene storage behind the scene-library source protocol.

### Wave D: deliberately separate or low-priority features

- Buddhabrot is an accumulation renderer, not a distance estimator. Keep it as an
  alternate renderer sharing palettes, export, and library infrastructure; do not bend
  the raymarch core around it.
- SharePlay/collaboration follows only after scene deltas and command semantics are
  stable.
- MIDI follows after the generalized input source model is stable.

## 8. Performance sequence

Performance work follows correctness and uses the corpus scorecard. The existing perf
audit supports this order:

1. Bake DE iteration counts into specialized variants, then reduce secondary normal/AO
   iterations with explicit image re-baselining.
2. Add guarded over-relaxed sphere tracing with per-DE caps and retreat on overshoot.
3. Add conservative per-scene bounding-sphere entry/early-out.
4. Move the shading tail to half precision where image comparisons pass.
5. Replace per-frame parameter/op buffer allocation with an in-flight ring.
6. Ship metallibs and archive known pipelines to reduce launch and scene-switch hitches.
7. Consider distance LOD, cached normals, and a coarse prepass only after the cheaper
   changes are measured.

For each item record:

- target device and OS;
- scene, resolution, and render mode;
- median and p95 CPU/GPU frame time;
- compiler/pipeline warm state;
- visual diff result;
- memory and thermal notes.

Frame budgets are 11.1 ms for 90 Hz and 16.7 ms for 60 Hz. Quality governors may reduce
resolution, but they must not conceal a regression in per-pixel cost.

## 9. Definition of done for any ported feature

A feature is complete only when it has:

- catalog/IR/signal ownership with no second state model;
- migration and unknown-key policy;
- deterministic CPU or pure-logic tests where applicable;
- Metal implementation shared by live and headless paths;
- UI generated from metadata or a narrowly scoped custom editor;
- at least one corpus or synthetic golden;
- a measured performance budget;
- diagnostics and a temporary kill switch for driver-sensitive work;
- macOS, iPadOS, and visionOS behavior explicitly marked supported, fallback, or not
  applicable.

## 10. Milestones

### M0: attributable baseline

Distinct product identity, MetricKit/breadcrumb capture, isolation switches, and the
reproduction matrix.

### M1: stable renderer

Long-lived MetalFX lifecycle, bounded compiler scheduler, nonblocking teardown, and GPU
error records. Gate: 60-minute stress soak with no crash and no main-thread stall over
250 ms outside known launch/setup intervals.

### M2: corpus truth

Generated 43-scene scorecard and reviewed smoke-set goldens. No scene is merely “it
decoded”; every scene has a visual-support classification.

### M3: high-coverage parity

Wave A complete, with compatibility percentage reported by exact, approximate,
preserved/no-op, and unsupported scene features.

### M4: product features

Wave B and selected Wave C features, chosen by user value and scene coverage rather than
legacy implementation size.

### M5: performance target

Measured optimization sequence complete on the target Mac and Vision Pro hardware, with
accepted image comparisons and stable 60/90 Hz budgets on the nominated smoke scenes.
