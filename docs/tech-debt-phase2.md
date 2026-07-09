# Tech-Debt Phase 2

Follow-on to the "Tech-debt phase 1" commit (`99a75e3`). Scoped from a four-axis
audit (architecture/code, concurrency, test/dependency, self-acknowledged doc
debt) run on the `debug/lockups` branch.

**Health baseline:** the codebase is unusually clean — 1 TODO, zero external
package dependencies, Swift 6 tools, ~587 tests. This is *prioritizing
deliberate deferrals*, not cleaning up rot. Dependency debt is effectively nil
(the only cost is a high Xcode 26 / visionOS 26 toolchain floor).

Priority = (Impact + Risk) × (6 − Effort), each scored 1–5.

## Ranked backlog

| # | Item | Category | Imp | Risk | Eff | Pri | Status |
|---|------|----------|----:|-----:|----:|----:|--------|
| 1 | GPU render tests **skip-not-fail** off Apple-silicon (63 tests green-but-blind) | Test | 3 | 4 | 1 | 35 | open |
| 2 | CI **does not run golden or perf suites** despite claiming to; scripts local-only | Infra | 4 | 4 | 2 | 32 | open |
| 3 | **H1: `CommandMailbox.publish` grows its ring under the lock** on the cross-thread hot path — priority inversion / unbounded memory when the render thread wedges | Concur | 4 | 5 | 3 | 27 | partial (2a) |
| 4 | Doctrine **Invariant 15 & 8 false as written** (ADR-001 "Proposed" but asserted as law; external DEs silently compute-only) | Docs | 2 | 3 | 1 | 25 | open |
| 5 | **H2: `InteractiveSession.stop()` blocks the main thread up to ~10s** and leaks the render thread on timeout | Concur | 3 | 3 | 2 | 24 | acceptable — see note |
| 6 | **Golden suite 75% unrecorded** (3 of 12 scenes) — pixel regressions on 9 scenes undetected | Test | 3 | 3 | 2 | 24 | open |
| 7 | **H4: `CompositorSession`** (visionOS) has no thread join, unbounded waits, strong-self teardown, zero watchdog instrumentation | Concur | 3 | 4 | 3 | 21 | fixed (2a) |
| 8 | **RaymarchCore.metal: 4 near-duplicate march kernels** + 438 magic literals; binding block copied 4× | Arch/Code | 4 | 4 | 4 | 16 | open |
| 9 | **`ModulationEngine` ~15 hand-aligned parallel arrays** (missed array = silent corruption); 193-line `resolve()` | Arch/Code | 3 | 4 | 4 | 14 | open |
| 10 | **`SessionCore` god-object** (~12 responsibilities, ~30 stored props, 130-line command switch) | Arch | 3 | 3 | 4 | 12 | open |

**Below the line (real, lower ROI):** `Panels.swift` bucket file + hardcoded
param-key groups that defeat the catalog; `ModulationPanels` duplicated card
scaffolding + Hz math leaking into views; provisional `BindingEngineShim` test
(blocked on Core); visionOS `app-build` non-gating in CI; `@unchecked Sendable`
× ~15 sites; `SignalTable` seqlock (works, but any change is high-risk);
`THRESH_SLOT_SHADOW_SOFT` dead slot.

## Two standing flags

- **Perf baseline is already under its own goal:** `bench-results/history.csv`
  shows 2048² at **69.3 fps vs the 70 fps target** ("debug-lockups freeze
  hardening baseline"). With #2 (perf gate not in CI) this regresses silently.
- **`RenderWatchdog` is diagnostics, not a fix** — by honest design. It logs a
  stalled frame index and takes no corrective action, and (before phase 2a) was
  wired only on macOS/iOS. The actual hang mitigations live in the bounded
  `inflight` wait + drop, `CommandBufferHealth`, and `stop()`'s bounded joins.

## Phased remediation

### Phase 2a — concurrency (this branch, `debug/lockups`)

- **H1 (partial):** bound `CommandMailbox` growth with a hard cap + a loud
  one-time fault so a wedged render thread leaves a diagnostic trail instead of
  growing memory without limit. The full allocation-free / lock-free publish
  (ADR-004 action item 2) remains open — a larger rewrite deliberately not
  rushed on a debugging branch.
- **H4 (fixed):** give `CompositorSession` a joinable teardown — a `finished`
  semaphore + bounded `stop()` join mirroring `InteractiveSession`, so visionOS
  teardown is deterministic and the render thread cannot outlive the session
  silently.
- **H2 (assessed, no change):** already bounded (5s + 5s) and well-documented;
  it degrades loudly (fault log + thread-leak-not-crash). Moving the join off
  the main thread changes app-teardown semantics for marginal gain and is not
  worth the risk on this branch. Revisit if a real teardown beachball is
  observed.
- TSan/ASan schemes exist; adding the ARM-ordering litmus tests ADR-004 lists as
  open is the natural next step.

### Phase 2b — CI hardening (highest ROI/effort)

- #1: assert `GPU.available` in CI so the 63 render tests fail-not-skip.
- #2: wire `Scripts/golden-suite.sh` + `bench-suite.sh` into CI with the fps
  gate (closes the "already failing, nobody notices" gap).
- #4: amend Invariant 15/8 in ARCHITECTURE.md §10 + PLAN.md; mark ADR-001
  superseded by ADR-006. Zero perf risk.

### Phase 2c — correctness-coupling refactors (opportunistic)

Do #8 and #9 *when next touching those files* — both attack silent-corruption
coupling (4 drifting kernels; hand-aligned parallel arrays), not just
readability. Extract a shared `marchPixel()` helper and a `SlotTable` value
type. #6 (record the 9 missing goldens) pairs with #8.

### Backlog (track, don't schedule)

`SessionCore`/`Panels` splits (#10 — mechanical, low risk, incremental) and the
ADR-006 deferred perf-lever list (SkipVolume A/B, bounding-sphere early-out,
Jacobian normals, MTLBinaryArchive) — roadmap, already well-documented.
