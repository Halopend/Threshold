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
| `kleinian`                  | kleinian                                     | pending — renders blank¹ |
| `mandelboxSphereProjection` | mandelbox-sphere-projection, boxflower2      | pending — blank at defaults¹ |

**Goldens are intentionally not recorded yet** (as of 2026-07-06):

- The three existing goldens (classic-box, default-bulb, warped-bulb) predate
  the color/tonemap pipeline work and now **mismatch** current output — the
  *geometry* is pixel-identical and deterministic, only the shading shifted.
  They are left as-is until the color pipeline settles; refresh them with
  `--update all` once it does, and the suite goes green.
- ¹ `kleinian` and `mandelboxSphereProjection` render pure black at their
  default parameters in the current build (GPU DE shape-fix pending; the
  "MSP scenes still black" bug). `boxflower2` shows MSP *is* fine with other
  params. Their scene inputs are staged here so recording a golden is a
  one-liner (`--update kleinian`) the moment their shaders render a surface —
  re-check the staged camera framing then.
