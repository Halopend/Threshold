// TemporalResolve.metal — the reconstruction/present library.
//
// This is the SECOND runtime-compiled library, deliberately separate from
// RaymarchCore.metal: reconstruction is a PRESENTATION concern (the march-core
// invariant keeps march features in RaymarchCore), and external-DE programs
// recompile the header+core pair per program — resolve kernels concatenated
// there would recompile with every external DE for nothing. GPUContext
// prepends the same ABI header copy and builds this library LAZILY (first
// TemporalReconstructor construction), so the offscreen/CLI/bench paths that
// never reconstruct never pay the compile.
//
// ThreshReconUniforms and every binding index here are a PRIVATE contract
// with TemporalReconstructor.swift (the standing of THRESH_BUFFER_AUX = 7 in
// RaymarchCore.metal) — not part of the published ABI header. The Swift
// mirror's layout is pinned by a MemoryLayout test (ReconPresentTests).

#include <metal_stdlib>
using namespace metal;

// Uniforms for every kernel in this library, filled per pass (resolve:
// srcSize = march, dstSize = acc; present: srcSize = acc, dstSize = drawable).
// 48 bytes, 8-byte aligned.
struct ThreshReconUniforms {
    float2 srcSize;     // source dimensions for this pass, pixels
    float2 dstSize;     // destination dimensions for this pass, pixels
    float2 jitter;      // current frame's sub-pixel jitter, march pixels
    float  sharpen;     // RCAS strength [0, 1]; 0 = no sharpening
    float  tScale;      // present-from-t: far distance for the miss sentinel
                        // (Mac branch later: t/maxDist un-normalization)
    float  volatility;  // world-morph magnitude [0, 1] from the lane engine
    float  alphaBase;   // temporal blend floor
    uint   frameIndex;  // jitter/sample-pattern phase
    uint   flags;       // bit 0 = reset history this frame (octave rebase,
                        // scene epoch, history realloc)
};

constant constexpr sampler kReconBilinear(
    coord::normalized, address::clamp_to_edge, filter::linear);

// Function constants (disjoint from RaymarchCore's 0–12 block so a grep for
// an index never finds two owners):
//   20 — thresh_recon_upsample: temporal_resolve fetches current samples
//        through Catmull-Rom + sample-distance confidence (TAAU: acc res >
//        march res). False = 1:1 reads (stabilize: acc res == march res).
//   21 — thresh_present_from_t: recon_present derives compositor clip depth
//        from the RESOLVED hit-t (texture 1 becomes the resolve aux texture)
//        and upgrades the color filter to Catmull-Rom when upscaling. False
//        compiles the phase-0 present byte-for-byte (parity guarantee).
constant bool thresh_recon_upsample_defined [[function_constant(20)]];
constant bool THRESH_RECON_UPSAMPLE = is_function_constant_defined(thresh_recon_upsample_defined)
    ? thresh_recon_upsample_defined : false;
constant bool thresh_present_from_t_defined [[function_constant(21)]];
constant bool THRESH_PRESENT_FROM_T = is_function_constant_defined(thresh_present_from_t_defined)
    ? thresh_present_from_t_defined : false;

// Local copies of RaymarchCore's ray helpers (separate library — the header
// carries only the ABI). Drift is pinned by TemporalResolveTests: present
// depth at scale 1 must match the march's own clip depth.
static inline float3 reconQuatRotate(float4 q, float3 v) {
    return v + 2.0f * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

static inline float3 reconViewDirLocal(float4x4 invProj, float2 ndc) {
    const float4 h0 = invProj * float4(ndc, 0.25f, 1.0f);
    const float4 h1 = invProj * float4(ndc, 0.75f, 1.0f);
    float3 dirLocal = normalize(h1.xyz / h1.w - h0.xyz / h0.w);
    if (dirLocal.z > 0.0f) { dirLocal = -dirLocal; }
    return dirLocal;
}

// Pixel center of `p` in a `size` grid → NDC (y up) — the march kernels'
// exact formula, one definition here for resolve + present.
static inline float2 reconPixelNdc(uint2 p, float2 size) {
    return float2((float(p.x) + 0.5f) / size.x * 2.0f - 1.0f,
                  1.0f - (float(p.y) + 0.5f) / size.y * 2.0f);
}

// --------------------------- color-space helpers -----------------------------

static inline float3 reconToYCoCg(float3 rgb) {
    return float3(0.25f * rgb.r + 0.5f * rgb.g + 0.25f * rgb.b,
                  0.5f * rgb.r - 0.5f * rgb.b,
                  -0.25f * rgb.r + 0.5f * rgb.g - 0.25f * rgb.b);
}

static inline float3 reconFromYCoCg(float3 c) {
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// Clip `v` into the axis-aligned box (center, extents) along the ray from the
// box center — the standard TAA AABB clip (never leaves the box, keeps hue
// better than a per-axis clamp).
static inline float3 reconClipAABB(float3 center, float3 extents, float3 v) {
    const float3 d = v - center;
    const float3 unit = d / max(extents, 1e-6f);
    const float maxUnit = max3(abs(unit.x), abs(unit.y), abs(unit.z));
    return maxUnit > 1.0f ? center + d / maxUnit : v;
}

// Catmull-Rom (A = −0.5) 9-tap fetch at `samplePos` (texel coordinates) — the
// TAA-standard sharp history/current filter; weights sum to 1, negative lobes
// preserve detail bilinear would blur away. Callers clamp the result where
// undershoot matters.
static inline float4 reconCatmullRom(
    texture2d_array<float, access::sample> tex,
    float2 samplePos, float2 size, uint slice)
{
    const float2 tc = floor(samplePos - 0.5f) + 0.5f;
    const float2 f = samplePos - tc;
    const float2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
    const float2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
    const float2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
    const float2 w3 = f * f * (-0.5f + 0.5f * f);
    const float2 w12 = w1 + w2;
    const float2 off12 = w2 / max(w12, 1e-6f);
    const float2 t0 = (tc - 1.0f) / size;
    const float2 t3 = (tc + 2.0f) / size;
    const float2 t12 = (tc + off12) / size;
    float4 acc =
          tex.sample(kReconBilinear, float2(t0.x,  t0.y), slice)  * (w0.x  * w0.y)
        + tex.sample(kReconBilinear, float2(t12.x, t0.y), slice)  * (w12.x * w0.y)
        + tex.sample(kReconBilinear, float2(t3.x,  t0.y), slice)  * (w3.x  * w0.y)
        + tex.sample(kReconBilinear, float2(t0.x,  t12.y), slice) * (w0.x  * w12.y)
        + tex.sample(kReconBilinear, float2(t12.x, t12.y), slice) * (w12.x * w12.y)
        + tex.sample(kReconBilinear, float2(t3.x,  t12.y), slice) * (w3.x  * w12.y)
        + tex.sample(kReconBilinear, float2(t0.x,  t3.y), slice)  * (w0.x  * w3.y)
        + tex.sample(kReconBilinear, float2(t12.x, t3.y), slice)  * (w12.x * w3.y)
        + tex.sample(kReconBilinear, float2(t3.x,  t3.y), slice)  * (w3.x  * w3.y);
    // Negative lobes can push rgb/alpha slightly out of range on hard edges;
    // alpha is COVERAGE here (composited over passthrough) — keep both sane.
    return float4(max(acc.rgb, 0.0f), saturate(acc.a));
}

// RCAS-style contrast-adaptive sharpen (the FSR1 shape): a negative-lobe
// cross whose weight is LIMITED by how close the neighborhood already sits to
// its local extremes, so sharpening can never ring past them. Belt and
// braces, the result is clamped to the local min/max anyway — that clamp is
// what keeps later phases' temporal noise from being amplified into
// fireflies. Alpha passes through untouched (misses are transparent over
// passthrough; a sharpened silhouette would fringe).
static inline float4 reconSharpen(
    float4 e, float4 b, float4 d, float4 f, float4 h, float strength)
{
    const float3 mn4 = min(min(b.rgb, d.rgb), min(f.rgb, h.rgb));
    const float3 mx4 = max(max(b.rgb, d.rgb), max(f.rgb, h.rgb));
    const float3 hitMin = mn4 / max(4.0f * mx4, 1e-4f);
    const float3 hitMax = (1.0f - mx4) / min(4.0f * mn4 - 4.0f, -1e-4f);
    const float3 lobe3 = max(-hitMin, hitMax);
    const float lobe = max(-0.1875f, min(max3(lobe3.x, lobe3.y, lobe3.z), 0.0f))
        * clamp(strength, 0.0f, 1.0f);
    float3 rgb = (lobe * (b.rgb + d.rgb + f.rgb + h.rgb) + e.rgb)
        / (4.0f * lobe + 1.0f);
    rgb = clamp(rgb, min(mn4, e.rgb), max(mx4, e.rgb));
    return float4(rgb, e.a);
}

// Present: march-resolution color+depth arrays → output-resolution arrays.
// Bilinear color tap + RCAS; depth is a NEAREST tap (filtering depth invents
// geometry between surfaces — the compositor reprojects with it, and blocky
// beats bent). Grid: (dstW, dstH, viewCount), 8×8×1 threadgroups; dst need
// not be a multiple of 8 (bounds check below) — only MARCH textures carry the
// multiple-of-8 guarantee.
//
// THRESH_PRESENT_FROM_T variant (phase A): the source is the RESOLVED history
// pair — texture 1 is the resolve aux array (r = world hit-t, MISS = −1;
// g = sample count) instead of a clip-depth array — and depth is DERIVED per
// output pixel from the converged t through this view's projection (buffer 1),
// so the compositor reprojects converged geometry, not one jittered frame's.
// Upscaling from-t (stabilize mode) upgrades the color filter to Catmull-Rom;
// TAAU (equal sizes) keeps the direct tap. RCAS runs last in both, its
// output clamped to the cross min/max — clamp-before-sharpen is the no-
// firefly ordering the plan requires.
kernel void recon_present(
    constant ThreshReconUniforms& R                 [[buffer(0)]],
    texture2d_array<float, access::sample> srcColor [[texture(0)]],
    texture2d_array<float, access::sample> srcDepth [[texture(1)]],
    texture2d_array<float, access::write>  outColor [[texture(2)]],
    texture2d_array<float, access::write>  outDepth [[texture(3)]],
    device const ThreshViewUniforms* views          [[buffer(1),
                                                      function_constant(THRESH_PRESENT_FROM_T)]],
    uint3 gid                                       [[thread_position_in_grid]])
{
    const uint w = outColor.get_width();
    const uint h = outColor.get_height();
    if (gid.x >= w || gid.y >= h) { return; }
    const uint slice = gid.z;

    // Identity fast path: exact reads, bit-identical to a blit. The encoder
    // skips the pass entirely at scale 1 — this branch is the test seam that
    // PROVES pass-through-ness (ReconPresentTests), and the zero-sharpen
    // equal-size configuration behaves as documented rather than "almost".
    // Never taken from-t: even at equal sizes with sharpen 0, depth must be
    // derived from the resolved t (texture 1 is not a depth array there).
    if (!THRESH_PRESENT_FROM_T
        && R.sharpen <= 0.0f && all(R.srcSize == R.dstSize)) {
        outColor.write(srcColor.read(gid.xy, slice), gid.xy, slice);
        outDepth.write(srcDepth.read(gid.xy, slice), gid.xy, slice);
        return;
    }

    const float2 uv = (float2(gid.xy) + 0.5f) / R.dstSize;
    const float2 du = float2(1.0f / R.dstSize.x, 0.0f);
    const float2 dv = float2(0.0f, 1.0f / R.dstSize.y);

    const bool upscaling = any(R.srcSize != R.dstSize);
    float4 e;
    if (THRESH_PRESENT_FROM_T && upscaling) {
        e = reconCatmullRom(srcColor, uv * R.srcSize, R.srcSize, slice);
    } else if (THRESH_PRESENT_FROM_T) {
        e = srcColor.read(gid.xy, slice);
    } else {
        e = srcColor.sample(kReconBilinear, uv, slice);
    }
    float4 color = e;
    if (R.sharpen > 0.0f) {
        const float4 b = srcColor.sample(kReconBilinear, uv - dv, slice);
        const float4 d = srcColor.sample(kReconBilinear, uv - du, slice);
        const float4 f = srcColor.sample(kReconBilinear, uv + du, slice);
        const float4 g = srcColor.sample(kReconBilinear, uv + dv, slice);
        color = reconSharpen(e, b, d, f, g, R.sharpen);
    }
    outColor.write(color, gid.xy, slice);

    const uint2 sp = uint2(clamp(
        floor(uv * R.srcSize), float2(0.0f), R.srcSize - 1.0f));
    if (THRESH_PRESENT_FROM_T) {
        // Depth from the RESOLVED t: regenerate this output pixel's ray in
        // view-local space (the march kernels' exact formulas) and project
        // the resolved hit distance — misses (t < 0) sit at the far
        // distance the host passes in tScale.
        const ThreshViewUniforms view = views[slice];
        const float roomScale = max(view.originScale.w, 1e-6f);
        const float2 ndc = reconPixelNdc(gid.xy, R.dstSize);
        const float3 dirLocal = reconViewDirLocal(view.invProj, ndc);
        float t = srcDepth.read(sp, slice).x;
        if (t < 0.0f) { t = R.tScale; }
        const float4 clip = view.proj * float4(dirLocal * (t / roomScale), 1.0f);
        outDepth.write(
            float4(clamp(clip.z / max(clip.w, 1e-9f), 0.0f, 1.0f), 0.0f, 0.0f, 0.0f),
            gid.xy, slice);
    } else {
        outDepth.write(srcDepth.read(sp, slice), gid.xy, slice);
    }
}

// ============================ temporal resolve ===============================
//
// Phase A: accumulate jittered march frames into a persistent history at the
// ACCUMULATION resolution — march res (stabilize, THRESH_RECON_UPSAMPLE
// false) or drawable res (TAAU, true). One kernel, both modes.
//
// Bindings (private contract with TemporalReconstructor):
//   buffer 0 — ThreshReconUniforms (srcSize = march res, dstSize = acc res,
//              flags bit 0 = host reset: octave rebase / scene epoch /
//              history realloc)
//   buffer 1 — this frame's ThreshViewUniforms array (ray regeneration)
//   buffer 2 — PREVIOUS frame's views (expected-t for the consistency test)
//   textures 0/1/2 — march color / world-t (miss = −1) / motion (march px)
//   textures 3/4 — history color / aux (r = t, g = count) from frame N−1
//   textures 5/6 — history color / aux for frame N (written)
//
// Grid: (accW, accH, viewCount), 8×8×1 — acc textures are ×8-padded (the
// march-size contract), so no bounds check is needed, but one is kept for
// the TAAU case where acc = drawable (any size).
kernel void temporal_resolve(
    constant ThreshReconUniforms& R                    [[buffer(0)]],
    device const ThreshViewUniforms* views             [[buffer(1)]],
    device const ThreshViewUniforms* prevViews         [[buffer(2)]],
    texture2d_array<float, access::sample> marchColor  [[texture(0)]],
    texture2d_array<float, access::read>   marchT      [[texture(1)]],
    texture2d_array<float, access::read>   marchMotion [[texture(2)]],
    texture2d_array<float, access::sample> histColor   [[texture(3)]],
    texture2d_array<float, access::sample> histAux     [[texture(4)]],
    texture2d_array<float, access::write>  outColor    [[texture(5)]],
    texture2d_array<float, access::write>  outAux      [[texture(6)]],
    uint3 gid                                          [[thread_position_in_grid]])
{
    if (gid.x >= uint(R.dstSize.x) || gid.y >= uint(R.dstSize.y)) { return; }
    const uint slice = gid.z;

    // ---- 1. current fetch (march space) ------------------------------------
    // q: this acc pixel's position in march texel coordinates. The march
    // wrote texel j from the ray through (j + 0.5 − jitter), i.e. the frame's
    // sample GRID is shifted by −jitter — so evaluating the image at q means
    // sampling the TEXTURE at q + jitter (registration), and the nearest
    // actual sample to q is texel round(q − 0.5 + jitter).
    const float2 q = (float2(gid.xy) + 0.5f) * (R.srcSize / R.dstSize);
    const int2 srcMax = int2(R.srcSize) - 1;
    const uint2 mi = uint2(clamp(
        int2(round(q - 0.5f + R.jitter)), int2(0), srcMax));

    float4 C;
    float4 Cfill;
    float beta = 1.0f;
    if (THRESH_RECON_UPSAMPLE) {
        // TAAU: the BLEND contribution is the nearest RAW jittered sample —
        // the sub-pixel information lives in the samples; any filtered fetch
        // is band-limited to march resolution. β gates it by distance from
        // this acc pixel to that sample, with a width of ~0.35 ACC pixels
        // (ratio-scaled into march units) so a sample that belongs to a
        // neighboring acc pixel contributes ~nothing. The registered
        // Catmull-Rom fetch is the FILL image for reject/reset paths, where
        // full coverage beats sharpness.
        C = marchColor.read(mi, slice);
        Cfill = reconCatmullRom(marchColor, q + R.jitter, R.srcSize, slice);
        const float2 nearest = float2(mi) + 0.5f - R.jitter;
        const float2 d = q - nearest;
        const float ratio = R.srcSize.x / max(R.dstSize.x, 1.0f);
        beta = exp(-dot(d, d) / max(0.245f * ratio * ratio, 1e-3f));
    } else {
        C = marchColor.read(gid.xy, slice);
        Cfill = C;
    }
    const float Ct = marchT.read(mi, slice).x;

    // ---- 2. reproject through the march's motion ---------------------------
    // motion = previous − current in MARCH pixels; scale to acc pixels.
    const float2 mv = marchMotion.read(mi, slice).xy;
    const float2 prevP = (float2(gid.xy) + 0.5f) + mv * (R.dstSize / R.srcSize);
    const bool disoccluded =
        any(prevP < 0.0f) || any(prevP >= R.dstSize);
    const float2 uvPrev = prevP / R.dstSize;

    // ---- 3. history fetch ---------------------------------------------------
    const float4 H = histColor.sample(kReconBilinear, uvPrev, slice);
    const float count = histAux.sample(kReconBilinear, uvPrev, slice).y;

    // Expected t: the CURRENT surface point measured from the PREVIOUS eye
    // (both in fractal-world units — camera motion is thereby explained
    // away; what remains is real geometry change, i.e. parameter morphing).
    const ThreshViewUniforms view = views[slice];
    const ThreshViewUniforms prev = prevViews[slice];
    float texp = -1.0f;
    if (Ct >= 0.0f) {
        const float2 ndc = reconPixelNdc(gid.xy, R.dstSize);
        const float3 dirLocal = reconViewDirLocal(view.invProj, ndc);
        const float3 rd = reconQuatRotate(view.orient, dirLocal);
        const float3 world = view.originScale.xyz + rd * Ct;
        texp = length(world - prev.originScale.xyz);
    }

    // History t: gather the 4 bilinear-footprint candidates and keep the one
    // nearest the expectation — bilinear-AVERAGING t across a silhouette
    // would manufacture a distance nobody measured.
    const float4 t4 = histAux.gather(kReconBilinear, uvPrev, slice);
    float Ht = t4.x;
    float bestErr = fabs(t4.x - texp);
    for (int i = 1; i < 4; i++) {
        const float ti = i == 1 ? t4.y : (i == 2 ? t4.z : t4.w);
        const float err = fabs(ti - texp);
        if (err < bestErr) { bestErr = err; Ht = ti; }
    }

    // ---- 4. hit-t consistency (κ relative band) -----------------------------
    bool consistent;
    if (Ct >= 0.0f) {
        consistent = Ht >= 0.0f
            && fabs(Ht - texp) <= 0.08f * max(texp, 1e-4f);
    } else {
        consistent = Ht < 0.0f;   // both miss agree; hit↔miss flip rejects
    }

    // ---- 5. neighborhood clamp (YCoCg mean ± 1.25σ over the 3×3 current) ---
    float3 m1 = float3(0.0f);
    float3 m2 = float3(0.0f);
    float aMin = 1.0f, aMax = 0.0f;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            const uint2 sp = uint2(clamp(int2(mi) + int2(dx, dy),
                                         int2(0), srcMax));
            const float4 s = marchColor.read(sp, slice);
            const float3 y = reconToYCoCg(s.rgb);
            m1 += y;
            m2 += y * y;
            aMin = min(aMin, s.a);
            aMax = max(aMax, s.a);
        }
    }
    const float3 mu = m1 / 9.0f;
    const float3 sigma = sqrt(max(m2 / 9.0f - mu * mu, 0.0f));
    const float3 Hy = reconToYCoCg(H.rgb);
    const float3 clamped = reconFromYCoCg(
        reconClipAABB(mu, 1.25f * sigma + 1e-4f, Hy));
    const float4 Hc = float4(max(clamped, 0.0f), clamp(H.a, aMin, aMax));

    // ---- 6. blend -----------------------------------------------------------
    // Volatility (the lane engine's world-morph scalar) discounts history
    // BEFORE the blend; ≥ 0.9 or any reject path collapses to current-only.
    // β scales α DOWN: a low-confidence current sample (far from any jittered
    // ray this frame) defers to history — the jitter cycle guarantees a
    // near-sample frame comes around, so the floor below is drift insurance,
    // not the convergence path.
    const bool hostReset = (R.flags & 1u) != 0u;
    const float w = (consistent && !disoccluded && !hostReset
                     && R.volatility < 0.9f) ? 1.0f : 0.0f;
    const float n = count * (1.0f - R.volatility) * w;
    float4 outc;
    float tOut;
    if (w > 0.0f) {
        float alpha = max(R.alphaBase, 1.0f / (n + 1.0f)) * beta;
        alpha = max(alpha, 0.01f);
        outc = mix(Hc, C, alpha);
        if (Ct >= 0.0f && Ht >= 0.0f) {
            tOut = mix(Ht, Ct, max(alpha, 0.5f));  // t converges faster than color
        } else if (Ct < 0.0f && Ht < 0.0f) {
            tOut = -1.0f;
        } else {
            tOut = Ct;
        }
    } else {
        // Reject/reset: full-coverage fill, current-only.
        outc = Cfill;
        tOut = Ct;
    }
    const float nOut = min(n + 1.0f, 32.0f);

    outColor.write(outc, gid.xy, slice);
    outAux.write(float4(tOut, nOut, 0.0f, 0.0f), gid.xy, slice);
}
