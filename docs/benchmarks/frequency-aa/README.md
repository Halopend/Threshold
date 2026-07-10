# 3D frequency-guided AA experiment

Branch: `experiment/volume-frequency-aa`

## Method

This is deliberately independent of the distance-cache experiment. For one
exact resolved geometry signature, it builds a model-origin-anchored 3D grid
of `mapScene` distances and convolves it with a 3D Sobel kernel plus a
six-neighbour Laplacian. The metric is `abs(|∇d|-1) + 0.5*|∇²d|`: smooth SDF
space tends toward zero, while folds, curvature, and under-resolved distance
changes become bright.

The primary ray looks up that scalar at its closest surface approach. Only a
cell above the configured threshold receives two symmetric 0.28-pixel rays;
their colors are averaged with the primary sample. The field key excludes
camera position, orientation, FOV, resolution, palette, and shading, so view
changes reuse the build. DE selection, DE parameter slice, model scale, and
warp stack are part of the key, so geometry edits rebuild it.

`frequency-slice-64.png` is the centre XY slice of this field: black is low
activity, red/yellow is high activity, and white is the strongest candidate
area. It is a methodology diagnostic rather than a beauty render.

## 512² sweep — Apple GPU, bench-mandelbulb, 24 measured frames

| threshold | median GPU ms | change | last-frame coverage | mean RGB Δ |
|---:|---:|---:|---:|---:|
| baseline | 1.70 | — | — | — |
| 0.50 | 5.85 | +244% | 56.5% | 1.910 |
| 0.75 | 5.32 | +213% | 41.0% | 1.870 |
| 1.00 | 3.89 | +129% | 18.1% | 0.846 |
| 1.15 | 2.64 | +55% | — | 0.206 |
| **1.25** | **2.21** | **+30%** | **1.48%** | **0.052** |
| 1.35 | 2.60 | +53% | — | 0.016 |
| 1.50 | 2.10 | +23% | 0.15% | 0.007 |

The exact medians have normal GPU/thermal variance, but the sweep clearly
rejects wide coverage: three rays per pixel are not an acceleration. Threshold
`1.25` is now the conservative experiment default for this scene because it
changes only difficult pixels. It is **not** a shipping default or a general
quality claim; it needs visual evaluation per fractal and view path.

Run `Scripts/bench-frequency-aa.sh <output-directory>` to regenerate the
baseline, threshold sweep, per-threshold diagnostics, and `summary.csv`.
