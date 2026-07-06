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

// Uniforms for every kernel in this library. Fields past `sharpen` are the
// temporal-resolve phase's slots (jitter/tScale/volatility/alphaBase/
// frameIndex) — bound but unused by the phase-0 present pass, reserved so the
// contract doesn't churn per phase. 48 bytes, 8-byte aligned.
struct ThreshReconUniforms {
    float2 srcSize;     // march-resolution dimensions, pixels
    float2 dstSize;     // present/accumulation-resolution dimensions
    float2 jitter;      // current frame's sub-pixel jitter, march pixels
    float  sharpen;     // RCAS strength [0, 1]; 0 = no sharpening
    float  tScale;      // linear-t un-normalization (Mac t/maxDist vs world t)
    float  volatility;  // world-morph magnitude [0, 1] from the lane engine
    float  alphaBase;   // temporal blend floor
    uint   frameIndex;  // jitter/sample-pattern phase
    uint   flags;       // reserved
};

constant constexpr sampler kReconBilinear(
    coord::normalized, address::clamp_to_edge, filter::linear);

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
kernel void recon_present(
    constant ThreshReconUniforms& R                 [[buffer(0)]],
    texture2d_array<float, access::sample> srcColor [[texture(0)]],
    texture2d_array<float, access::sample> srcDepth [[texture(1)]],
    texture2d_array<float, access::write>  outColor [[texture(2)]],
    texture2d_array<float, access::write>  outDepth [[texture(3)]],
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
    if (R.sharpen <= 0.0f && all(R.srcSize == R.dstSize)) {
        outColor.write(srcColor.read(gid.xy, slice), gid.xy, slice);
        outDepth.write(srcDepth.read(gid.xy, slice), gid.xy, slice);
        return;
    }

    const float2 uv = (float2(gid.xy) + 0.5f) / R.dstSize;
    const float2 du = float2(1.0f / R.dstSize.x, 0.0f);
    const float2 dv = float2(0.0f, 1.0f / R.dstSize.y);

    const float4 e = srcColor.sample(kReconBilinear, uv, slice);
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
    outDepth.write(srcDepth.read(sp, slice), gid.xy, slice);
}
