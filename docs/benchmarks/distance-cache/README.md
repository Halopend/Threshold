# View-invariant distance cache experiment

Branch: `experiment/view-invariant-distance-cache`

## Design

A dense parameter lattice is not viable: `r` samples in `d` independent
parameters costs `r^d` entries (only 16 samples in 8 dimensions is already
4.3 billion entries). This prototype instead keeps a bounded LRU whose key is
the exact resolved geometry signature and whose value is a 3D world-space
field of final `mapScene` distances.

The key includes DE identity/slice, warp ops, model scale, and LOD scale. It
excludes camera pose/FOV, stereo eye, resolution, palette, and shading, so the
same field is reused while orbiting the view. The field is anchored at model
origin. At march time, `cachedDistance - voxelCircumradius * (1 + margin)`
must be positive before the exact DE is skipped.

## Initial A/B (Apple GPU, 512², bench-mandelbulb, 30 frames)

| mode | median GPU ms | FPS | exact DE evaluations/frame |
|---|---:|---:|---:|
| baseline | 1.70 | 588.0 | 4,717,066 |
| cache 96³, cold build | 19.65 | 50.9 | 2,157,778 |
| cache 96³, warm reuse | 3.25 | 307.3 | 2,157,778 |

Warm reuse removed about 54% of exact DE evaluations but was 91% slower in
GPU time. The extra random buffer read/branch on the cheap mandelbulb workload
costs more than the avoided DE calls. A follow-up that memoized the current
occupied voxel per ray measured 3.38 ms and did not help.

Resolution sweep (warm median, 20 frames): 32³ 2.28 ms, 48³ 3.29 ms, 64³
3.73 ms, 128³ 4.22 ms. None beat the 1.70 ms baseline; 32³ is the least-bad.
A 32³ extent sweep from ±2 through ±8 world units also failed to win; the
best measured extent was ±2 at 2.41 ms.

## Interpretation

Keep this as an experiment, not a shipping default. It can still become useful
for much more expensive DEs, stereo reuse, offline diagnostics, or as the
source for a lower-frequency acceleration structure. The next promising
iteration is a sparse brick/octree with a screen- or ray-coherent lookup, not
a denser global grid. Rapid geometry animation is a poor fit because the cold
build dominates.

Run `Scripts/bench-distance-cache.sh <output-directory>` to reproduce the
baseline/cold/warm split and emit a centre-slice diagnostic PNG.
