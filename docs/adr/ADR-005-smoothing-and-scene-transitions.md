# ADR-005: Change smoothing & scene transitions (LERP feel + tweening)

**Status:** Accepted
**Date:** 2026-07-04
**Deciders:** Jean
**Relates to:** ARCHITECTURE.md §3 (modulation), plan §3.3 (smoothing), §8.3 (camera),
§5.5 (palette); ADR-003 (lanes); the original app's `RenderSettings.smoothDamp`
and "Same Scene Transition Time".

## Context

The original Threshold app had two smoothing behaviors the rebuild had dropped:

1. **A per-frame LERP on every parameter change** — a critically-damped
   `smoothDamp` (Game Programming Gems 4 §1.10, ~0.35 s) so any geometry/color/
   camera change *eased* into place instead of snapping. Geometry, position,
   rotation (SLERP), and log-space zoom all rode it; iterations/enums/presets
   snapped.
2. **Scene/preset "tweening"** — loading a scene snapshotted the current values
   and eased them toward the new scene's over a configurable "Same Scene
   Transition Time" (default 0.5 s), then snapped on convergence.

The rebuild's `ModulationEngine` already implements the exact exponential the
original approximated — `alpha = 1 - exp(-dt/tau)` per frame, frame-rate
independent — but `Smoothing.default` set the **scene** and **user** lanes to
`tau = 0` (instant). So only gesture (0.15 s) and music (0.08 s) eased; slider
edits and scene applies snapped. Both headline behaviors were latent, one
constant away.

## Decision

Turn the existing per-lane smoother on for continuous content, and add a
duration-scoped **scene transition** on top of it. No new smoothing math — the
engine's `1 - exp(-dt/tau)` is the whole mechanism; everything below is *which
tau, when* plus two pieces of scene content (camera, palette) that live outside
the lane table and tween in `SessionCore` on the same clock.

### 1. Continuous change smoothing (the global LERP feel)

- A `Smoothing.continuous` preset (**user 0.2 s**, gesture 0.15 s, music 0.08 s)
  is the exponential match for the original's 0.35 s critically-damped feel.
  Every continuous content param — DE shape params, camera rig, color grading,
  bubble radius/blend — declares it. Slider drags now *follow* smoothly.
- **The scene lane stays `tau = 0`.** A plain scene apply still snaps, so the
  headless harness and golden images are byte-identical by default (Invariant
  10/11 preserved). Tweening is opt-in per apply (§2).
- **Bool and enum KINDS are forced instant on every lane**, regardless of their
  spec — a fractional enum index or a half-set toggle is a garbage frame. The
  engine zeroes their tau at registration (`isSmoothableKind`).
- **Graceful lane release**: a momentary gesture binding whose signal goes
  stale, instead of clearing instantly, *glides* its lane value to the
  composition neutral at the lane's tau, then clears (`releaseLane`) — a hand
  leaving tracking eases out rather than snapping. Degrades to an instant clear
  for tau-0 (test/discrete) specs, so it is transparent there.
- **Slider commit/discard stay instant.** The live drag already eased the
  resolved value to the target via the user lane; baking that into the scene
  lane and clearing user keeps the value exactly where it is. Commit/discard are
  one-shot commands and must not depend on later frames landing to finish a
  glide (a throttled or idle render loop would strand a committed edit
  mid-glide). Continuous FOLLOW happens *during* the drag; the endpoints snap.

### 2. Scene transitions (tweening between scenes)

- `SceneCommand.applyScene(_, transition:)` carries an optional
  `SceneTransition(duration:)`. `nil` snaps (startup/harness). UI-triggered
  loads default to 0.5 s (the legacy "Same Scene Transition Time").
- **Continuous scene params ease.** `beginSceneTransition(duration:)` opens a
  window during which tweenable scene-lane slots smooth at **τ = duration/4**
  (≈ 98 % of the way by the deadline) *instead of* their spec tau — every tweened
  param moves in lockstep at the transition rate, coordinated, not each at its
  own feel. When the window closes they land **exactly** (`current = target`),
  so the tail is a negligible snap, never a visible pop.
- **The window is content time** (AppClock): pausing freezes a transition
  mid-flight, exactly like every other smoothed value.
- **Discrete, quality, and structural content snap.** Bool/enum kinds and
  params flagged `Capabilities.snapOnSceneTransition` (the march-quality
  four — iterations, maxSteps, step-safety, maxDist; the bubble-shape enum)
  jump immediately: sweeping an iteration count pops the fractal frame by frame.
  The warp-stack structure, the DE swap, and the zoom octave also snap — the
  original tweened none of these.
- **Authoritative clears ramp then release.** A param the incoming scene omits
  ramps its scene lane to the catalog default over the window, then clears — a
  snap-to-default next to easing neighbors reads as a glitch.
- **Camera & palette tween in `SessionCore`**, on the same clock and the same
  exponential, because they are scene content that does not live in the lane
  table:
  - Camera: position + fov lerp, orientation **SLERP** along the shortest arc
    (negate one quaternion when `dot < 0`). The authored `camera` stays the save
    target; a `cameraTween` carries the displayed pose and, when the window
    closes, is discarded so `displayedCamera` falls back to the authored pose —
    an exact landing with no extra state.
  - Palette: `Palette.crossfade(from:to:weight:)` mixes the two gradients at the
    union of their stops; `displayedPalette` falls back to the authored palette
    on close. Same exact-landing-by-fallback pattern as the camera.
  - An octave rebase mid-transition scales the tween's displayed camera by the
    same power of two as the authored camera, so the glide stays in one world.

### 3. Zoom speed stays instant (not continuous)

`scale.zoomSpeed` is an integrator *rate*. The phase integrator already turns a
stepped rate into continuous motion (∫ of a step is a ramp — position never
jumps), so smoothing the rate would double-smooth and desync the deterministic
integration the harness relies on. It keeps `Smoothing.instant`.

## Options Considered

### A: Turn on the existing lane smoother + a transition window (chosen)
**Pros:** one mechanism (`1 - exp(-dt/tau)`) for live edits, gesture decay,
music decay, and scene transitions; no new state machine; the snap path stays
byte-identical so goldens are untouched; per-param opt-out via a capability
flag. **Cons:** camera/palette need a small parallel tween in `SessionCore`
(they are not lane values); two "which tau" special cases (transition window,
forced-instant kinds).

### B: Port the original's critically-damped `smoothDamp` verbatim
**Cons:** a second smoothing law alongside the engine's exponential (two feels
to reconcile), per-value velocity state, a `maxSpeed` clamp, and a convergence-
snap heuristic — all of which the exponential + exact-landing already cover.
Rejected: reintroduces the parallel-state pattern the lane model exists to
avoid.

### C: Model a transition as a keyframe animation on the animation lane
**Cons:** the animation lane is owned by the clip player; a transition would
collide with a playing clip, and "stop zeroes the lane" would kill a transition.
The transition is a property of *how the scene lane is applied*, not a clip.
Rejected as a lane collision (same class ADR-003 rejected for the governor).

## Trade-off Analysis

- **τ = duration/4** is the knob that trades landing-cleanliness against motion:
  at the deadline the exponential has run 4 time constants (~98 %), so the exact
  landing snaps ~2 %. Smaller divisors (say /2) leave a bigger pop; larger (/6)
  make the motion feel like it stops early. /4 matches the original's "reaches
  ~95 % settle in ~1 s for a 1 s transition."
- **Forcing continuous-during-transition to override the spec tau in both
  directions** (not `max(specTau, τ)`) is deliberate: a coordinated transition
  wants every tweened param to arrive together, governed by the duration, not by
  each param's live-edit responsiveness.
- **Snap vs. tween is per-param data** (`snapOnSceneTransition` + the kind
  check), not hard-coded — the same "policy is declaration" discipline as
  persistence and composition.

## Consequences

- Easier: any new continuous param gets the LERP feel by declaring
  `.continuous`; any param that should snap in transitions gets one flag; scenes
  cross-fade for free.
- Harder: camera/palette landing lives in `SessionCore`, not the engine — two
  places implement "ease then land," kept in lockstep by construction (both use
  the same τ and the nil-fallback exact landing).
- Tests that asserted a single write → single resolve now advance to
  convergence for continuous params (the smoothing is the point); the snap path
  (`transition: nil`) still asserts one-frame exactness.

## Action Items

1. [x] `Smoothing.continuous`; force bool/enum kinds instant at registration.
2. [x] `beginSceneTransition` / `scheduleSceneClear`; τ = duration/4; exact
   landing; `snapOnSceneTransition` capability.
3. [x] `releaseLane` graceful decay for momentary gesture release.
4. [x] `SessionCore` camera SLERP + palette crossfade tweens on the AppClock;
   octave-rebase interaction.
5. [x] Keep `transition: nil` on the harness/startup path (goldens byte-identical).
