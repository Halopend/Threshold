# Threshold Rebuild Architecture

A ground-up architecture for the Threshold fractal renderer, designed so that the six
headline features — hand interactivity, gestures, animations, music reactivity, external
scene loading with external distance estimators, and stackable space transformations —
fall out of three load-bearing systems instead of being wired individually:

1. **ParameterCatalog** — every tunable value declared exactly once.
2. **Modulation Engine** — layered per-frame value resolution; writers never mutate shared state.
3. **Shader IR** — the distance estimator and transform stack are data with a stable GPU ABI.

Everything else (UI, persistence, music, hands, animation) is a *derivation* or a *client*
of those three.

---

## 0. Goals and non-goals

**Goals**
- Adding a new parameter = one declaration. UI, persistence, music/gesture/animation
  binding, and scene round-trip come for free.
- Adding a new input source (a new gesture, a new audio feature, a new hardware input)
  touches only the input layer — no per-parameter wiring.
- Adding a new transform or an externally-authored DE requires no changes to the render
  core, the persistence layer, or the UI framework.
- One raymarch core shared by every platform path; a feature cannot silently exist on
  only one path.
- Headless, deterministic rendering from day one.

**Non-goals**
- Cross-platform beyond Apple (Metal-only is fine; no abstraction layer over the GPU API).
- Multi-scene compositing, networking/multiplayer, non-SDF geometry.

**Platforms**: macOS, iPadOS, visionOS (no iPhone).

---

## 1. System overview

```
┌────────────────────────────────────────────────────────────────────┐
│                            INPUT SOURCES                           │
│  HandTracker  GestureRecognizers  Crown/Orbit  AudioAnalyzer  UI   │
│        │             │                │             │         │    │
│        ▼             ▼                ▼             ▼         │    │
│  ┌──────────────────────────────────────────────────┐        │    │
│  │              SIGNAL BUS  (named float/float3      │        │    │
│  │              signals + confidence, per frame)     │        │    │
│  └──────────────────────┬───────────────────────────┘        │    │
│                         ▼                                    ▼    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │   BINDING LAYER   signal → (paramID, lane, mapping curve)    │ │
│  └──────────────────────┬───────────────────────────────────────┘ │
│                         ▼                                          │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │   MODULATION ENGINE   per-param lane stack, resolved once    │ │
│  │   per frame:  scene ▷ animation ▷ user ▷ gesture ▷ music     │ │
│  └──────────────────────┬───────────────────────────────────────┘ │
│                         ▼                                          │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │   FRAME SNAPSHOT   immutable resolved values + transform     │ │
│  │   op buffer + DE handle  →  encoded into GPU argument buffer │ │
│  └──────────────────────┬───────────────────────────────────────┘ │
│                         ▼                                          │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │   RENDER CORE   one MSL raymarch core, thin platform shells  │ │
│  │   (Mac/iPad fragment · visionOS compute · headless offscreen)│ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  PARAMETER CATALOG ──── declares everything above; persistence,   │
│  UI, and bindability are all derived from it                       │
└────────────────────────────────────────────────────────────────────┘
```

Module layout (Swift packages / targets):

```
ThresholdCore/          # no UI, no Metal — catalog, modulation, persistence, signals
  ParameterCatalog/
  Modulation/
  Signals/
  Persistence/
  Clock/
ThresholdShaderIR/      # transform ops, DE registry, ABI structs shared with MSL
ThresholdRender/        # Metal: pipelines, PSO cache, platform shells, MSL sources
ThresholdInputs/        # hand tracking, gestures, crown, orbit, audio analysis
ThresholdUI/            # SwiftUI; everything generated from the catalog
ThresholdHarness/       # headless CLI renderer + perf/regression harness
ThresholdApp/           # per-platform app targets, thin
```

Dependency rule: arrows point downward only. `ThresholdCore` and `ThresholdShaderIR`
have **zero** UI or platform dependencies — they compile in a CLI test target. This is
what makes headless testing and the harness cheap.

---

## 2. ParameterCatalog

The current codebase's biggest structural tax was ~63 controls with ~290 drifting
definition sites. In the rebuild, a parameter exists **only** as a catalog entry.

### 2.1 Declaration

```swift
enum Lane: Int, CaseIterable {          // fixed, ordered composition
    case scene, animation, user, gesture, music
}

struct ParamSpec<Value: ParamValue> {
    let id: ParamID                     // stable string, e.g. "shape.boxFold.limit"
    let label: String                   // UI display name
    let range: ClosedRange<Value>
    let defaultValue: Value
    let curve: ResponseCurve            // .linear, .exp(k), .sCurve — UI + binding both use it
    let unit: Unit?                     // .radians, .scale, .seconds — for display formatting
    let composition: Composition        // .additive | .multiplicative | .replace
    let smoothing: Smoothing            // per-lane time constants (music fast, user instant)
    let persistence: Persistence        // .scene | .deviceLocal | .transient
    let capabilities: Capabilities      // [.musicBindable, .gestureBindable, .animatable]
    let group: GroupID                  // UI section placement, e.g. .shape, .color, .camera
    let platformDefault: [Platform: Value]?  // e.g. safety bubble ON for visionOS only
}
```

Rules baked in from lessons learned:
- **`persistence` is per-param, not per-struct.** The FractalPreset "silently dropped 10
  fields" bug and the quality-accel "deliberately device-local" distinction both become
  declarations. Serialization walks the catalog; nothing can be forgotten.
- **`ParamID` is a stable string, hierarchical** (`"shape.mandelbox.absScalePow"`).
  Renames go through a migration table (§7.3), never by editing the ID.
- **Vector params are first-class** (`float3` color, `float4` shape tuples like the hand
  ball/softness/pocket group) — not four scalars glued together in the UI.
- The catalog is **data, built at startup, immutable after**. Fractal-type-specific
  params register under their type's namespace; only params for the active DE are shown,
  but all are resolvable (scene switching never loses values).

### 2.2 What derives from the catalog

| Consumer | Derivation |
|---|---|
| UI | `ModuleSectionView`-style generic renderer walks groups → sliders/toggles/pickers. Zero per-param UI code. |
| Scene/preset files | Serialize `(paramID → base value)` for `.scene` params. |
| Music binding UI | List of `.musicBindable` params, ranges/curves from spec. |
| Gesture binding | Same list mechanism, `.gestureBindable`. |
| Animation tracks | Any `.animatable` param is a keyframable track. |
| GPU encoding | Each spec declares its slot in the argument buffer layout (§5.4). |
| Range validation | Clamping happens in exactly one place: lane resolution. |

---

## 3. Modulation Engine

Every interaction bug in the original (music two-stack desync, gesture-vs-animation
override, `_audioOffset` parallel layers, music recentering) came from multiple writers
mutating one value. Here, **nobody writes a parameter value**. Writers own a *lane*, and
the engine composes lanes per frame.

### 3.1 Model

Per parameter, per frame:

```
resolved = clamp(range,
    scene            // base value: set by scene load / preset apply
  ▷ animation        // keyframe evaluation (absolute or offset per track config)
  ▷ user             // slider drag / persistent manual offset
  ▷ gesture          // transient, decays or holds per binding
  ▷ music            // transient, always decays toward 0
)
```

`▷` applies per the spec's `Composition` (additive on top of base, multiplicative for
scale-like params, replace for enums/toggles). Lane order is **fixed and global** — the
same for all params — so behavior is predictable: music always modulates around whatever
animation+gesture produced, gestures ride on top of animation (the
"gesture-override-during-animation" feature is the default behavior, not a fix).

### 3.2 Lane semantics

- **scene**: written only by scene apply / preset load. This is the *authoritative base*.
- **animation**: evaluated from tracks each frame; a track declares whether it replaces
  the base or offsets it. Stopping playback zeroes the lane — user/gesture/music offsets
  are untouched (the original's "music survives animation playback" for free).
- **user**: written by UI. On slider grab, the UI shows the *resolved* value; the drag
  writes the user lane such that resolved matches the thumb ("grab-what-you-see"). A
  "commit" gesture (release + hold, or explicit button) can fold user into scene for
  scene authoring.
- **gesture**: written by the binding layer from gesture signals. Per-binding policy:
  `momentary` (decays when the signal ends) or `latched` (holds until re-grabbed).
- **music**: written by the binding layer from audio signals; always transient, always
  decays with the spec's smoothing constant. **Recentering is a non-event** — music is
  never folded into base, so the two-stack desync class of bug cannot exist.

### 3.3 Implementation notes

- Storage: one dense `[Float]` per lane, indexed by catalog slot (SoA, cache-friendly);
  vectors occupy consecutive slots. Resolution is one linear pass, `O(params × lanes)`,
  trivially SIMD-able, runs on the render thread right before snapshot.
- **Threading rule**: lanes are written from any thread via a lock-free mailbox
  (latest-value-wins per writer); the resolver drains mailboxes once per frame on the
  render thread. No other synchronization exists. This kills the "node stack vs
  dispatcher stack unsynced" category.
- Smoothing (per-lane exponential time constants from the spec) is applied at
  resolution, driven by the AppClock (§8.1) so pausing time pauses decay.
- The resolver emits an immutable **FrameSnapshot** — resolved params + transform op
  buffer + DE handle + camera. The GPU encoder and the UI's readback both consume the
  snapshot; nothing downstream reads live lanes.

---

## 4. Signals and Bindings (hands, gestures, crown, music)

### 4.1 Signal bus

Every input source publishes **named signals**, not parameter writes:

```swift
struct Signal {
    let id: SignalID          // "hand.left.pinchStrength", "audio.onset", "crown.delta"
    let value: SIMD4<Float>   // scalar in .x; vectors use more lanes
    let confidence: Float     // 0…1; hand tracking quality, audio SNR
    let timestamp: TimeInterval
}
```

Standard signal namespaces:
- `hand.{left,right}.{position, palmNormal, pinchStrength, grabStrength, fingertip.N}`
- `gesture.{swipe.direction, orbit.delta, zoom.delta, dwell}`
- `crown.{value, delta}`
- `audio.{onset, rms, band.low, band.mid, band.high, centroid, beatPhase}`
- `app.{time, beatClock}` (for tempo-synced modulation)

Sources are dumb: the hand tracker knows nothing about fractals; the audio analyzer
knows nothing about parameters. Device-specific tuning (swipe thresholds, pinch
hysteresis) lives in the *source*, in one place.

### 4.2 Bindings

A binding maps a signal to a lane write:

```swift
struct Binding: Codable {
    let signal: SignalID
    let param: ParamID
    let lane: Lane                 // .gesture or .music (only transient lanes bindable)
    let mapping: Mapping           // input range → output range, curve, deadzone
    let policy: Policy             // .momentary | .latched
    let scale: Float               // user-tunable strength
}
```

- Bindings are **data**: scenes persist them (a scene can ship its own music mapping),
  users edit them in a generic binding UI derived from the catalog's capability flags.
- Music reactivity and hand reactivity are *literally the same mechanism* with different
  signal sources. The original's "core scalar gesture+music wiring: 6 lockstep points"
  becomes: add capability flag, done.
- Discrete actions (scene swipe → next scene) go through a parallel
  `signal → Command` table rather than the lane system; commands are the same ones the
  UI menu invokes.

### 4.2.1 Music binding, concretely (current system → target binding model)

The shipping music system is more structured than a generic signal→lane map and the
rebuild's `Binding` (§4.2) needs to reproduce three things it gets right, not flatten
them away:

- **Explicit, user-composed mapping list**, not always-on per-slider bindings. A user
  adds discrete `(target, source, curve, amount, ...)` mappings one at a time — this is
  `Binding` almost exactly, and ports directly.
- **A genre preset is a bundle of sensitivity scalars + a default mapping set**
  (Electronic/Ambient/Rock/Classical/Hip-Hop), applied as one action. In the rebuild
  this is a named, shareable *set of `Binding` values plus a few global scale params*,
  serializable the same way a scene's warp stack is — not a special preset type.
- **Response curve is per-binding, not per-source**: sinusoidal ("Wave"), pulse,
  drift-toward-target ("Follow"), and a hybrid combining two. This maps onto `Mapping`
  (§4.2) — `curve` already carries this; make sure the curve library includes at least
  these four shapes plus an optional secondary-curve blend, since "hybrid" isn't
  expressible as a single response-curve enum case.

**The bug the current system had to work around, and why the lane model prevents it
structurally:** formula (fractal-shape) params have two separate value stacks
(`coreStacks` for effect params, `formulaStacks` for shape params) because animation
playback owns `formulaParams` directly during keyframe evaluation, forcing manual and
audio edits during playback into parallel offset fields (`manualFormulaParamOverride`,
`audioFormulaParamOffset`) composed elsewhere. When a user drags a formula slider, only
the render-facing stack updates; the *audio* layer's stack keeps composing on a stale
anchor unless explicitly re-centered (`recenterMusicBase`, called from the slider path
but — by the fix's own comment — deliberately *not* needed for core/effect params,
because those share one stack for both `.ui` and `.music` layers). This is exactly the
"two writers, one value" class of bug §3's lane model is designed to make impossible:
**there must be exactly one value stack per parameter, full stop — no
core-vs-formula split, no per-source-type exception.** Any future performance reason to
special-case animation playback should special-case *how the animation lane is
evaluated*, never spawn a second stack for a subset of params.

### 4.3 Hand interactivity, specifically

Two distinct consumers of hand data, deliberately separated:

1. **Parametric**: hand signals → bindings → lanes (pinch controls color shift, etc.).
2. **Spatial**: hand *geometry* (joint transforms) feeds the **transform op stack** as
   ops (§5.2) — attraction/pocket/carve effects are DE-space operations, not parameters.
   The CPU side updates the op's fields (hand position, strength) each frame; because
   it's just an op in the stack, hand effects compose with kaleido/folds, reorder,
   serialize into scenes, and can themselves be music-modulated (op fields are catalog
   params too — see §5.3).

Fallback rule: every hand-driven effect must have a non-hand control path (slider or
simulated signal) so Mac/iPad and the headless harness can exercise it.

### 4.4 Hand deformation, concretely (current system → target op model)

The shipping implementation (`HandAttractionConfig`, `applyHandAttraction*` in
`Shaders.metal`) is **one signed-strength CSG blob per hand**, not a kind enum: a single
smooth-min/smooth-max sphere (attract when `strength > 0`, repel when `< 0`, magnitude
controls carve *depth* independent of a separate blend-softness field), an optional
inner dual-sphere "pocket" hollow (attract-only), and a wholly separate forearm capsule
(wrist→elbow) that is **always carve-only regardless of sign** — it exists purely so
Compositor passthrough of the user's real arm is never occluded by fractal geometry, not
to sculpt. Only 2 points per hand ever reach the GPU: palm position (not per-finger) and
forearm wrist+elbow. Tunables: radius (0.05–1m), signed strength (−1..1), ball-scale,
blend-softness, pocket-size/softness, a "Reach Offset" (`projectionDistance`, 0–1m —
projects the effect center outward along the palm normal so the bulge sits past the
fingertips), and independent forearm radius. The whole feature is opt-in behind an
app-level `handEffectsBeta` flag: persistence load and scene-apply both force
`enabled = false` unless the flag is set, independent of the saved value — so tuning
survives while the feature stays invisible to most users. Forearm carve additionally
defaults off even when the beta flag is on.

Rebuild mapping: this becomes exactly two `WarpOp` kinds — `handAttract` (payload:
hand-space center + radius in `a`, ball-scale/softness/pocket-size/pocket-softness
packed in `b`, sign of `strength` selects attract/repel, `pocketEnabled` as a payload
bit) and `forearmCarve` (payload: capsule endpoints + radius; always subtractive, no
sign field at all — encoding "carve-only" structurally instead of by convention).
Reach Offset is a CPU-side derived field (palm position + palm normal → offset center)
computed before the op is written, not a separate op. The beta gate becomes a single
`Capabilities.requiresOptIn` flag checked once at lane resolution, replacing today's
three separate enforcement sites (persistence load, scene apply, live toggle).

---

## 5. Shader IR — DEs and the transform stack

The renderer's contract with content is a small IR, not a monolithic shader.

### 5.1 Distance estimator ABI

Every DE — built-in or external — is a Metal `[[visible]]` function with one signature:

```metal
// The immutable ABI. Version it; never widen it casually.
struct DEContext {
    device const float* params;    // pointer + count, NEVER by-value blobs
    uint paramCount;
    float time;
    float lodScale;                // epsilon/detail policy input
};
float2 de_main(float3 p, thread const DEContext& ctx);   // .x = distance, .y = orbit trap / material
```

- Built-in DEs (Mandelbox, Bulatov limit set, …) compile into the app's metallib as
  visible functions.
- **External DEs** (`.threshscene` with embedded MSL) compile at load via
  `makeLibrary(source:)` against a published header defining the ABI, then link through
  a **visible function table**. Same table, same call site — external and built-in are
  indistinguishable to the render core.
- Coloring/orbit-trap hooks are optional secondary visible functions with defaults.

**Hard rule (learned at cost):** anything crossing the CPU→GPU boundary is
pointer+count into argument buffers. No 272-byte structs by value through the march
loop; the params struct that *is* by-value stays under ~64 bytes (camera, epsilon
policy, a few uniforms) and is measured in CI (§9).

### 5.2 Transform op stack

Space transformations are an **interpreted op list in a device buffer** (the approach
that won in the original after codegen was removed) — kept, but designed as the primary
content model rather than a feature:

```metal
struct WarpOp {                   // 32 bytes, fixed — rank-3 coxeter proved this is enough
    uint  kind;                   // fold, twist, kaleido, coxeter, sphereProject, handAttract…
    float strength;
    float4 a, b;                  // op-defined payload (normals, axes, centers)
};
// march-time: p = applyOps(p, ops, opCount);  runs before de_main
```

- Ops apply in order; the stack is reorderable, serializable, and shared verbatim
  between CPU (editing/simplification) and GPU (execution).
- The **simplifier** (exact-only fusion: drop no-ops, coalesce idempotent folds, sum
  parallel twists) runs CPU-side on stack change, producing the buffer the GPU sees.
- Ops carry a `isometric: Bool` registration flag → the DE Lipschitz/step-scale policy
  is computed per-stack instead of globally pessimistic.
- **Normals**: single implementation of gradient sampling that reuses `applyOps` —
  never a second hand-unrolled sweep (the T3 lesson: a "fast path" that skips the stack
  is incorrect, so make it impossible to write).
- Hand effects, the safety bubble, and sphere projection are all just ops. **There is
  exactly one sphere system.**

**Current transform inventory (17 kinds — carry forward as-is, this is the actual
content library, not a placeholder):**

| Op | Geometric effect |
|---|---|
| Twist | rotate p about an axis by an angle proportional to axial distance (vortex shear) |
| Bend | bow space around an axis |
| Mirror Fold | `abs()` all axes at once — fold into the positive octant |
| Box Fold | Mandelbox box fold — clamp+reflect, optional "Hall of Mirrors" infinite tiling |
| Sphere Fold | Mandelbox sphere fold — inflate the region inside a min radius, rescale the shell |
| Sphere Inversion | true conformal inversion through a sphere — swaps near/far |
| Kaleidoscope | fold the polar angle of p.xz into one wedge — rotational symmetry |
| Ripple | sinusoidal displacement along an axis |
| Tube Fold | sphere fold restricted to one plane — carves vertical tube structure |
| Shells | fold radius to the nearest concentric shell — onion layering |
| Scale Repeat | log-radial Droste — exponentially growing self-similar copies |
| Coxeter | {p,q} rank-3 reflection-group fold across 3 precomputed mirror normals — full polyhedral symmetry |
| Plane Fold | reflect points behind an arbitrary aimed plane |
| Menger Fold | abs-fold + descending coordinate sort — Menger-sponge prep |
| Tiling | infinite lattice domain repeat |
| Scale | uniform domain scale (IFS fold→scale glue step) |
| Offset Fold | mirror fold whose crease is shifted off-origin (asymmetric fold) |

Each op is exactly 32 bytes today (`type:int, strength:float, p1:float, p2:float,
axisX/Y/Z:float, _pad:float` — 8×4B, explicit padding to a 32-byte stride,
`ShaderTypes.h:231-243`) — **re-verified; the 32B figure in §5.2's `WarpOp` sketch is
correct as originally written.** Coxeter's 3 precomputed mirror normals fit inside this
today by packing into `p1/p2/axis` rather than needing a wider payload — if the
rebuild's `WarpOp` widens to `float4 a, b` for hand/forearm ops (§4.4), that is a
genuine size increase over the current format, not a correction of a miscounted
original; treat it as a deliberate design change to weigh (more payload room per op vs.
doubling the struct size and GPU buffer footprint), not a bug fix.

The existing simplifier (adjacent-only, exact-fusion-only: drops zero-strength no-ops,
coalesces idempotent full-strength Mirror/Scale-Repeat/Shells, sums parallel-axis
Twists) is correct and should port unchanged — its exclusions are load-bearing
(Kaleidoscope and Box Fold "look idempotent but are not"; Coxeter isn't exactly
idempotent when non-convergent). Keep the "no approximate rules, ever" contract.

### 5.3 Op fields are parameters

Each stack slot's fields (`strength`, payload components a transform exposes) register
dynamically in the catalog under `warp.slot{N}.{field}` when the stack changes. That
makes every op field music-bindable, gesture-bindable, animatable, and scene-persisted
through the *same* machinery as everything else — the original's per-slot music binding
with audio-offsets-folded-at-snapshot becomes a non-special case (offsets live in the
music lane; the snapshot bakes `resolved strength` into the op buffer).

**Note on current vs. target scope:** re-verified against `MusicReactiveTypes.swift:
187-208` — today only `strength` is music-bindable per slot (`.spaceWarp0`...
`.spaceWarp7`, one bindable target per slot, resolved dynamically, no per-field
selection of `p1`/`p2`/axis). Binding `p1`/`p2`/axis per field, as this section
proposes, is a **real scope increase** over the shipped feature, not a description of
what exists today — worth flagging as a deliberate expansion when scoping rebuild
Phase 5 (§11), since it's more UI and more catalog entries than the original shipped.

### 5.4 GPU data layout

One argument buffer per frame snapshot:

```
[ FrameUniforms (small, by-value: camera, epsilon policy, time, resolve dims) ]
[ resolved param table   (dense float array, catalog slot order)             ]
[ warp op buffer         (WarpOp × count)                                    ]
[ DE function table index + DE param slice offset                            ]
```

Triple-buffered ring; the snapshot is immutable, so no fences beyond the ring.

### 5.5 Color: palettes, orbit-trap mapping, post-process grading

Color is presently a three-stage pipeline, not one system, and the rebuild should keep
the three stages distinct because they answer different questions:

1. **Mapping** — how a `float t ∈ [0,1]` is derived from fractal data each pixel.
   `ColorMappingMode`: orbit-trap distance (the default/classic look — the fractal
   iteration loop tracks `minTrap`/`trapIter`/`trapPos` as it runs, no separate pass),
   iteration count, z-depth, orbit-trap angle, surface normal, or a blend of trap +
   iteration. This is genuinely per-fractal-type data (whatever the DE's inner loop
   already computes), so in the rebuild it's a second, optional return channel on
   `de_main` (§5.1's `.y` component is already reserved for exactly this) rather than a
   bolt-on.
2. **Palette** — a gradient of up to 8 RGB stops (`GradientStop{position, color}`),
   sampled at `t` with configurable repeat count, phase offset, and edge smoothing.
   14 built-in named presets exist today (classic/ocean/fire/forest/nebula/mono/aurora/
   volcanic/neon-cyber/neon-sunset/neon-matrix/rainbow/infrared/twilight) plus a
   separate procedural "neon" hue-cycle path (`hueFrequency`/`hueOffset` driven off
   iteration count, not literally time). Palette **is scene-persisted content**, same
   tier as the warp stack — in the rebuild it belongs in the scene envelope (§7.1)
   as `palette: { stops, mappingMode, repeat, offset, smoothing }`, not as loose catalog
   scalars.
3. **Grading** — a fixed post-process chain applied to every pixel after mapping+palette:
   saturation, contrast, saturation-power (gamma-like curve on saturation specifically),
   vibrance, shadows/highlights lift, a midtone S-curve, gamma, and an optional ACES
   filmic tonemap blend (`tonemapStrength`, default 0 = old plain clamp — kept opt-in
   deliberately so existing scenes don't silently change look). No LUT-texture grading
   exists or is needed; the parametric chain covers the shipped look. Every one of these
   is a plain catalog scalar (`.scene`-persisted, `.musicBindable`) — nothing here needs
   new machinery beyond §2.

**Color cycling** is two independent mechanisms that get conflated in casual naming and
should stay separate in the rebuild:
- `gradientOffset` — animatable/music-bindable phase shift through the palette stops
  ("Color Offset" target). This is an ordinary catalog param on the animation/music
  lanes, nothing special.
- A calmed hue-phase accumulator (`hueSpeed`, radians/sec, wrapped) driving the fog tint
  and the procedural neon path — this is time-integrated state, not a stateless function
  of `t`, so it needs an explicit phase accumulator owned by the render thread (fed by
  AppClock, §8.1) rather than being resolved fresh each frame like other lanes; treat it
  as a first-class exception to "lanes are stateless," not a bug to design out.

### 5.6 Pipeline & PSO caching

- Function constants only for *structural* variants (has-warp-stack, shadow mode,
  foveation on), not per-parameter — keeps PSO count low.
- `MTLBinaryArchive` cache keyed on `(shader source hash, DE source hash, function
  constant set)` — **content hash, not CFBundleVersion** — killing the stale-archive-on-
  dev-builds trap structurally. Runtime-compiled external DEs can't serialize into the
  archive (API limit); cache their `MTLLibrary` in memory keyed by source hash and
  accept first-load compile cost.

---

## 6. Render core

### 6.1 One core, thin shells

All march logic lives in header-style MSL included by every entry point:

```
RaymarchCore.h        march loop, DE dispatch, normals, shadows, AO, coloring
+ fragment_main.metal      Mac/iPad fragment shell (~30 lines)
+ compute_tiled.metal      visionOS 8x8 adaptive-hierarchical shell
+ compute_offscreen.metal  headless/harness shell
```

Shells do exactly: decode their invocation (pixel/tile/foveation rate map) → produce a
ray → call `marchAndShade(ray, snapshot)` → write output. Foveation rate-map decode is
a shell concern; everything visual is core.

### 6.2 Feature table

Every render feature registers in a single table:

```swift
struct RenderFeature {
    let id: FeatureID
    let paths: Set<RenderPath>        // which shells support it
    let requiredOnAll: Bool           // if true, CI fails when a path lacks it
}
```

A CI check walks the table against compiled function constants per shell. "Zoom fog
comp exists on fragment but not compute" becomes a build failure, not a device
discovery six weeks later.

### 6.3 Zoom & scale model

Zoom = model-scale renormalization (the original's choice, kept — it's what enables
infinite zoom). Consequences designed in, not patched in:

- Epsilon, LOD, proxy-geometry inflation, and horizon/far-threshold all derive from a
  single `ScaleContext { modelScale, octave }` struct consumed by both vertex and
  march code — the zoom-out sphere fix (horizon lift + proxy inflate + epsilon rescale,
  which had to touch three places) becomes one struct with three consumers.
- Octave rebase (Phase 2 of infinite zoom) is a renormalization event between frames:
  when the zoom phase reaches +8 octaves, SessionCore folds the integer part into an
  `octave` counter, subtracts it from the integrator phase, and scales the base camera
  by the matching power of two — both rewrites are float-exact, so the image cannot
  move while the phase and camera coordinates stay in a healthy float range at any
  depth. Zoom-IN only (zoom-out collapses features toward the origin and accumulates
  no coordinate drift; −64 remains its honest budget). The counter persists as the
  envelope's optional `scaleOctave` (omitted when 0 — pre-octave files unchanged).

### 6.4 visionOS specifics

- Compute path with adaptive tiling; immersion via progressive style (portal render
  context) supported from the start — portal mask is a fixed final pass slot.
- The fps-holding quality governor operates on a `renderQuality` catalog param via the
  *animation lane semantics* (a system writer with its own lane priority below user):
  user slider = ceiling, governor modulates below it. No bespoke override logic.

---

## 7. Persistence & external content

### 7.1 Scene format

`.threshscene` = a JSON (or binary-plist) envelope:

```
{ version, fractalTypeID | embeddedDE { source, abiVersion, hash },
  params:   { paramID → value },        // only .scene-persisted params, from catalog walk
  warpStack:[ { kind, fields… } ],
  bindings: [ Binding… ],               // optional: scene-shipped music/gesture mappings
  camera:   { … },
  region:   { bounds in camera+param space }   // regions-of-interest support
}
```

- Serialization is a **catalog walk** — a param cannot be forgotten because there is no
  hand-written field list. Unknown params on load are preserved (round-trip safe) and
  warned, not dropped.
- **Apply is authoritative and lane-scoped**: scene apply writes only the scene lane +
  warp stack + camera. It cannot leak enabled-state or clobber user offsets (the MSP
  migration bugs are structurally impossible).
- Policy hooks live at apply time as explicit rules (e.g. "safety bubble: apply scene
  value only if scene has it ON; user disable is device-local" — expressible because
  persistence policy and apply policy are per-param data).

### 7.2 External DEs

Embedded-DE scenes compile against the published ABI header (§5.1). Validation at load:
compile → link into function table → **probe render** (headless 64×64 march with NaN/
divergence detection) → accept or reject with the compiler diagnostics surfaced to the
user. Never trust-and-crash.

### 7.3 Versioning & migration

- Envelope `version` + per-param stable IDs mean most format evolution is additive.
- A single ordered migration table maps old paramIDs/ranges to new
  (`"shape.msp.radius" → "warp.sphereProject.radius" × k`). Migrations are data +
  pure functions, unit-tested against a corpus of real saved scenes checked into the
  repo (the original's Disguise/Vampire negative-MinDistance loss is the cautionary
  tale: capture the corpus *early*).
- **Legacy phase-out policy.** All original-app compatibility is QUARANTINED in the
  version-0 migration layer (`LegacyMigration`, `LegacyAnimMigration`,
  `LegacyBindingMigration`, `LegacyFormulaShim`) — reachable only when decoding a
  version-less legacy tree; native version-1 files never execute a line of it. No NEW
  legacy surface may be added outside that layer. The exit ramp is native save
  (`captureScene` → catalog-walk snapshot): a legacy file opened and re-saved is a
  fully-formed version-1 document (embedded formulas keep their shimmed source, now
  hashed). Once the corpus and users' files are re-saved, the version-0 entries are
  deleted in a major version — the migration table is append-AND-retire.

### 7.4 File types

Finder/Files-app open flow for `.threshscene`, `.threshanim` (keyframe tracks),
`.threshmp` (binding maps), `.threshfx` (warp stack recipes) — each is a sub-envelope
of the scene format, so loaders share one code path.

---

## 8. Services

### 8.1 AppClock

One injected clock: `now`, `delta`, `paused`, `timeScale`, plus a beat clock derived
from audio tempo when available. Animations, color cycling, modulation smoothing, and
gesture decay all take the clock as a dependency — **no ambient `CACurrentMediaTime()`
in feature code** (lint rule). Headless harness substitutes a deterministic
fixed-step clock, which is what makes byte-identical captures trivial.

### 8.2 Audio analysis

`AudioAnalyzer` = tap → FFT → feature extraction (onset via spectral flux, band
energies, RMS, centroid, beat/tempo) → publishes signals (§4.1). It has no knowledge of
parameters. Feature quality work (better onset detection — a known roadmap gap) happens
entirely inside this box.

### 8.3 Camera & navigation

Camera is a parameter group like any other (position/orientation/scale in the catalog,
`.scene`-persisted), so camera animation, gesture orbit, and music-driven camera drift
all use lanes. Desktop orbit/zoom writes the gesture lane; "walking" in visionOS writes
user. Scenes-as-regions (bounded boxes in unified camera+param space) are the region
field in the scene envelope; the sampling/sensitivity work for damped music coupling
plugs in as per-region binding scale hints.

---

## 9. Testing & harness (built in week one)

- **Headless renderer**: `ThresholdHarness` CLI renders any scene deterministically
  (fixed-step clock, phase-freeze) to PNG + stats JSON. No CVDisplayLink, no
  app-active gating — the render core never knows about either.
- **Golden images**: corpus of scenes rendered per-commit; byte-compare (Mac) /
  perceptual-compare (across GPU families).
- **Perf gate**: per-commit ms/frame on the canonical stress scene, with the
  measured-steps atomic counter always compiled in behind a function constant.
  **All perf claims come from this harness — no hand-written numbers in docs.**
- **ABI checks in CI**: `sizeof(FrameUniforms) ≤ 64`, `sizeof(WarpOp) == 32`, DE ABI
  header hash matches published version.
- **Round-trip tests**: every catalog param save→load→compare, generated automatically
  from the catalog (cannot go stale as params are added).
- **Migration corpus**: real legacy scene files replayed through migrations per commit.

---

## 10. Frame data flow (one frame, end to end)

1. Input sources publish signals (any thread) → signal bus latest-value store.
2. Binding layer maps signals → lane mailbox writes (gesture/music lanes).
3. UI writes user lane; animation evaluator writes animation lane (render thread).
4. Render thread: drain mailboxes → resolve lanes (smoothed, clamped) →
   **FrameSnapshot** (resolved params, baked warp op buffer, DE handle, camera,
   ScaleContext).
5. Encoder writes snapshot into the next argument-buffer ring slot.
6. Platform shell dispatches (fragment draw / tiled compute) → RaymarchCore → present.
7. UI reads back the same snapshot for display values; harness dumps it for
   determinism checks.

---

## 11. Build order

Ordered so every phase is demo-able and the risky ABI decisions happen earliest:

1. **Skeleton + harness**: catalog (10 params), modulation engine, fixed-step clock,
   offscreen render of one hardcoded DE. Golden-image + perf gate live.
2. **Shader IR**: WarpOp buffer + 5 ops + simplifier; DE visible-function ABI with two
   built-in DEs; ABI size checks in CI.
3. **Persistence**: scene envelope, catalog-walk serialization, round-trip tests,
   migration table scaffold.
4. **Derived UI**: generic module/section renderer from the catalog; grab-what-you-see
   slider semantics.
5. **Signals + bindings**: signal bus, binding data model + UI; audio analyzer (RMS +
   bands first, onset second) → music reactivity working end-to-end.
6. **Animation**: keyframe tracks writing the animation lane; `.threshanim` files.
7. **Platform shells**: Mac fragment shell → visionOS compute shell + feature-table CI
   check; progressive-immersion portal pass.
8. **Hands & gestures**: hand tracker signals; hand-geometry warp ops
   (attract/pocket/carve); gesture commands (scene swipe); Crown dial.
9. **External DEs**: runtime compile + probe validation + external file open flow.
10. **Zoom/scale**: ScaleContext plumbing, then octave rebase.

---

## 12. Appendix — current app: full user-facing feature inventory

This section catalogs the UI that exists **today**, so the rebuild's derived-UI system
(§2.2, §11 phase 4) has a concrete completeness target: everything below must be
reachable through catalog groups + generic renderers, not hand-built screens.

### 12.1 Navigation shell

Top-Dock ornament (5 tabs, pinned) + a left **Section Rail** per tab + a center content
panel. In the rebuild this whole shell is generic: `TopDockTab → [RailSection]` is just
`GroupID → [SubGroupID]` walked from the catalog's `group` field (§2.1); no per-tab
SwiftUI file is needed.

```
Explore | Shape | Visualizations | Music | Performance      ← Top-Dock tabs
   + secondary sidebar: Gestures, Settings, Quick Toggles
```

### 12.2 Explore tab — scene browser

Rail: Jumping Off · Music Reactive · Animated · Mixed · Custom Scenes. Grid of scene
preset cards (load / edit / checkmark-selected). → Rebuild: a view over the scene
persistence store (§7.1), filtered by scene metadata tags; no catalog involvement.

### 12.3 Shape tab

Rail: **Parameters · Formula · Hands · Space · Transform · Bounding · Performance**

- **Parameters** — fractal type label + auto-generated per-formula sliders/rotation
  matrix (already catalog-driven today) + Mandelbox-only Scale slider + "Music Shape
  Control" amount slider. → maps directly to catalog groups per fractal type
  (§2.1 `group`), the music-amount slider is a per-param lane gain (§3.1).
- **Formula** — fractal type picker (grid), equation display, switching resets params
  to type defaults. → `FractalTypeDescriptor` becomes a catalog namespace registry
  (§2.1); "reset to defaults" is `applyScene(defaults)` through the scene lane.
- **Hands** (visionOS, beta-gated) — Hand Attraction toggle, Radius slider
  (0.05–1.0), Repel↔Attract signed slider (-1…1). → this *is* §4.3's spatial hand
  effect: a warp op (§5.2, `handAttract` kind) whose fields are catalog params.
- **Space** — Sphere Projection toggle, Blend (0–1), Radius (0.1–3.0). → one more
  warp op kind (§5.2); sphere projection is not a special system in the rebuild,
  it's `kind: .sphereProject` in the same stack as Hands.
- **Transform** — the space-warp stack editor (§12.5 below).
- **Bounding** — bounding toggle, shape picker (Platonic presets + Sphere), size
  slider (0.05–30), fog mode picker (Off / Soft Fade / Inner Shadow [+ Shadow Depth
  slider] / Shell), Mixed-immersion size cap. → bounding is **also a warp/shading op**
  in the rebuild (a clip/fog kind operating on the resolved SDF), so its size,
  shape, and fog fields are ordinary catalog params; the bounded⇄Mixed immersion
  rule becomes a platform-scoped `platformDefault` + apply-policy rule (§7.1), not
  bespoke code.
- **Performance** — see §12.7.

### 12.4 Visualizations tab (color + effects)

Rail: **Color · Mapping · Grading · Cycling · Atmosphere · Transition · Reactive**

- **Color** — gradient preview/editor, saved custom gradients grid (rename/overwrite/
  delete), preset picker.
- **Mapping** — mapping-mode picker (Orbit Trap / Iterations / Z Depth / Angle /
  Normal / Blended), Gradient Transform sliders (Repeat, Offset [music-bindable],
  Smoothing), Color Blend sliders (Color Mix, Iterations).
- **Grading** — Tone (Contrast, Vibrance, Midtone Curve), Shadows & Highlights,
  Advanced (Ambient Occlusion, Filmic Tonemap).
- **Atmosphere** — Glow / Bloom / Fog, each: toggle + intensity [+ Fog Tint color],
  each music-bindable.
- **Cycling** — master Color Shift Speed, Gradient Cycle (+ Mirror Loop), Hue
  Rotation, Fog Hue Cycle, Pulse, Linear Rail, Polar Rotation (fractal-specific).
- **Reactive** — audio-binding editor (§12.6).

→ Every slider/toggle here is a catalog leaf under `group: .color`; the gradient
editor and saved-gradient library are the one genuinely bespoke widget (a curve
editor, not a slider) and stay hand-built in the rebuild too — catalog-derived UI
covers scalars/vectors/enums/toggles, not arbitrary curve authoring.

### 12.5 Space-warp stack editor (Shape ▸ Transform)

Add menu: **Recipes** (Icosahedral Bloom, Menger Blocks, Kaleido Tunnel, Nested
Spheres, Sierpinski Web) and **Surprise Me** (random weighted stack), plus individual
transforms grouped by family: *Mirrors & Folds · Spherical & Radial · Self-Similar
Repeats · Bend & Wave*.

Per-op card: slot index, name + tagline, music badge (field + bound-count), enable
toggle, reorder (up/down), delete, Master Amount slider, up to 2 kind-specific params,
an optional toggle option, and up to 3 axis sliders.

**All 17 transform kinds** (current `SpaceWarpKind` — this is the op-kind vocabulary
§5.2's `WarpOp.kind` must cover on day one of the rebuild):

| Kind | Family | Params | Notes |
|---|---|---|---|
| Twist | Bend & Wave | axis | screw around axis |
| Bend | Bend & Wave | axis | bow around axis |
| Ripple | Bend & Wave | axis, frequency | sine displacement |
| Mirror | Mirrors & Folds | — | fold into octant |
| Box Fold | Mirrors & Folds | fold limit, toggle "Hall of Mirrors" | Mandelbox fold |
| Plane Fold | Mirrors & Folds | axis, distance | mirror across a plane |
| Kaleidoscope | Mirrors & Folds | segments | N-wedge fold |
| Coxeter | Mirrors & Folds | p, q | {p,q} reflection group |
| Menger Fold | Mirrors & Folds | — | abs + sort octant |
| Offset Fold | Mirrors & Folds | axis | off-centre mirror |
| Sphere Fold | Spherical & Radial | min R, max R | inflate core |
| Sphere Inversion | Spherical & Radial | radius | turn inside-out |
| Tube Fold ("Circle") | Spherical & Radial | inner R, outer R | sphere fold in XZ plane |
| Shells | Spherical & Radial | spacing | concentric shells |
| Scale Repeat | Self-Similar Repeats | scale factor | log-radial Droste |
| Tiling | Self-Similar Repeats | cell size | infinite lattice |
| Scale | Self-Similar Repeats | — (master only) | uniform domain scale |

→ This table **is** the seed data for §5.2's op-kind enum and §2.1 catalog entries
for each op field (`warp.slot{N}.{field}`, per §5.3). Recipes and Surprise Me are
just named/randomized `[WarpOp]` arrays — pure data, no new mechanism. The
sphere-projection and hand-attract/bounding ops from §12.3 slot into this exact
same table as three more rows, which is the whole point of unifying them.

### 12.6 Music tab

Panel tabs: **Playback** (now-playing card, transport, service auth/priority — macOS
gets a waveform/FFT dashboard instead) · **Songs · Playlists · Albums** (library
browsers) · **Visualizations** (the reactive-binding editor: add binding, target
picker, audio-band source, response curve [Linear/Exponential/Smooth/Step/Pulse],
flashing-risk indicator, active-bindings list with edit/delete).

→ Playback/library browsing is a client of a `MusicLibraryService`, orthogonal to the
architecture. The **Visualizations** sub-tab is a direct UI over §4.2's `Binding`
list, filtered to `signal.namespace == "audio.*"` and `param.capabilities ⊇
.musicBindable` — generated, not hand-built, in the rebuild.

### 12.7 Performance tab

Rail: **Budget · Acceleration**. Acceleration exposes toggles for over-relaxation,
cone marching, LOD, smart advance, self-shadows, foveation, coherent packet,
bounding-sphere culling, plus a quality slider and adaptive-governor state; Budget
shows FPS, iteration/step counts, and (Metrics panel) measured steps-to-converge.

→ Toggles are catalog params under `group: .performance` (persistence: `.deviceLocal`,
per the original "quality accel fields deliberately device-local" rule, §7.1). The
governor is a system lane-writer below `user` (§6.4). The measured-steps display reads
the harness's in-kernel atomic counter (§9) — same instrumentation in dev and shipping
builds.

### 12.8 Animate tab (Scenes)

Play/Edit mode picker, scene list (name, thumbnail, play/edit/select), Infinite Zoom
card (toggle + signed speed slider, −max…+max, 0 = stationary).

→ Infinite Zoom's signed speed is a catalog param feeding `ScaleContext` (§6.3)
directly; it is bindable/animatable/music-reactive for free once it's a catalog entry,
which it notably is *not* today.

### 12.9 Gestures tab

Master enable, **Relative Gestures** toggle, **Tilt to Orbit** (macOS, motion sensor),
**Menu Toggle Gesture** (+ mode picker), **Per-Finger Tap** (middle → menu), and the
**Hand Constellation Panel** (visionOS: per-hand slot assignment, triplet/scalar
parameter binding UI).

→ The Constellation Panel *is* §4.2's generic binding editor scoped to `signal.namespace
== "hand.*" | "gesture.*"` — the same editor as Music ▸ Visualizations with a different
signal filter. In the current app these are two separately-built editors; in the
rebuild they're one editor, two filters.

### 12.10 Settings tab

Sub-tabs: **Display** (visionOS platform toggle+radius, dominant hand, text size,
iOS touch indicators, experimental/legacy toggles) · **Gestures** (full binding config)
· **Sharing** (Siri shortcuts, scene/animation share) · **Export** (save scene/preset,
custom name, thumbnail, video export) · **Advanced** (force-recompile shader cache,
beta feature gates: Allow Custom Scenes, Hand Effects Beta).

**Quick Toggles** sidebar: 4-col grid of one-tap toggles spanning Formula, Lighting &
Color, Space, Audio (incl. quick-mute per band), Performance — long-press jumps to the
full control's home section.

→ "Force Recompile" maps to §5.5's content-hash cache (should rarely be needed once
caching is keyed on source hash, not build metadata). Beta gates are a
`capabilities: .betaGated` flag rather than ad hoc `UserDefaults` booleans scattered
per feature. Quick Toggles is a *view*, not new state — a pinned/starred subset of
existing catalog entries (§2.1), so "jump to home section" is just `param.group`.

### 12.11 Fractal type catalog

12 selectable types + runtime `custom`: **Mandelbox, Mandelbulb, Menger Sponge,
Mandelbulb Julia, Quaternion Julia, Octahedron, Menger Sphere, Theli Pseudo Kleinian,
Kleinian, Box Sphere Folder, Bulatov Limit Set**, plus per-type category (Box Folds /
Power-Quaternion / Kaleidoscopic IFS / Hybrid Folds / Reflection Groups), icon,
equation string, per-type gesture core-action/triplet/scalar support, and per-type
quality presets (iteration/step overrides).

→ Each becomes one built-in DE registration (§5.1) plus a catalog namespace; the
equation string, icon, category, and quality overrides are metadata on that
registration — exactly the same registration path an **external** DE uses (§7.2),
which is the concrete proof that "built-in and external DEs are indistinguishable"
(Invariant 5) holds in practice.

### 12.12 Immersion & platform-specific controls

visionOS: Immersion picker (Immersive / Mixed) + Digital Crown continuous immersion
dial (dialing to zero switches to Mixed). Bounding-fog and Mixed-immersion-size-cap
interact per the bounded⇄Mixed rule (§12.3).

→ Immersion style is a platform-scoped catalog param; the Crown is a `crown.value`
signal (§4.1) bound to it via a **built-in, non-removable** binding (discrete
commands and safety-relevant bindings are allowed to be non-user-editable, per §4.2).

### 12.13 File handling

Open `.threshscene` / `.threshanim` / `.threshfx` from Finder or Siri; Quick Look
thumbnail + interactive preview extension; Save sheet (reset location / named preset /
named preset with thumbnail).

→ Unchanged in spirit — §7.1/§7.4's envelope format is designed to keep this flow
intact; Quick Look becomes trivial once the headless harness (§9) already renders
scenes offscreen deterministically, since Quick Look wants exactly that.

---

## 13. Invariants (the rules that must not break)

1. A parameter exists only as a catalog entry; UI/persistence/binding are derived.
2. No writer mutates a resolved value; writers own lanes, the resolver composes.
3. Music and gesture lanes are transient and never folded into base state.
4. Everything crossing CPU→GPU is pointer+count; by-value uniforms stay ≤ 64 B (CI-enforced).
5. One DE ABI; built-in and external DEs are indistinguishable past the function table.
6. Spatial effects (hands, bubble, sphere projection) are warp ops — one stack, one
   sphere system, ops serialize like all content.
7. Normals and every secondary ray reuse `applyOps` — no divergent fast paths.
8. One raymarch core; shells contain no visual logic; feature table is CI-checked.
9. No ambient time — everything takes the AppClock.
10. All perf numbers come from the harness. None are typed by hand.
11. Scene apply writes only the scene lane; apply policy is per-param data.
12. Shader caches key on content hashes, never build metadata.
