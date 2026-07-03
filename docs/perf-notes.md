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
