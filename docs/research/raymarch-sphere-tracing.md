# Raymarching / sphere-tracing acceleration techniques

Platform-agnostic algorithmic literature. None of these numbers were
measured on Metal/Apple Silicon — they're Nvidia/AMD, OpenGL/DX12. Treat as
hypotheses to validate against Threshold's own DEs, not numbers to import
directly. See [README.md](README.md) for refuted claims and caveats.

## Terminology (three different papers, two both called "enhanced")

| Name used here | Paper | Mechanism |
|---|---|---|
| basic | Hart 1995 (coined "sphere tracing") | Step by `f(t)` (global Lipschitz bound = 1 for a proper SDF) |
| relaxed | Keinert et al. 2014, "Enhanced Sphere Tracing" | Over-relax step by constant `ω ∈ [1,2)` |
| enhanced | Balint & Csebfalvi 2018, "Enhanced Sphere Tracing" | Geometric step extrapolation under local-planarity assumption |
| auto-relaxed (AR) | Ban & Valasek 2023, "Automatic Step Size Relaxation" | Relaxation factor `β` derived from an exponential moving average — adaptive, not fixed |

Two papers both titled "Enhanced Sphere Tracing" is a real citation trap.
Ban & Valasek's paper is what disambiguates them (verified 3-0 against
primary text) — cite *that* paper when you need the naming straightened out.

## Relaxed sphere tracing (Keinert et al. 2014)

[Paper](https://www.lgdv.tf.fau.de/publications/enhanced-sphere-tracing/) — confidence: high, 3-0 verified.

- Step multiplier `ω ∈ [1,2)` applied to the SDF-bounded step — trades
  precision for speed by deliberately overshooting the conservative bound.
- Failure mode: overshoot can skip past thin features. Mitigation: a
  dynamic self-intersection-prevention check — when the over-relaxed step's
  bounding sphere becomes disjoint from the previous step's sphere, the
  march falls back to a standard (non-relaxed) step. This is the concrete
  backtrack-on-overshoot correction referenced in Threshold's plan.
- `ω` is scene-sensitive (see auto-relaxed comparison below) — a fixed,
  hand-picked value is likely to need retuning per DE/per scene.

## Enhanced sphere tracing (Balint & Csebfalvi 2018)

[Paper (PDF)](https://people.inf.elte.hu/csabix/publications/articles/eurographics-2018-shortpaper.pdf) — confidence: medium (short paper, 3 scenes, Nvidia 1080Ti, not Apple Silicon).

- Geometrically extrapolates the next step radius assuming local planarity
  of the surface; falls back to standard sphere tracing when the surface is
  locally concave.
- Cross-scene-averaged (time to reach a prescribed error threshold): beats
  basic sphere tracing after ~64 iterations, and beats Keinert et al.'s
  relaxed sphere tracing at every iteration count tested. (Verified 2-1;
  note a stronger "up to 50% better" framing of this same result was
  explicitly **refuted** — see README.)
- **Fractal caveat (important for Threshold):** on the paper's one fractal
  test case (Mandelbulb), this advantage largely disappears — enhanced,
  relaxed, and basic sphere tracing were statistically on par with each
  other. The planarity assumption that drives the win doesn't hold well on
  fractal boundary detail. This is the single most load-bearing caveat for
  applying any of this literature to Threshold's DEs — don't assume a
  win here without measuring it.

## Auto-relaxed sphere tracing (Ban & Valasek, Eurographics 2023)

[Paper](https://www.researchgate.net/publication/370902411_Automatic_Step_Size_Relaxation_in_Sphere_Tracing) — confidence: high, 3-0 verified against primary text and results table. Measured on AMD RX 5700, DX12/Falcor, 1000-iteration cap.

Concrete average frame times:

| Scene | basic | enhanced | relaxed (ω=1.2) | relaxed (ω=1.5) | AR (β=0.3) | AR (β=0.2) |
|---|---|---|---|---|---|---|
| Temple procedural | 39.39ms (125%) | 31.57ms (100%) | 33.36ms (106%) | 31.06ms (98%) | 29.79ms (94%) | 29.79ms (94%) |
| Temple discrete 1024³ | 8.50ms (112%) | 7.60ms (100%) | 7.21ms (95%) | 6.46ms (85%) | 6.19ms (81%) | 5.99ms (79%) |

- Headline: AR is 6–19% faster than "enhanced" and 4–5% faster than
  "relaxed" at a 1000-iteration cap — **but** the gain shrinks to only
  ~2–6% faster than enhanced at low iteration caps (e.g. 32 steps), which
  is the regime closer to a real-time headset per-frame budget. Don't
  expect the full headline number at Threshold's actual step budgets.
- AR's single hyperparameter `β` is markedly less scene-sensitive than
  Keinert's `ω`: best `β` values (0.2, 0.3) stayed within 2% of each other
  across all tested scenes, vs. `ω=1.2` vs `ω=1.5` differing by ~10% on one
  scene, with the optimum differing between procedural and discretized
  versions of *identical* geometry. If Threshold's warp-stack DEs vary
  widely in local Lipschitz behavior, a fixed `ω` is a worse bet than an
  adaptive scheme.

## Segment Tracing (Galin, Guerin, Paris, Peytavie — CGF/Eurographics 2020)

[Paper](https://hal.science/hal-02507361/document) (DOI 10.1111/cgf.13951, [reference implementation on GitHub](https://hal.science/hal-02507361/document)) — confidence: high, 3-0 verified.

- Generalizes sphere tracing's *global* Lipschitz bound to a *local*,
  per-candidate-segment Lipschitz bound. Step formula:
  `s(t, e_i) = min(|f(t)| / λ(e(t, e_i)), e_i)`. Directly implementable
  modification to the step function — requires only a local (not global)
  Lipschitz estimate.
- CPU test scenes (few dozen complex primitives): reduces DE evaluation
  count by 1–2 orders of magnitude vs. plain sphere tracing — Chandelier:
  22.87M → 0.09M evals; Temple: 19.74M → 0.33M. Scenes with thousands of
  simple primitives saw more (Molecule: 463.06M → 0.26M).
- GPU (OpenGL 4.3, Nvidia GeForce 2070), *unoptimized* shader: ~6 Hz → ~67
  Hz, roughly an order of magnitude, with zero shader-level optimization
  effort.
- **Negative result, and it's the relevant one for Threshold:** for
  near-uniform-density objects (roughly constant local Lipschitz), the
  wall-clock benefit was limited or even negative. A single continuous
  fractal DE is architecturally closer to this negative-result category
  than to the multi-primitive scenes that saw the 10–100× wins. Segment
  tracing's benefit for Threshold's specific DE shape is genuinely
  uncertain — needs direct measurement, not adoption on faith.
- A claim that the paper's optimal step-growth amplification factor is
  `k ≈ 2` was **refuted** (1-2) — don't cite a specific k without
  rechecking the paper directly.

## Normal estimation: tetrahedron technique

[Article — Inigo Quilez](https://iquilezles.org/articles/normalsSDF/) — confidence: high, 3-0 verified, independently corroborated.

- 4 SDF evaluations per shading point (sample offsets `{1,-1,-1}`,
  `{-1,-1,1}`, `{-1,1,-1}`, `{1,1,1}`) vs. 6 for classic central
  differences — matches forward-difference cost while keeping
  central-difference-like unbiased directional-derivative quality.
- General, non-fractal-specific, orthogonal to raymarch step-count
  optimization — a straightforward ~33% reduction in per-shading-point
  normal cost, applicable regardless of what step-acceleration scheme is
  used for the march itself.
- (A flat "central differences = 6 evals" framing was refuted on exact
  wording — 1-2 — but the 4-vs-6 comparison above is the verified claim.)

## Not covered by this pass

Cone marching, self-shadow approximation, coherent ray packets, and
spatial acceleration structures (octrees/BVH) were in scope but no primary
source was fetched/verified for them this round — see README's open
questions.
