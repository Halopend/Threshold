# Vision Pro controls and scene loading review

2026-10-15. Scope: current working tree, shared scene submission, hand input,
and desktop/visionOS app wiring. This is a focused correctness review, not a
headset performance benchmark or a repository-wide audit.

## Implemented in this iteration

- Shared `SceneLoadCoordinator` replaces duplicated asynchronous scene loading
  in the macOS/iPadOS and visionOS app models. Selection order is recorded before
  compilation begins. Stale completions and stale errors cannot replace a newer
  scene; built-in selections invalidate pending external preparations too.
- Prepared scenes use one existing transactional render command. Editors and
  platform side effects update only after the mailbox accepts that command.
  Acceptance is not a render acknowledgement.
- Lane messages can explicitly clear a single slot. Clear and write messages
  share the same latest-value ordering, including replace-composition parameters
  where writing zero would not mean releasing ownership.
- Hand input releases momentary targets, clears its published offsets on reset,
  and reanchors when binding tables change. Rebinding intentionally resets hand
  adjustments rather than transferring an old displacement to a new parameter.
- The Vision Pro control window exposes Pause Gestures and Reset Hand Adjustments.
  World grab pauses without losing the current view; reset remains paused.
- Gesture editors no longer offer unimplemented core actions. Existing serialized
  action bindings are preserved and can be cleared. World Grab instructions now
  describe the actual one-hand move/turn and two-hand scale behavior.

## Follow-up (2026-10-15, later session): gesture-lane arbitration contract

Priority 1 below is now implemented in core:

- `GestureSource.arbitrationRank` defines a total, build-stable arbitration
  order (family-precision ▷ hand ▷ finger). `GestureLaneResolver.resolve`
  iterates sources in that order — never dictionary order — so its output is a
  pure function of the frame's drive set.
- Per touched (lane, slot) the resolver emits EXACTLY ONE write, composed by
  the target spec's composition: additive offsets SUM, multiplicative factors
  MULTIPLY (`exp(drive·gain·logReach)` toward the range edge — consistent with
  how multiplicative lane values are consumed and with the camera dolly's
  `exp(log-dolly)` hand path), and REPLACE targets are owned by the lowest-rank
  (most precise) armed source, writing `default + drive·gain·span` absolutely.
- Discrete `.bool`/`.enumeration` targets produce no write (the editor never
  offered them; a drag has no meaning for a toggle).
- Availability became a declaration the catalog owns: `DERegistry.registerParams`
  and `SessionCore.setExternal` now declare `.gestureBindable` on DE params
  (the legacy gesture vocabulary), and the editor derives its list through
  `BindableParams.gestureTargets` — engine/quality params no longer surface as
  gesture targets despite the kind-based filter that previously exposed them.
- Tests: full suite 658 tests / 122 suites green (`swift test --build-system
  native --disable-sandbox`). New coverage: total-order arbitration, additive
  sum, multiplicative log-space mapping (up/down/one-sided/no-room), replace
  ownership, factor composition, discrete-kind skip, capability-filtered
  targets, DE capability declarations.

## Follow-up 2 (2026-10-15, same session): incorrect/improvement review

A focused correctness review of the changed code and adjacent consumers found:

- **Music Routes picker had the same availability drift.** `BindTarget.all`
  offered every continuous param component; it now filters on the catalog's
  `.musicBindable` declaration. The catalog's own design comments ("Color
  Offset pulsing to the beat", "intensity/strength scalars are music/animation
  bindable") were honored by DECLARING `.musicBindable, .animatable` on the
  color grading lanes (saturation, contrast, vibrance, brightness, gamma,
  tonemap, gradient offset), bubble blend, and the atmosphere glow/bloom/fog
  intensity scalars. Existing bindings still apply (BindingEngine never gated
  on capabilities); only creating NEW routes is declared-gated now.
- **Replace-lane semantics documented in the resolver**: a live gesture on a
  replace target anchors at the param DEFAULT (pure resolver cannot see the
  composed base), and lane order still applies — a live MUSIC write overrides
  a gesture on replace targets (music composes after gesture), while the
  gesture overrides scene/animation/system/user. No shipped layout currently
  binds gestures to replace params, so this is policy for the future.
- **`GestureGate` and `WorldGrab` verified clean** (hysteresis/dwell/grace/
  cooldown state machine; grab pivot algebra checked against `contentPoint`,
  ratio-based two-hand scale, latch + commit bookkeeping, NaN ingress guards).
- **Minor / deferred findings** (intentionally not changed):
  - `GestureBindingStore.pruneOrphans(forFractal:keeping:)` is dead code whose
    contract would over-prune GLOBAL scope against the passed key set; the
    scope caveat is now documented on the API itself. If wired up later it
    should prune each scope against that scope's own vocabulary
    (global = static catalog; per-fractal = static + dynamic).
  - The gesture editor can no longer display/clear persisted bindings that
    target params whose capability declaration regressed (engine params were
    briefly offered pre-release). Pre-release risk only; a store-load pruning
    migration would close it if it ever reproduces.
  - Default `SignalMapping` output range is 0…1 whatever the target's
    composition: on multiplicative targets (dolly) that's attenuation-only,
    on replace targets (saturation 0…2) half the range. The mapping is
    editable per binding; a nicer default could seed output bounds from the
    target spec (composition-aware) in a later UI pass.
  - Camera-tick writes (orbit/dolly accumulators) and resolver writes share
    gesture-lane slots when a camera param is ALSO explicitly bound; the
    mailbox's latest-write-per-frame wins deterministically (resolver runs
    after the hand ticks), but a documented arbitration policy would be
    better than implicit order. (The built-in index-pinch camera gesture
    cannot collide: an assignable binding on `.tapThumb(.index)` suppresses
    the camera tick outright.)
- **Detection arms verified** (`HandGestureEngine`): fist/tapPalm pose
  exclusivity, tapThumb winner-takes-all with lead gap + lock, incremental
  re-anchoring (suspension-safe, zero first post-gap step), swipe gating with
  the no-pinch-readings vacuous guard, and held-latched tapThumb accumulation
  all consistent with the resolver's drive contract.
- **`SceneLoadCoordinator` verified**: generation-checked completions are
  check-and-submit atomic on the main actor; built-in scenes select their
  descriptor inside `apply(scene:)`, and `ExternalDELoader.load` never returns
  a silent nil (returns a program or throws), so the nil-program path is test
  injection only.
- Validation: full suite 660 tests / 122 suites green; the visionOS app target
  rebuilt clean (`xcodebuild build -destination generic/platform=visionOS`,
  unsigned) after the capability and picker changes.

## Remaining priorities

1. **Headset scene preparation.** External DE raster/view-compute variants are
   still constructed lazily. Prepare the required headset variants before scene
   activation, with a surfaced error and the prior scene retained on failure.
   Measure first-load latency separately from steady-state frame time.
2. **Gesture interaction design.** The current constellation editor remains a
   dense assignment surface. A subsequent UI pass should distinguish navigation,
   parameter editing, and paused interaction; expose meaningful sensitivity and
   arming feedback; and validate accidental UI-pinch activation on device.
   Raw hand signals remain available to explicitly authored signal bindings even
   when skeleton gesture controls are paused.
3. **Render acknowledgements and closed immersive space.** Scene submission can
   succeed while no compositor loop is consuming commands. Make pending/applied
   state visible and audit all optimistic UI setters for rejection handling.
4. **Platform growth.** Keep scene selection and gesture state machines shared;
   keep ARKit and Compositor Services in adapters. This iteration adds no new
   rendering abstraction and makes no non-Apple backend compatibility claim.

## Validation

86 focused Swift tests pass, covering scene ordering and rejection, mirror state,
lane mailboxes, gesture bindings, synthetic hand input, and world grab. macOS and
visionOS app builds are checked separately without signing. Hardware-dependent
scene fidelity, performance, thermals, and gesture feel require a Vision Pro run;
no frame-rate improvement is claimed by this change.
