# Threshold — Apple-Ecosystem Architecture

This document is the concrete realization of the rebuild plan (`PLAN.md` / the
"Threshold Rebuild Architecture" spec). The plan defines *what* the three load-bearing
systems are — ParameterCatalog, Modulation Engine, Shader IR. This document defines
*how they are built on Apple's stack*: package topology, concurrency model, Swift and
Metal type design, and the resolutions to the open tensions the plan flags.

Where this doc and the plan disagree, this doc wins — each disagreement is called out
explicitly with a `⚖ DECISION` marker and rationale.

---

## 1. Project & package topology

One Swift package, `ThresholdKit`, containing all logic. Per-platform app targets in
the `.xcodeproj` are thin shells (App struct + scene declaration + entitlement plumbing)
that depend on the package.

```
Threshold/
  Package.swift                      # ThresholdKit — all real code lives here
  Sources/
    ThresholdCore/                   # catalog, modulation, signals, persistence, clock
    ThresholdShaderIR/               # WarpOp, DE registry, ABI structs (Swift side)
    ThresholdShaderABI/              # C header target: structs shared Swift ↔ MSL
    ThresholdRender/                 # Metal pipelines, shells, encoder (imports ABI)
    ThresholdInputs/                 # ARKit hands, gestures, crown, AVAudio analysis
    ThresholdUI/                     # SwiftUI, catalog-derived
  Shaders/                           # .metal sources, compiled into ThresholdRender
  Tests/                             # swift-testing; per-target test bundles
  Apps/
    ThresholdMac/                    # xcodeproj app targets, ~50 lines each
    ThresholdPad/
    ThresholdVision/
  Harness/
    threshold-render/                # SPM executable target: headless CLI renderer
  Corpus/                            # legacy scenes + golden scenes, checked in
```

Rules:

- **Swift 6 language mode, strict concurrency = complete, everywhere.** The lane/mailbox
  threading design in the plan is exactly the kind of thing strict concurrency either
  proves safe or forces you to be honest about (`@unchecked Sendable` with a comment is
  the honest escape hatch for the lock-free mailbox — one type, audited once).
- `ThresholdCore` and `ThresholdShaderIR` import **Foundation and simd only**. Enforced
  by the harness target: it links only those two + Render, and builds on CI as a plain
  `swift build` (no Xcode) — any accidental UIKit/SwiftUI/ARKit import breaks the build
  immediately rather than by convention.
- **`ThresholdShaderABI` is a C-header-only target** (`publicHeadersPath`), included by
  both Swift (via module import) and MSL (via `#include`). This is the single source of
  truth for `FrameUniforms`, `WarpOp`, `DEContext`, and slot-layout constants. No
  hand-mirrored Swift structs. `_Static_assert(sizeof(WarpOp) == 48, ...)` lives in the
  header itself, so the ABI checks fire at *compile* time on both sides, plus the CI
  size test in §9.
- The `.metallib` for built-in DEs and the raymarch core is built by Xcode's Metal
  toolchain for app targets, and by `xcrun metal` in a package build-tool plugin for the
  harness — same sources, so a shader that compiles for one compiles for both.

---

## 2. Concurrency model (the part the plan hand-waves)

Strict-concurrency-era Swift makes "runs on the render thread" something you must name.
The topology:

| Domain | Isolation | Owns |
|---|---|---|
| **Main** | `@MainActor` | SwiftUI, catalog *metadata*, binding editing, scene apply initiation |
| **Render** | dedicated thread (not a Swift actor) driven by `CAMetalDisplayLink` (Mac/iPad) / Compositor frame loop (visionOS) / manual step (harness) | lane storage, resolver, integrator state, snapshot ring, Metal encoding |
| **Inputs** | per-source (ARKit callbacks, AVAudioEngine tap queue, gesture recognizers on Main) | nothing shared — publish-only into the signal table |
| **Audio DSP** | `AVAudioEngine` tap → dedicated high-priority queue | FFT state, feature extractors |

Key decisions:

- **The render loop is a thread, not an actor.** Swift actors don't give bounded
  latency; a frame callback must never await. The render thread is reached only through
  two lock-free structures:
  1. **Signal table** — fixed-size array of slots (one per registered `SignalID`,
     allocated at startup). Each slot is a seqlock-style double-buffered
     `(SIMD4<Float>, confidence, timestamp)` cell. Writers (any thread) publish
     latest-value; the resolver reads at frame start. No allocation, no locks held
     across work.
  2. **Command mailbox** — MPSC queue for structural changes (scene apply, warp-stack
     edit, binding change, DE swap). Drained once per frame *before* resolution, so a
     frame sees either the old structure or the new one, never a torn mix. This is also
     where "scene apply writes only the scene lane" is enforced — apply is a command,
     not a pile of setter calls. A structural operation that spans several fields is
     represented by **one command** (for example, a prepared embedded-DE scene carries
     its compiled program in the scene-apply command); callers never publish a
     multi-command transaction that another producer could interleave.
- Request/reply operations that cross the render boundary use a command plus a
  Sendable result slot. Fallible replies publish a terminal `Result` — absence means
  only "pending," never "failed silently." The live image-capture path follows this
  rule, including unsupported-platform and renderer-initialization failures.
- **FrameSnapshot is an immutable value type**, `Sendable` for real (all `let`, POD +
  a reference to an immutable op buffer). UI readback and the harness both consume
  snapshots from a published `latest` slot; nothing downstream ever reads live lanes,
  exactly as the plan requires — but now the compiler enforces it, because lane storage
  is non-Sendable and confined to the render thread.
- **UI readback cadence is decoupled from render cadence.** A `@MainActor @Observable
  final class ParameterMirror` polls the latest snapshot on a main-thread display link
  and updates only values that changed beyond epsilon. SwiftUI invalidation is driven
  by the mirror, so a 90 fps render loop doesn't cause 90 fps SwiftUI diffs. Slider
  views read the mirror; slider *writes* go straight to the user-lane mailbox.

---

## 3. ParameterCatalog in actual Swift

The plan's `ParamSpec<Value>` generic is right as an authoring API but wrong as a
storage model — you can't put heterogeneous generics in one table. Realization:

```swift
// Authoring (type-safe, one declaration per param):
extension ParamKey {
    static let boxFoldLimit = ParamKey("shape.boxFold.limit")
}
catalog.register(Param(.boxFoldLimit, label: "Fold Limit",
                       range: 0.5...3.0, default: 1.0,
                       curve: .linear, composition: .additive,
                       smoothing: .lanes(music: 0.08, gesture: 0.15),
                       persistence: .scene,
                       capabilities: [.musicBindable, .animatable],
                       group: .shape))

// Storage (erased, dense):
struct CatalogEntry {           // one per scalar SLOT, vectors span consecutive slots
    let key: ParamKey           // stable string id
    let slot: Int               // index into lane arrays AND the GPU param table
    let kind: ParamKind         // .float, .float3, .float4, .bool, .enum(count)
    // ... erased spec fields
}
```

- **`ParamKey` is a wrapped `StaticString`-backed constant, declared centrally.** The
  plan says "stable string"; raw strings at call sites are how typos become runtime
  bugs. All keys live in one file per namespace, so the migration table (§7.3 of the
  plan) diffs cleanly in review. Dynamic keys (warp slot fields, external DE params)
  are constructed through one factory (`ParamKey.warp(slot:field:)`) — never ad hoc
  interpolation.
- **Slot order is the GPU layout.** `slot` is assigned at registration, appended-only
  within a session; the resolved param table uploaded to the GPU is literally the
  resolver's output array. One layout, zero marshalling code.
- Bools and enums live in the same float table (0/1, index-as-float) — the GPU wants
  floats anyway, and it keeps the resolver a single SIMD pass. `composition: .replace`
  handles their lane semantics.
- Dynamic registration (warp-slot fields, external-DE params) uses a **reserved slot
  arena** at the end of the table (e.g. 256 slots), recycled on stack/DE change via the
  command mailbox. The GPU-facing layout never reshuffles mid-frame.

### Grab-what-you-see, precisely

The plan's slider semantics need one rule to be implementable: **the user-lane write is
the inverse of the composition chain.** On drag, the UI computes
`userValue = invert(composition, target: thumbValue, otherLanes: snapshot)` and writes
that. This requires every `Composition` to be invertible given the other lanes:
additive and multiplicative are; `.replace` is trivially (user lane simply *is* the
value). This inversion is a pure function in `ThresholdCore` with property tests
(`resolve(invert(x)) == clamp(x)` for arbitrary lane states) — it's the one piece of
math the whole UI feel depends on.

### Stateful params (the hue accumulator)

The plan correctly flags time-integrated values as an exception. Formalize it:
`kind: .integrator(rate: ParamKey)` — the catalog entry's resolved value is a phase
owned by the resolver, advanced by `rate × clock.delta` each frame and wrapped. The
*rate* is an ordinary lane-resolved param (bindable, animatable); the *phase* is
resolver state, serialized as `.transient` (or optionally snapshotted into scenes for
exact reproduction). This covers hue cycling, gradient cycle, beat phase — one
mechanism, declared in the catalog like everything else, so Invariant 1 survives.

---

## 4. Metal strategy

### ⚖ DECISION: compute-only raymarch, all platforms

The plan proposes fragment shells for Mac/iPad and compute for visionOS. Collapse to
**one compute shell everywhere** (tile-dispatched, writing a texture; Mac/iPad present
via a trivial blit into the drawable, visionOS via Compositor Services layer textures,
harness reads the texture back):

- Visible function tables (the DE ABI) are best-supported and least-restricted in
  compute pipelines; the fragment path for function pointers has stricter feature-set
  and performance caveats.
- The plan's own Invariant 8 ("a feature cannot exist on only one path") is cheapest to
  enforce when there is *one* path. The feature table + CI check (§6.2 of the plan)
  shrinks to checking function-constant sets of a single kernel family.
- Adaptive/hierarchical tiling, the measured-steps atomic counter, and foveation
  rate-map decode are all compute-native; a fragment path would need parallel
  implementations of each.
- Cost: you give up hardware early-z/fragment interpolation — irrelevant for a
  full-screen raymarcher — and pay one blit (~free).

Fragment shells can be added later behind the same `marchAndShade` core if a concrete
need appears; nothing in the design precludes it. Don't build it speculatively.

### DE ABI details

- DEs are `[[visible]]` MSL functions in a `MTLVisibleFunctionTable` attached to the
  compute pipeline. Built-ins compile into the app metallib; external DEs compile at
  load with `device.makeLibrary(source:)` (works on iPadOS/visionOS — the Metal
  compiler is a system service, not JIT in the app's address space) and link via
  `MTLLinkedFunctions`. **Linking external functions requires creating a new pipeline
  state**, so external-DE load cost is one PSO compile — cache the resulting
  `MTLComputePipelineState` in memory keyed by DE source hash, and keep built-in DE
  pipelines in the `MTLBinaryArchive` (keyed on content hash per the plan; runtime
  libraries can't serialize into archives, accept that).
- The ABI header is versioned by hash; `.threshscene` embeds `abiVersion`, and the
  probe render (64×64, NaN/divergence check) runs before a scene's DE is ever attached
  to the live pipeline. Probe failures surface `MTLLibrary` diagnostics verbatim.
- **Security note**: external MSL is untrusted code on the GPU. It can't touch app
  memory outside bound buffers, but it can hang the GPU (infinite loop → command buffer
  timeout). Run the probe with a watchdog: separate `MTLCommandBuffer`, wait with
  timeout, treat timeout as rejection. Gate the whole feature behind the existing
  "Allow Custom Scenes" opt-in.

### ⚖ DECISION: `WarpOp` is 48 bytes

The plan flags 32 B (current) vs `float4 a, b` (proposed) as an open trade. Take 48 B:

```c
typedef struct {
    uint32_t kind;        // op kind enum
    uint32_t flags;       // isometric, pocketEnabled, hallOfMirrors, … per-kind bits
    float    strength;    // master amount — the universally bindable field
    float    _pad;
    simd_float4 a;        // per-kind payload (axis+angle, center+radius, …)
    simd_float4 b;        // per-kind payload (normals, secondary params)
} WarpOp;                 // _Static_assert(sizeof == 48 && _Alignof == 16)
```

Rationale: hand ops need center+radius+4 shaping params (§4.4 of the plan) — 32 B
forces packing games *now*, and Coxeter's three mirror normals already sit at the
packing ceiling. 48 B × 8–16 ops is ≤ 768 bytes per frame; the "doubling the buffer
footprint" concern in the plan is about a buffer measured in *hundreds of bytes* — it
is not a real cost on any target GPU. Explicit `flags` also removes today's
sign-encodes-behavior and toggle-in-p2 conventions. The 17-kind op vocabulary, the
adjacent-only exact-fusion simplifier, and its documented exclusions port unchanged.

### Frame encoding

Argument buffer ring, 3 deep, exactly as the plan lays out:
`[FrameUniforms ≤ 64 B by-value] [param table: device float*] [WarpOp buffer] [DE table index + param slice]`.
The ring slot is selected by frame index; snapshots are immutable so the only sync is
the ring's completed-frame semaphore.

---

## 5. Inputs on Apple frameworks

| Signal namespace | Source | Notes |
|---|---|---|
| `hand.*` | visionOS `HandTrackingProvider` (ARKitSession) | anchors → palm/joints in world space; confidence from tracking state. Runs in its own task, publishes to the signal table. Predicted poses via `queryHandAnchors(at:)` timed to the Compositor frame's `trackableAnchorTime`. |
| `gesture.*` | SwiftUI gestures (all platforms) + `SpatialEventCollection` (visionOS) | recognizers live in ThresholdUI but publish signals — no parameter knowledge |
| `crown.*` | visionOS immersion amount callbacks | the Crown *is* the immersion dial in progressive style; expose the resolved immersion amount as `crown.value` |
| `audio.*` | `AVAudioEngine` input/render tap → vDSP FFT (Accelerate) | features: RMS, 3-band energy, spectral flux onset, centroid, tempo (autocorrelation of onset envelope). MusicKit/local-library playback feeds the same tap path. |
| `motion.*` | CoreMotion (iPad tilt-to-orbit) | |

Music playback/library (`MusicLibraryService`) is MusicKit + `AVAudioEngine`; it is a
UI-layer client and deliberately outside the architecture core, per the plan §12.6.
System audio capture on macOS (visualize Spotify etc.) is a separate acquisition
backend behind the same analyzer (`AVAudioEngine` input tap from a loopback device is
user-configured; don't build virtual-device capture in v1).

Hand *geometry* → warp ops path (plan §4.3/4.4): a render-thread-side `HandOpWriter`
reads `hand.*` signals at resolve time and rewrites the payload fields of the
`handAttract`/`forearmCarve` ops in the current stack — through the same catalog slots
as any warp field, so music can modulate hand-effect strength with zero special cases.

---

## 6. visionOS render path

- **Compositor Services** (`CompositorLayer` in an `ImmersiveSpace`) with the compute
  kernel writing directly into `LayerRenderer.Drawable` textures. Foveation via the
  layer's rasterization rate maps, decoded in the shell (plan §6.1) — with compute-only
  rendering this means sampling the rate map to decide per-tile ray density, which is
  the adaptive-tiling mechanism anyway; one system, not two.
- Progressive immersion style from day one; the portal mask is the fixed final pass the
  plan specifies. Mixed mode = same pipeline, alpha-composited layer.
- Frame pacing: `LayerRenderer.Frame` predict/update/submit phases map exactly onto
  drain-mailboxes → resolve → encode. The harness's manual `step(dt:)` and the
  Compositor loop call the same `RenderFrame.execute(snapshot:)`.
- The quality governor writes a `system` value below the user lane. ⚖ Add an explicit
  `system` lane between `animation` and `user` rather than overloading animation-lane
  semantics as the plan suggests — lane order becomes
  `scene ▷ animation ▷ system ▷ user ▷ gesture ▷ music`. Cost: one more dense array.
  Benefit: the governor, safety clamps, and platform caps get a principled home and
  Invariant 2 stays clean.

---

## 7. Persistence

- Envelope: **JSON via Codable**, pretty-printed, sorted keys (diff-able scenes; users
  will share these). Binary plist buys nothing at these sizes.
- Serialization is a catalog walk (plan §7.1) — implemented as one generic
  `SceneCodec` over `CatalogEntry`, so round-trip tests are generated, not written.
- Unknown-key preservation: decode into a `[String: JSONValue]` sidecar carried through
  re-save. This is what makes forward-compatibility real rather than aspirational.
- File types (`.threshscene`, `.threshanim`, `.threshmp`, `.threshfx`) are exported
  UTIs on all app targets; Quick Look preview extension renders via the harness's
  offscreen path (plan §12.13).
- Migration corpus: `Corpus/legacy/` checked in from the current app **before** the
  rebuild ships anything — the plan's own cautionary tale says capture it early.

---

## 8. Testing & CI

- **swift-testing** for unit/property tests (`ThresholdCore` runs on any Mac, no GPU).
  Property tests on: lane resolution (clamping, composition, smoothing convergence),
  grab-what-you-see inversion, simplifier correctness (op-stack ≅ simplified-stack via
  sampled-point equivalence on the CPU reference implementation of `applyOps`).
- **CPU reference `applyOps` + reference DEs in Swift**, kept in `ThresholdShaderIR`.
  This is the oracle for simplifier tests and for golden-image triage (is the GPU wrong
  or the content?). It also enforces Invariant 7 structurally: MSL and Swift both
  implement the ABI header's op semantics, cross-checked by sampled equivalence tests.
- **Harness on CI**: Apple-silicon macOS runners have Metal; golden images render
  per-commit. Byte-compare on identical GPU family, perceptual (ΔE / SSIM threshold)
  otherwise. Perf gate uses the in-kernel step counter; numbers publish to a JSON
  artifact — the plan's "no hand-typed perf numbers" rule, mechanized.
- ABI checks: `_Static_assert` in the header (compile time) + a CI test that hashes the
  ABI header and compares to the published version constant.
- Lint rule (SwiftLint custom rule or a grep gate in CI): no `CACurrentMediaTime`,
  `Date()`, `DispatchTime.now` outside `Clock/` — Invariant 9 enforced mechanically.

---

## 9. Build order — amendments to the plan's §11

The plan's ten phases are right. Three amendments:

1. **Phase 0 (before phase 1): capture the legacy corpus.** Export every scene/preset
   from the shipping app into `Corpus/legacy/` now, while the old app still runs.
   Everything in §7.3 depends on this existing.
2. **Phase 2 includes the CPU reference `applyOps`** — the simplifier and the golden
   images both need the oracle from the moment ops exist.
3. **Phase 7 shrinks** because of the compute-only decision: it's "present the same
   kernel via MTKView blit / Compositor Services," not "build a second shell." Pull
   visionOS bring-up earlier if hardware validation of tiling+foveation is the scary
   risk (it is); nothing in phases 3–6 blocks it.

---

## 10. Invariants (additions to the plan's §13)

13. All cross-thread communication with the render loop goes through the signal table
    or the command mailbox — no third channel, ever.
14. `ParamKey`s are declared constants or factory-constructed; no interpolated key
    strings outside the factories.
15. There is exactly one march shell family (compute); presentation differences are
    blit/compositor concerns.
16. The lane order is `scene ▷ animation ▷ system ▷ user ▷ gesture ▷ music`, global
    and fixed; `system` is the only lane a non-user automated writer (governor, safety
    caps) may use.
17. Every stateful resolved value is a declared `.integrator` catalog entry; no other
    resolver state exists.
