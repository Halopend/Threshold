# Warp op semantics — the normative spec

This document defines the exact math for every `ThreshWarpKind`. The CPU reference
(`ThresholdShaderIR/ReferenceOps.swift`) and the MSL interpreter
(`ThresholdRender/MSL/RaymarchCore.metal`) BOTH implement this document,
independently, and are cross-checked by sampled-equivalence tests. If either
implementation disagrees with this document, the implementation is wrong. If this
document is wrong, change it and both implementations in one commit.

Notation: `p` is the sample point entering the op, `s = strength`, `a`/`b` are the
op payload float4s. `lerp(x, y, t) = x + (y-x)t`. All angles radians.

## The two op classes

- **Point ops** (`kind < 64`) transform `p` before the DE runs. Applied in stack
  order: `p₀ → op₁ → op₂ → … → p'`.
- **Distance ops** (`kind ≥ 64`) transform the resolved SDF value `d` after the DE
  runs, and receive the ORIGINAL world-space point (pre-point-ops) — a hand is at a
  world position; it must not be dragged through the folds.

Pipeline per march step:

```
(p', dScale) = applyPointOps(worldP, ops)
d = de_main(p', ctx).x / dScale
d = applyDistanceOps(worldP, d, ops)
```

## Distance-scale accumulation (`dScale`)

Sphere tracing requires the returned distance to be a LOWER bound on true distance.
A point op `T` with local expansion `|T'|` makes `de(T(p))` change up to `|T'|`× as
fast, so the estimate must divide by the accumulated expansion. Each op multiplies
the running `dScale` (initialized 1.0) by its local expansion factor, evaluated at
its input point:

- Isometric ops (reflections, rotations, folds at full strength): factor 1 — skip.
- Conformal ops (uniform scale, sphere inversion): factor is exact.
- Non-conformal ops (twist, bend, ripple, tube fold, sphere project): factor is a
  local Lipschitz estimate — an approximation. The global `stepSafety` param
  (reserved slot 2, default 0.9) multiplies the final step length to absorb the
  approximation error. This is the standard practice in shipping fractal renderers.
- Contractions (factor < 1) are clamped to 1: contraction only makes the estimate
  more conservative, never wrong.

Rule: `dScale *= max(1, factor)` for Lipschitz-bounded ops; conformal ops use the
exact factor (which may legitimately be < 1: sphere inversion inside the sphere
shrinks distances and the estimate must shrink with it — do NOT clamp conformal
factors).

## Common helpers

```
// Deterministic perpendicular to unit axis n:
perpOf(n) = normalize(cross(n, |n.y| < 0.9 ? (0,1,0) : (1,0,0)))

// Rotation of v around unit axis n by angle t (Rodrigues):
rot(v, n, t) = v cos t + cross(n, v) sin t + n dot(n, v)(1 - cos t)

// Polynomial smooth min/max (IQ), k > 0:
smin(x, y, k): h = max(k - |x - y|, 0) / k;  min(x, y) - h²k/4
smax(x, y, k) = -smin(-x, -y, k)
```

Payload vectors named `axis` are stored unnormalized; implementations normalize on
read and treat near-zero axes (|axis| < 1e-6) as +Y.

## Point ops

### 1 Twist — `a.xyz` axis n̂
Screw around n̂, angle proportional to axial coordinate.
```
t   = dot(p, n̂)
p'  = rot(p, n̂, s·t)
r⊥  = length(p - n̂·t)
dScale *= max(1, sqrt(1 + (s·r⊥)²))
```

### 2 Bend — `a.xyz` axis n̂
Bow around n̂; bending coordinate is along the deterministic perpendicular.
```
ĉ  = perpOf(n̂)
θ  = s · dot(p, ĉ)
p' = rot(p, n̂, θ)
r⊥ = length(p - n̂·dot(p, n̂))
dScale *= max(1, sqrt(1 + (s·r⊥)²))
```

### 3 Ripple — `a.xyz` axis n̂, `a.w` frequency f
Sinusoidal displacement along n̂ driven by the perpendicular coordinate.
```
ĉ  = perpOf(n̂)
p' = p + n̂ · s · sin(f · dot(p, ĉ))
dScale *= 1 + |s·f|
```

### 4 Mirror — no payload
Fold into the positive octant. `s` blends.
```
p' = lerp(p, abs(p), s)        // s = 1 in practice; blend is for transitions
```
Isometric at s = 1.

### 5 BoxFold — `a.x` limit L; flag OPTION_A = Hall of Mirrors
Classic Mandelbox fold, per axis:
```
folded = clamp(p, -L, L)·2 - p
p' = lerp(p, folded, s)
```
Hall of Mirrors (flag set): mirrored infinite repeat instead, per axis:
```
folded_i = |mod(p_i + L, 4L) - 2L| - L      // triangle wave, period 4L, range [-L, L]
```
Isometric at s = 1 (piecewise reflection). No dScale term (|1-2s| ≤ 1 for s ∈ [0,1]).

### 6 PlaneFold — `a.xyz` normal n̂, `a.w` distance dist
Reflect points behind the plane `dot(p, n̂) = dist`.
```
h = dot(p, n̂) - dist
if h < 0:  p' = lerp(p, p - 2h·n̂, s)
```
Isometric at s = 1.

### 7 Kaleidoscope — `a.x` segment count N (≥ 1)
Fold the polar angle of p.xz into one wedge of width 2π/N.
```
θ  = atan2(p.z, p.x);  r = length(p.xz)
w  = π/N
θf = |mod(θ + w, 2w) - w|
θ' = lerp(θ, θf, s)
p'.xz = r·(cos θ', sin θ');  p'.y = p.y
```
Isometric at s = 1.

### 8 Coxeter — `a.x` = P, `a.y` = Q (the {P,Q} symbol, integers ≥ 2 as floats)
Rank-3 reflection group fold. Mirror normals derived from the Gram matrix
(m₁₂ = P, m₁₃ = 2, m₂₃ = Q):
```
n₁ = (1, 0, 0)
n₂ = (-cos(π/P), sin(π/P), 0)
n₃ = normalize( (0, -cos(π/Q)/sin(π/P), sqrt(max(ε, 1 - (cos(π/Q)/sin(π/P))²))) )
```
The explicit `normalize` is load-bearing: for Euclidean/hyperbolic symbols
(1/P + 1/Q ≤ 1/2, e.g. {5,4}) the inner term exceeds 1, the ε-clamp yields a
non-unit vector, and a non-unit mirror makes the reflection expansive — the
fold loop diverges. Normalized, the fold is the true {P,Q} group on the
spherical domain and a deterministic, isometric (safe) fold outside it.
Fold: iterate up to 24 times: for each nᵢ, if `dot(p, nᵢ) < 0` reflect
`p -= 2·dot(p, nᵢ)·nᵢ`; stop early when all three dots ≥ 0. Then
`p' = lerp(p_in, p_folded, s)`. Isometric at s = 1.

### 9 MengerFold — no payload
```
q = abs(p), components sorted descending (q.x ≥ q.y ≥ q.z)
p' = lerp(p, q, s)
```
Isometric at s = 1 (reflection + coordinate permutation).

### 10 OffsetFold — `a.xyz` crease center c
Mirror fold whose crease is shifted off-origin:
```
p' = lerp(p, abs(p - c) + c, s)
```
Isometric at s = 1.

### 11 SphereFold — `a.x` minRadius mR, `a.y` fixedRadius fR
Mandelbox sphere fold:
```
r² = dot(p, p)
factor = fR²/mR²          if r² < mR²
       = fR²/r²           if r² < fR²
       = 1                otherwise
k  = lerp(1, factor, s)
p' = p·k
dScale *= k               // conformal in each region — exact, unclamped
```

### 12 SphereInvert — `a.x` radius R
Conformal inversion through the sphere.
```
r² = max(dot(p, p), 1e-12)
k  = lerp(1, R²/r², s)
p' = p·k
dScale *= k               // conformal — exact, unclamped
```

### 13 TubeFold — `a.x` innerR mR, `a.y` outerR fR
SphereFold restricted to the XZ plane:
```
r² over p.xz only; same factor rule as SphereFold; k = lerp(1, factor, s)
p'.xz = p.xz·k;  p'.y = p.y
dScale *= max(1, k)       // non-conformal (in-plane only) — Lipschitz, clamped
```

### 14 Shells — `a.x` spacing t (> 0)
Fold radius to the nearest concentric shell (triangle wave, period 2t):
```
r  = length(p);  r' = |mod(r, 2t) - t|
k  = lerp(1, r'/max(r, 1e-9), s)
p' = p·k
```
Radial folding is piecewise isometric; tangential factor r'/r ≤ 1 is a
contraction. No dScale term.

### 15 ScaleRepeat — `a.x` factor k (> 1)
Log-radial Droste: map p into the shell [1, k).
```
r = length(p);  n = floor(log(max(r, 1e-9)) / log(k))
m = k^(n·s)                 // strength scales the exponent
p' = p/m
dScale *= 1/m               // conformal (uniform scale) — exact, unclamped
```
(Note 1/m: p' = p·(1/m) is a uniform scale by 1/m, so expansion factor is 1/m;
for r > 1, m > 1 → the estimate GROWS, which is the point of Droste zoom.)

### 16 Tiling — `a.x` cell size c, `b.xyz` per-axis mask (≥ 0.5 = axis enabled)
Infinite lattice repeat, per enabled axis:
```
p'_i = mod(p_i + c/2, c) - c/2   (enabled axes; others pass through)
p'   = lerp(p, p', s)
```
Isometric at s = 1.

### 17 Scale — `a.x` factor k (> 0)
Uniform domain scale (IFS glue step):
```
m  = lerp(1, k, s)
p' = p/m
dScale *= 1/m             // conformal — exact, unclamped
```

### 18 SphereProject — `a.x` shell radius R
Radial compression toward the sphere shell:
```
r  = length(p);  r' = lerp(r, R, s)
p' = p · r'/max(r, 1e-9)
dScale *= max(1, r'/max(r, 1e-9))   // Lipschitz, clamped
```

## Distance ops (receive world-space p and the post-DE distance d)

`|s|` is the effect amount; where sign matters it is noted.

### 64 HandAttract — `a.xyz` center c, `a.w` radius R; `b.x` ballScale,
`b.y` blendSoftness, `b.z` pocketSize, `b.w` pocketSoftness; flag OPTION_A = pocket
```
sphere = length(p - c) - R·b.x
k      = max(b.y, 1e-4)
s > 0 (attract):  d' = lerp(d, smin(d, sphere, k), s)
s < 0 (repel):    d' = lerp(d, smax(d, -sphere, k), -s)
s = 0:            d' = d
Pocket (flag set AND s > 0):
  pocket = length(p - c) - R·b.z
  d' = lerp(d', smax(d', -pocket, max(b.w, 1e-4)), s)
```

### 65 ForearmCarve — `a.xyz` capsule start, `b.xyz` capsule end, `a.w` radius,
`b.w` blendSoftness. ALWAYS subtractive; there is no sign field, structurally.
```
pa = p - a.xyz; ba = b.xyz - a.xyz
h  = clamp(dot(pa, ba)/max(dot(ba, ba), 1e-9), 0, 1)
cap = length(pa - ba·h) - a.w
d' = lerp(d, smax(d, -cap, max(b.w, 1e-4)), |s|)
```

### 66 Bounding — reserved (clip/fog op; not implemented in Phase 2)

## Simplifier contract (port of the shipping rules — exact fusion ONLY)

Adjacent-only, applied repeatedly until fixpoint:

1. **Drop no-ops**: strength == 0, or kind == None.
2. **Coalesce idempotent adjacent duplicates** at FULL strength (s == 1) with
   identical payloads: Mirror and ScaleRepeat only. (The shipping app also
   coalesced Shells, but under THIS document's Shells formula a double
   application is the identity on the fundamental domain — an involution, not
   idempotent — so the rule is mathematically false here and is excluded.)
3. **Sum adjacent parallel Twists**: same normalized axis (dot of normalized axes
   > 1 - 1e-6): strengths add, single op remains.

Load-bearing EXCLUSIONS — never coalesce: Kaleidoscope and BoxFold (look idempotent
but are not), Coxeter (not exactly idempotent when non-convergent). No approximate
rules, ever. Any new rule must come with a sampled-equivalence proof test.

## March defaults (reserved engine slots)

| Slot | Param | Default |
|---|---|---|
| 0 | maxSteps | 256 |
| 1 | maxDist | 64.0 |
| 2 | stepSafety | 0.9 |
| 3 | iterations (DE) | 12 |
| 4 | aoStrength | 0.5 |
| 5 | shadowSoft | 8.0 |

Ray generation: NDC x,y ∈ [-1, 1] (y up), aspect = width/height, camera looks down
-Z in its local frame:
```
dir_local = normalize( (ndc.x·aspect·fovTan, ndc.y·fovTan, -1) )
dir_world = quatRotate(camQuat, dir_local)
```
Hit epsilon: `epsilonBase · modelScale · t` (distance-proportional), where t is
current ray distance. March: `t += d · stepSafety` with `d` the fully corrected
estimate from the pipeline above.
