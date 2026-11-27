// PostProcess.metal — ordered, full-frame image effects.
//
// One dispatch consumes one authored filter. The host ping-pongs through
// rgba16Float intermediates in exact array order, then runs kind 0 as the
// output conversion into the presentation texture. Keeping these effects
// after temporal reconstruction prevents grain/bloom from feeding history.

#include <metal_stdlib>
using namespace metal;

struct ThreshPostUniforms {
    float2 size;
    float2 invSize;
    float4 a;
    float4 b;
    float strength;
    float time;
    uint kind;
    uint stage;
};

constant constexpr sampler kPostSampler(
    coord::normalized, address::clamp_to_edge, filter::linear);

/// Stable live-resolution fallback. Unlike MetalFX this is an ordinary GPU
/// compute pass: no ANE program, temporal state, or cross-device fence. The
/// ray marcher supplies a reduced-resolution color texture and this expands
/// it to presentation size with hardware bilinear filtering.
kernel void spatial_upscale_2d(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint width = destination.get_width();
    const uint height = destination.get_height();
    if (gid.x >= width || gid.y >= height) { return; }
    const float2 uv = (float2(gid) + 0.5f) / float2(width, height);
    destination.write(source.sample(kPostSampler, uv), gid);
}

static inline float4 postSample(
    texture2d<float, access::sample> source, float2 uv, uint slice)
{
    (void)slice;
    return source.sample(kPostSampler, uv);
}

static inline float4 postSample(
    texture2d_array<float, access::sample> source, float2 uv, uint slice)
{
    return source.sample(kPostSampler, uv, slice);
}

static inline float postLuma(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

static inline float3 postBrightPass(float3 c, float threshold, float knee) {
    const float luma = postLuma(c);
    // A soft knee avoids a hard contour around the threshold while retaining
    // highlight energy. The division keeps hue/chroma intact.
    knee = max(0.001f, knee);
    const float soft = smoothstep(threshold - knee, threshold + knee, luma);
    const float gain = max(luma - threshold + knee, 0.0f) / max(luma, 1e-4f);
    return c * soft * gain;
}

static inline float postHash(float2 p, float seed) {
    float3 q = fract(float3(p.xyx) * 0.1031f);
    q += dot(q, q.yzx + 33.33f + seed);
    return fract((q.x + q.y) * q.z);
}

template <typename Texture>
static float4 applyPostFilter(
    Texture source, constant ThreshPostUniforms& u,
    float2 uv, uint2 pixel, uint slice)
{
    const float4 center = postSample(source, uv, slice);
    const float amount = isfinite(u.strength) ? u.strength : 0.0f;

    // Kind 0 is the host's format-conversion/presentation copy.
    if (u.kind == 0u) { return center; }

    // 1 — spatial bloom. This is an actual neighborhood bright-pass (unlike
    // the legacy per-pixel "bloom" in the march shader). The 3x3 Gaussian
    // footprint is radius-scaled and can be stacked for broader diffusion.
    if (u.kind == 1u) {
        const float threshold = clamp(u.a.x, 0.0f, 8.0f);
        const float knee = clamp(u.a.y, 0.001f, 4.0f);
        const float radius = clamp(u.a.z, 0.5f, 64.0f);
        const float scatter = clamp(u.a.w, 0.0f, 1.0f);
        const float2 d = u.invSize * radius;
        float3 bloom = float3(0.0f);
        bloom += postBrightPass(postSample(source, uv + float2(-d.x, -d.y), slice).rgb, threshold, knee);
        bloom += 2.0f * postBrightPass(postSample(source, uv + float2(0.0f, -d.y), slice).rgb, threshold, knee);
        bloom += postBrightPass(postSample(source, uv + float2(d.x, -d.y), slice).rgb, threshold, knee);
        bloom += 2.0f * postBrightPass(postSample(source, uv + float2(-d.x, 0.0f), slice).rgb, threshold, knee);
        bloom += 4.0f * postBrightPass(center.rgb, threshold, knee);
        bloom += 2.0f * postBrightPass(postSample(source, uv + float2(d.x, 0.0f), slice).rgb, threshold, knee);
        bloom += postBrightPass(postSample(source, uv + float2(-d.x, d.y), slice).rgb, threshold, knee);
        bloom += 2.0f * postBrightPass(postSample(source, uv + float2(0.0f, d.y), slice).rgb, threshold, knee);
        bloom += postBrightPass(postSample(source, uv + float2(d.x, d.y), slice).rgb, threshold, knee);
        bloom *= (1.0f / 16.0f) * clamp(amount, 0.0f, 8.0f)
            * mix(0.5f, 1.5f, scatter);
        const float haloAlpha = clamp(max3(bloom.r, bloom.g, bloom.b), 0.0f, 1.0f);
        return float4(max(center.rgb + bloom, 0.0f), max(center.a, haloAlpha));
    }

    // 2 — Gaussian blur. Alpha is blurred with RGB, preserving premultiplied
    // silhouettes on the visionOS passthrough compositor.
    if (u.kind == 2u) {
        const float radius = clamp(u.a.x, 0.5f, 64.0f);
        const float sigma = clamp(u.a.y, 0.25f, 64.0f);
        const float2 d = u.invSize * radius;
        const float axisWeight = exp(-0.5f * (radius * radius) / (sigma * sigma));
        const float diagonalWeight = axisWeight * axisWeight;
        float4 blur = center;
        blur += diagonalWeight * postSample(source, uv + float2(-d.x, -d.y), slice);
        blur += axisWeight * postSample(source, uv + float2(0.0f, -d.y), slice);
        blur += diagonalWeight * postSample(source, uv + float2(d.x, -d.y), slice);
        blur += axisWeight * postSample(source, uv + float2(-d.x, 0.0f), slice);
        blur += axisWeight * postSample(source, uv + float2(d.x, 0.0f), slice);
        blur += diagonalWeight * postSample(source, uv + float2(-d.x, d.y), slice);
        blur += axisWeight * postSample(source, uv + float2(0.0f, d.y), slice);
        blur += diagonalWeight * postSample(source, uv + float2(d.x, d.y), slice);
        const float weightSum = 1.0f + 4.0f * axisWeight + 4.0f * diagonalWeight;
        return mix(center, blur / weightSum, clamp(amount, 0.0f, 1.0f));
    }

    // 3 — unsharp-mask sharpen.
    if (u.kind == 3u) {
        const float radius = clamp(u.a.x, 0.5f, 8.0f);
        const float2 dx = float2(u.invSize.x * radius, 0.0f);
        const float2 dy = float2(0.0f, u.invSize.y * radius);
        const float3 cross = (
            postSample(source, uv - dx, slice).rgb
            + postSample(source, uv + dx, slice).rgb
            + postSample(source, uv - dy, slice).rgb
            + postSample(source, uv + dy, slice).rgb) * 0.25f;
        return float4(max(center.rgb + (center.rgb - cross) * clamp(amount, 0.0f, 4.0f),
                          0.0f), center.a);
    }

    // 4 — vignette. Radius/softness are in normalized image-height units;
    // aspect correction keeps the falloff circular instead of elliptical.
    if (u.kind == 4u) {
        float2 d = uv - 0.5f;
        d.x *= u.size.x / max(u.size.y, 1.0f);
        const float inner = clamp(u.a.x, 0.0f, 2.0f);
        const float outer = max(inner + 0.001f, clamp(u.a.y, 0.0f, 2.0f));
        const float edge = smoothstep(inner, outer, length(d));
        return float4(center.rgb * (1.0f - edge * clamp(amount, 0.0f, 1.0f)), center.a);
    }

    // 5 — radial chromatic aberration with an optional angular rotation.
    if (u.kind == 5u) {
        float2 radial = uv - 0.5f;
        const float len = length(radial);
        radial = len > 1e-5f ? radial / len : float2(1.0f, 0.0f);
        const float angle = clamp(u.a.y, -M_PI_F, M_PI_F);
        const float cs = cos(angle), sn = sin(angle);
        const float2 direction = float2(
            radial.x * cs - radial.y * sn,
            radial.x * sn + radial.y * cs);
        const float2 offset = direction * u.invSize * clamp(u.a.x, 0.0f, 64.0f) * len * 2.0f;
        const float r = postSample(source, uv + offset, slice).r;
        const float b = postSample(source, uv - offset, slice).b;
        return float4(
            mix(center.rgb, float3(r, center.g, b), clamp(amount, 0.0f, 1.0f)),
            center.a);
    }

    // 6 — deterministic film grain. Session/content time freezes when the
    // app pauses; the stage index decorrelates two grain filters in a stack.
    if (u.kind == 6u) {
        const float grainSize = clamp(u.a.x, 0.5f, 16.0f);
        const float2 cell = floor(float2(pixel) / grainSize);
        const float frame = floor(u.time * 24.0f);
        const float n = postHash(cell, frame + float(u.stage) * 19.19f) - 0.5f;
        const float grain = n * clamp(amount, 0.0f, 1.0f) * center.a;
        return float4(max(center.rgb + grain, 0.0f), center.a);
    }

    // 7 — color grade. a = saturation, contrast, brightness, gamma;
    // strength crossfades the complete grade.
    if (u.kind == 7u) {
        float3 graded = center.rgb * clamp(u.a.z, 0.0f, 8.0f);
        const float luma = postLuma(graded);
        graded = mix(float3(luma), graded, clamp(u.a.x, 0.0f, 4.0f));
        graded = (graded - 0.18f) * clamp(u.a.y, 0.0f, 4.0f) + 0.18f;
        const float gamma = max(u.a.w, 0.01f);
        graded = pow(max(graded, 0.0f), float3(1.0f / gamma));
        return float4(mix(center.rgb, max(graded, 0.0f), clamp(amount, 0.0f, 1.0f)),
                      center.a);
    }

    // 8 — posterize, strength-blended so it can be layered subtly.
    if (u.kind == 8u) {
        const float levels = clamp(round(u.a.x), 2.0f, 256.0f);
        const float3 quantized = round(saturate(center.rgb) * (levels - 1.0f))
            / (levels - 1.0f);
        return float4(mix(center.rgb, quantized, clamp(amount, 0.0f, 1.0f)), center.a);
    }

    // 9 — invert, premultiplied-alpha aware (transparent black stays clear).
    if (u.kind == 9u) {
        const float3 inverted = max(float3(center.a) - center.rgb, 0.0f);
        return float4(mix(center.rgb, inverted, clamp(amount, 0.0f, 1.0f)), center.a);
    }

    // Unknown kinds are preserved by persistence but skipped by the host. If
    // one reaches this shader defensively, it is still an identity stage.
    return center;
}

kernel void post_process_2d(
    constant ThreshPostUniforms& u                   [[buffer(0)]],
    texture2d<float, access::sample> source          [[texture(0)]],
    texture2d<float, access::write> destination      [[texture(1)]],
    uint2 gid                                        [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
    const float2 uv = (float2(gid) + 0.5f) * u.invSize;
    destination.write(applyPostFilter(source, u, uv, gid, 0), gid);
}

kernel void post_process_array(
    constant ThreshPostUniforms& u                   [[buffer(0)]],
    texture2d_array<float, access::sample> source    [[texture(0)]],
    texture2d_array<float, access::write> destination [[texture(1)]],
    uint3 gid                                        [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()
        || gid.z >= destination.get_array_size()) { return; }
    const float2 uv = (float2(gid.xy) + 0.5f) * u.invSize;
    destination.write(applyPostFilter(source, u, uv, gid.xy, gid.z), gid.xy, gid.z);
}
