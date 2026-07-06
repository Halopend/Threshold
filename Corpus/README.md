# Corpus — golden scenes and reference images

- `scenes/` — canonical `.threshscene` files rendered per-commit (plan §9).
- `golden/` — byte-golden PNGs for `scenes/`, rendered on Apple silicon
  (M-family GPU). Byte-compare is valid within one GPU family; across
  families use a perceptual compare (not yet implemented).
- `legacy/` — (pending) scenes exported from the shipping app, replayed
  through the migration table per commit (ADR build-order Phase 0; capture
  them while the old app still runs — see PLAN.md §7.3's cautionary tale).

## Running the gate

`Scripts/golden-suite.sh` renders every `scenes/*.threshscene` at 512²
through the deterministic headless renderer and byte-compares each against
its `golden/<name>.png` when one exists:

```
Scripts/golden-suite.sh              # build + gate every scene
Scripts/golden-suite.sh --no-build   # reuse an existing .build/debug binary
Scripts/golden-suite.sh --update NAME # (re)record golden/NAME.png
Scripts/golden-suite.sh --update all  # re-record every golden that exists
```

Result classes: `MATCH` / `MISMATCH` (fails the suite) / `ERROR` (fails) /
`PENDING` (no golden yet — reported, not a failure). A `PENDING` scene that
renders near-empty is tagged `EMPTY?` (its DE produces no surface in this
build). Single-scene ad-hoc equivalents of what the script runs:

```
swift build --build-system native --product threshold-render
.build/debug/threshold-render Corpus/scenes/<name>.threshscene --out Corpus/golden/<name>.png   # record
.build/debug/threshold-render Corpus/scenes/<name>.threshscene \
    --out /tmp/<name>.png --compare Corpus/golden/<name>.png                                     # gate (exit 2 on mismatch)
```

## Coverage (7 built-in fractal types, `DERegistry.builtin`)

| Fractal type (DE key)       | Scene(s)                                    | Golden |
|-----------------------------|---------------------------------------------|--------|
| `mandelbox`                 | classic-box, bench-mandelbox                 | classic-box (STALE) |
| `mandelbulb`                | default-bulb, warped-bulb, crinkle           | default-bulb, warped-bulb (STALE) |
| `mengerSponge`              | menger-sponge, colorful spheres              | pending |
| `quaternionJulia`           | quaternion-julia                             | pending |
| `mandelbulbJulia`           | mandelbulb-julia                             | pending |
| `kleinian`                  | kleinian (off-axis camera¹)                  | pending |
| `mandelboxSphereProjection` | mandelbox-sphere-projection (bubble on²), boxflower2 | pending |

**Goldens are intentionally not recorded yet** (as of 2026-07-06):

- The three existing goldens (classic-box, default-bulb, warped-bulb) predate
  the color/tonemap pipeline work and now **mismatch** current output — the
  *geometry* is pixel-identical and deterministic, only the shading shifted.
  They are left as-is until the color pipeline settles; refresh them with
  `--update all` once it does, and the suite goes green.

All 7 scenes now render (verified by the suite — no `EMPTY?` rows). Two of them
needed non-default scene setup, and NEITHER is a shader/CLI bug — the DE math
is correct (the DE-equivalence tests pass) and the CLI feeds the march
identically to the Mac GUI:

- ¹ `kleinian` (Knighty's pseudo-Kleinian) is **space-filling**: a dead-on
  `[0,0,z]` camera sits on the folds' symmetry axis where the DE stays
  sub-threshold and every ray *creeps* (renders black at any distance). An
  **off-axis** camera breaks that degeneracy and it renders. This is also why
  `CameraDTO.default` was moved off-axis (SceneEnvelope.swift) so a fresh pick
  / reset is never black.
- ² `mandelboxSphereProjection`'s once-applied sphere projection has a genuine
  r→0 singularity near the origin, so the DE explodes and rays 1-step-miss.
  Enabling the **safety bubble** (`engine.bubble.enabled=1`) carves that region
  out and it renders — at ANY `projBlend` (Blue hero renders at 0.98). The bare
  `--de mandelboxSphereProjection` (bubble off by default) is still black; a
  scene must turn the bubble on, as this one and the legacy MSP scenes do.
