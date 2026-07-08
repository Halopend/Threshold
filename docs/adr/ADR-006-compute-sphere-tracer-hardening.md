# ADR-006: Compute-sphere-tracer hardening — ratify the two-shell reality and phase the optimization campaign

**Status:** Proposed
**Date:** 2026-07-07
**Deciders:** Jean (solo) — sign-off = merging this doc
**Relates to:** ADR-001 (compute-only raymarch — this ADR amends it), ADR-003 (system
lane), ARCHITECTURE.md §4/§6/§10 (Invariant 15), PLAN.md §6/§13; `perf-notes.md`,
`perf-port-audit.md`.

## Context

We chose to prioritize **hardening the compute sphere-tracer** as the project's next
direction. A structured analysis pass across ten lenses (foveation, march loop,
skip-volume, temporal reconstruction, occupancy/specialization, visionOS compositor,
quality governor, perf measurement, numerical robustness, invariants) produced one
consistent conclusion — *the march core is already near its textbook ceiling* — and
surfaced three structural facts that must be decided **before** any optimization work,
because they determine what "hardening" even means here.

1. **ADR-001's "compute-only, one shell" is false as shipped.** The shipping visionOS
   backend is the *fragment* shell with hardware foveation, not compute:
   `RenderBackend.fragment` is the default and gets `rasterizationRateMap` +
   compositor foveated upscaling for free (`CompositorSession.swift:88-102`, `:138-140`;
   `ViewPass.swift:516-518`; `Settings.swift:40-43`), and `perf-notes.md:565-570`
   records the on-device DECISION that fragment+foveation *is* the visionOS backend with
   compute retained only as an A/B instrument. Meanwhile ADR-001 is still
   **Status: Proposed** with both foveation action items unchecked
   (`ADR-001:86-92`), and **Invariant 15** ("exactly one march shell family (compute)",
   `ARCHITECTURE.md:348`) is therefore *false as written*. The doctrine and the app
   disagree, and the app is right.

2. **The measurement substrate is partially blind — we cannot yet optimize safely.**
   Wall/GPU timing is sound (`gpuEndTime − gpuStartTime`, warm-up + 260 frames), but
   the load-attributable metric is *off* in exactly the gated runs: the in-kernel step
   counter (`RaymarchCore.metal:1627`) is disabled without `--stats`
   (`main.swift:355`), so `bench-results/last-2048.json` records `"totalSteps": 0`.
   There are **no GPU counters anywhere** (occupancy / ALU-vs-memory limiter), and the
   "~70% ALU-bound" premise driving the plan is inherited from *legacy* numbers, never
   re-measured on this kernel (`perf-port-audit.md:33`). The perf gate is a single
   absolute FPS floor at 2048² only (`bench-suite.sh:87-94`); no variance, no thermal
   flag, single DE. And the *actual optimized path* (skip / cone / lod-falloff /
   fast-math) is **off in the golden library**, while CPU↔GPU equivalence tests sample
   **exterior points only** (`DEEquivalenceTests.swift:7-12`) — so the fast path is
   untested for correctness in the near-surface band where its artifacts appear.

3. **The one genuinely open march lever — `SkipVolume` — has never been measured, and
   as built cannot win.** It is clean, conservative, and correctly rebuilt every frame
   (so live modulation is safe), but **no A/B has ever been recorded** (nothing in
   `bench-results/` or `.bench-history/` references it), and it forces the *slow*
   generic dynamic-dispatch march while gating *out* the cone prepass
   (`OffscreenRenderer.swift:126,138,198`) — discarding wins the benches already prove.
   Its only datum is a unit test's "~14% of DE evals shed" on mandelbulb head-on, with
   mandelbox / warped-bulb / kleinian skipping **zero** (`SkipVolumeTests.swift:76-79`).

For contrast, the levers people *expect* to be missing are already shipped and tuned:
Keinert over-relaxation with per-DE ω caps + a retreat guard
(`RaymarchCore.metal:1449-1455`, `DERegistry.swift`), a hierarchical cone prepass
(`march_cone_prepass`, `RaymarchCore.metal:1670`), cone-proportional hit epsilon,
reduced-iteration normals/AO, direct-call DE inlining via specialization, MetalFX
temporal upscaling, and a stable AIMD quality governor. The remaining march wins are
single-digit-% cleanup — the real frontier is elsewhere.

## Decision

Hardening proceeds under five decisions.

### 1. Ratify the two-shell reality (amend, don't restore, Invariant 15)

Invariant 15 becomes: **"There is exactly one march *core* (`marchShade`). Presentation
is either a compute shell (harness, Mac/iPad blit, visionOS A/B) or a foveated-fragment
shell (the shipping visionOS path)."** ADR-001 is marked *superseded-amended* by this
ADR. The anti-divergence guarantee ADR-001 wanted does **not** come from "one shell" —
it comes from the shared core + the CI-enforced `RenderFeatureTable`
(`RenderFeatures.swift:22-34`) + `CompositorParityTests.fragmentMarchMatchesComputeMarch`
(raster ≡ compute on Mac). Those three stay load-bearing and non-negotiable; the "one
shell" framing was a proxy for them that shipping reality already broke.

### 2. Re-justify the compute backend as R&D substrate, not shipping path

Compute is **not** the shipping visionOS renderer and we stop pretending it is. It is
retained, flag-gated, as the substrate for the two compute-native wins fragment
structurally cannot reach: **stereo reprojection** and **manual (rate-map-sampled)
foveation**. If neither lands, compute is demoted to a device A/B instrument. This
resolves the retire-vs-invest tension explicitly: keep it, but it must *earn* its parity
tax by delivering a win fragment can't.

### 3. Close the real Invariant-8 gap (external DEs on the raster path)

The genuine "feature on only one path" violation is not the shell choice — it is that
**external/embedded DEs render only on compute**; the shipping raster path is built-ins
only (`RenderFeatures.swift:68-69`, `requiredOnAll:false`). Decision: **document
embedded-DE-on-shipping-visionOS as unsupported now** and encode it honestly in the
feature table; schedule the fragment linked-functions pipeline *only* when external-scene
sharing becomes a priority (consistent with the project's "don't build speculatively"
ethos). What we do **not** do is leave it silently divergent.

### 4. Measurement is a blocking prerequisite (Phase 0)

No lever is enabled by default until: (a) per-run **ns/step** is restored in gated runs
(via a separate atomic-on pass — the timing pass stays atomic-free to avoid contention
skew); (b) **GPU counters** are captured *once* to confirm or refute the ALU-bound
premise on this kernel; (c) the bench gate carries **stddev/CoV + `thermalState` +
a multi-resolution baseline-delta**, not just the 2048² absolute floor. Every downstream
keep/cut — SkipVolume first — depends on this.

### 5. Phased campaign, gated (see Action Items)

Off-by-default, function-constant-gated levers on the *one* kernel are safe-and-first.
Anything that moves generic-`.safe` pixels, widens the ABI, or forks a shell is gated,
separately rebaselined, and last. The golden regime **forks**: the byte-exact
generic-`.safe` 512² gate stays as-is, **and** a new perceptual golden set covers the
levers-on / warp-heavy / near-silhouette path — otherwise the fast path ships untested.

## Options Considered

### Option A: Ratify two shells + measurement-gated phased hardening (chosen)

**Pros:** the doc matches the shipping app, so CI asserts something true; keeps the
compositor's hardware foveation (device-validated) as the shipping path; preserves the
biggest future visionOS win (stereo reprojection) by keeping compute; every lever lands
behind an existing guard pattern (function constant + feature table + golden). **Cons:**
two shells remain a real parity surface; the golden regime forks into byte-exact +
perceptual; "compute must earn its keep" is a standing obligation, not a closed decision.

### Option B: Hold ADR-001 as written — recover foveation inside compute to make it the true single path

**Pros:** restores Invariant 15 literally; one shell, one feature matrix.
**Cons:** `[ROI: L | Effort: H | Risk: H]` by every analysis lens — a software foveated
upsample rarely matches the compositor's built-in one, still pays two blit copies
(drawables aren't compute-writable), and by the team's own honest expectation fragment
already *wins*. This optimizes toward the losing path to satisfy a doc. Rejected.

### Option C: Retire the compute backend entirely — fragment everywhere

**Pros:** kills the dual-path parity tax outright; one shipping shell.
**Cons:** forfeits stereo reprojection (the single biggest visionOS win, ~halves per-eye
march cost) and manual foveation — both compute-native; and it breaks the property that
Mac/harness goldens (rendered through the offscreen/compute path) validate the visionOS
*visual* path. Too much upside surrendered for a tax three existing mechanisms already
bound. Rejected.

## Trade-off Analysis

- **Parity tax is real but already bounded.** ADR-001 feared unbounded dual-path drift;
  in practice it is fenced by the shared core, the feature table, and the parity test.
  Keeping those three honest is cheaper than either reinventing hardware foveation
  (Option B) or forfeiting stereo reprojection (Option C).
- **Ratify > restore.** Amending Invariant 15 trades doctrinal purity for honesty. A
  literally-restored "one shell" invariant would remain false the moment the app runs;
  an amended one is enforceable by the tests that actually guard divergence.
- **Measurement-first is the highest-leverage half-day in the plan.** It is the
  difference between optimizing a confirmed ALU-bound kernel and optimizing a black-box
  wall-time proxy — and it is a hard prerequisite for the SkipVolume keep/cut, which is
  otherwise faith-based.
- **Fork the goldens deliberately.** The byte-exact gate is what makes the harness
  trustworthy; the perceptual gate is what makes the *fast path* trustworthy. Collapsing
  them (either direction) loses one of those guarantees.

## Consequences

- **Easier:** the shipping visionOS path is now the documented path; every new lever has
  a phasing home, a gate, and a golden strategy; the SkipVolume keep/cut becomes a
  measured decision instead of a standing question.
- **Harder:** two shells persist — justified, but someone must keep the parity test +
  feature table green; the compute backend now carries an explicit "deliver stereo
  reprojection or be demoted" obligation; two golden sets (byte-exact + perceptual) must
  be maintained.
- **New private-buffer discipline continues:** per-frame accelerator state rides private
  buffer contracts outside the ABI (aux buffer 7, skip buffers 9/10) rather than
  widening `FrameUniforms` / `WarpOp` — the ABI stays frozen (`THRESHOLD_ABI_VERSION`,
  48-byte WarpOp `_Static_assert`s) unless Phase 4 forces a bump.

## Action Items

**Phase 0 — Instrument (blocking; nothing ships to default until these land)**
1. [ ] Restore per-run **ns/step** in gated bench via a separate atomic-on pass; keep the
   timing pass atomic-free (`RaymarchCore.metal:1627`, `main.swift:355`).
2. [ ] Capture **GPU counters once** (occupancy, ALU-vs-memory limiter) to validate/refute
   the ALU-bound premise on *this* kernel; record in `perf-notes.md`.
3. [ ] Add **stddev/CoV + `ProcessInfo.thermalState` + multi-resolution baseline-delta** to
   the gate; stop always measuring 2048² last/warmest (`bench-suite.sh`).

**Phase 1 — Ratify reality (zero perf risk)**
4. [ ] Amend **Invariant 15** in `ARCHITECTURE.md §10` and `PLAN.md §13`; mark
   `ADR-001` *superseded-amended* by this ADR.
5. [ ] Document **external-DE-on-shipping-raster as unsupported** in the feature table
   (or schedule the fragment linked-functions fix if sharing is prioritized).

**Phase 2 — Safe, golden-neutral levers (function-constant-gated, off by default)**
6. [ ] Run + record the **SkipVolume A/B** (`--skip-volume/--skip-grid/--skip-dense`); make
   it **compose** with the specialized static-dispatch + cone-prepass path (drop the
   `program==nil` / `!useSkip` exclusivity) — else keep it off.
7. [ ] **ω re-arm after retreat**; `hasBoundingOps` DCE gate; **ring-buffer** the per-frame
   param/ops buffers on the visionOS critical path; **cap** the `iterations`/`maxSteps`
   variant-cache leak (LRU / discretize).

**Phase 3 — Guarded levers (changes goldens → rebaseline + visual review)**
8. [ ] Per-callsite `precise::` pins on escape / `|z|/dr` / `atan2` so **fast-math becomes
   shippable** instead of golden-breaking; expand the golden corpus to warp-heavy +
   near-silhouette + levers-on; *then* enable higher ω / cone / skip by default.

**Phase 4 — Speculative bets (device numbers required before default)**
9. [ ] **Stereo reprojection** on the compute backend (one-eye march + depth reproject +
   disocclusion re-march); add stereo goldens. This is the test of Decision 2.
10. [ ] **Volatility-driven history rejection** + custom visionOS `temporal_resolve`
    (morph ghosting from camera-only motion vectors, `RaymarchCore.metal:1642-1657`);
    governor input-EMA + a stability/no-oscillation test.
