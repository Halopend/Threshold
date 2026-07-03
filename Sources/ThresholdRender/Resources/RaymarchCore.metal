// RaymarchCore.metal — the ONE march core (plan Invariant 8, ARCHITECTURE
// Invariant 15, ADR-001). Every march feature lives here; presentation
// differences (blit / Compositor Services / offscreen readback) are shell
// concerns and never touch this file.
//
// IMPORTANT: this file deliberately does NOT #include the ABI header.
// The Swift side (GPUContext) prepends the byte-identical header copy at
// Resources/ThresholdShaderABI.h to this source before
// device.makeLibrary(source:options:) — matching the external-DE compile
// path exactly. All ABI structs (ThreshWarpOp, ThreshFrameUniforms,
// ThreshDEContext) and the THRESH_* constants come from that prepended text.
//
// Op math is normative in docs/op-semantics.md. The CPU reference
// (ThresholdShaderIR/ReferenceOps.swift) implements the same document
// independently; the two are cross-checked by the sampled-equivalence tests
// in Tests/ThresholdRenderTests. If this file and that document disagree,
// this file is wrong.

using namespace metal;

// Binding index for the DE visible function table. Private contract between
// this file and GPUContext (NOT part of the ABI header — the header only owns
// data-layout constants). Keep in sync with GPUContext.deTableBufferIndex.
#define THRESH_BUFFER_DE_TABLE 4

// Every DE — built-in or external — has this signature (ABI header comment):
//   float2 de_<name>(float3 p, thread const ThreshDEContext& ctx)
//   .x = distance estimate, .y = min |z| orbit trap / material channel
using ThreshDE = float2(float3, thread const ThreshDEContext&);

// ======================== common helpers (op-semantics.md) ==================

// GLSL-style floor-mod. docs/op-semantics.md `mod` is the floor-mod: the
// triangle-wave constructions (BoxFold HoM, Kaleidoscope, Shells, Tiling)
// require mod(x, y) ∈ [0, y) for negative x, which fmod does not provide.
static inline float threshMod(float x, float y) { return x - y * floor(x / y); }
static inline float3 threshMod3(float3 x, float y) {
    return float3(threshMod(x.x, y), threshMod(x.y, y), threshMod(x.z, y));
}

// Deterministic perpendicular to unit axis n.
static inline float3 perpOf(float3 n) {
    return normalize(cross(n, (fabs(n.y) < 0.9f) ? float3(0.0f, 1.0f, 0.0f)
                                                 : float3(1.0f, 0.0f, 0.0f)));
}

// Rotation of v around unit axis n by angle t (Rodrigues).
static inline float3 rotAxis(float3 v, float3 n, float t) {
    float c = cos(t);
    float s = sin(t);
    return v * c + cross(n, v) * s + n * (dot(n, v) * (1.0f - c));
}

// Polynomial smooth min/max (IQ), k > 0.
static inline float sminIQ(float x, float y, float k) {
    float h = max(k - fabs(x - y), 0.0f) / k;
    return min(x, y) - h * h * k * 0.25f;
}
static inline float smaxIQ(float x, float y, float k) { return -sminIQ(-x, -y, k); }

// Axis payloads are stored unnormalized; normalize on read, near-zero → +Y.
static inline float3 readAxis(float3 raw) {
    return (dot(raw, raw) < 1e-12f) ? float3(0.0f, 1.0f, 0.0f) : normalize(raw);
}

// ============================ point ops (kind < 64) =========================
//
// Transforms the sample point before the DE runs, accumulating the distance
// scale correction per docs/op-semantics.md: `dScale *= max(1, factor)` for
// Lipschitz-bounded ops; conformal ops multiply the EXACT factor, unclamped.

static float3 applyPointOps(float3 p, device const ThreshWarpOp* ops, uint count,
                            thread float& dScale)
{
    for (uint i = 0; i < count; ++i) {
        const ThreshWarpOp op = ops[i];
        if (op.kind == ThreshWarpKindNone ||
            op.kind >= THRESH_WARP_KIND_DISTANCE_OP_BASE) {
            continue;
        }
        const float s = op.strength;

        switch (op.kind) {

        case ThreshWarpKindTwist: {                    // a.xyz axis
            float3 n = readAxis(op.a.xyz);
            float t = dot(p, n);
            float rp = length(p - n * t);
            p = rotAxis(p, n, s * t);
            dScale *= max(1.0f, sqrt(1.0f + (s * rp) * (s * rp)));
            break;
        }

        case ThreshWarpKindBend: {                     // a.xyz axis
            float3 n = readAxis(op.a.xyz);
            float3 c = perpOf(n);
            float theta = s * dot(p, c);
            float rp = length(p - n * dot(p, n));
            p = rotAxis(p, n, theta);
            dScale *= max(1.0f, sqrt(1.0f + (s * rp) * (s * rp)));
            break;
        }

        case ThreshWarpKindRipple: {                   // a.xyz axis, a.w frequency
            float3 n = readAxis(op.a.xyz);
            float3 c = perpOf(n);
            p = p + n * (s * sin(op.a.w * dot(p, c)));
            dScale *= 1.0f + fabs(s * op.a.w);
            break;
        }

        case ThreshWarpKindMirror: {                   // no payload
            p = mix(p, fabs(p), s);
            break;                                     // isometric at s = 1
        }

        case ThreshWarpKindBoxFold: {                  // a.x limit; OPTION_A = HoM
            float L = op.a.x;
            float3 folded;
            if (op.flags & THRESH_WARP_FLAG_OPTION_A) {
                // Mirrored infinite repeat: triangle wave, period 4L, range [-L, L].
                folded = fabs(threshMod3(p + L, 4.0f * L) - 2.0f * L) - L;
            } else {
                folded = clamp(p, -L, L) * 2.0f - p;
            }
            p = mix(p, folded, s);
            break;                                     // no dScale (|1-2s| ≤ 1)
        }

        case ThreshWarpKindPlaneFold: {                // a.xyz normal, a.w distance
            float3 n = readAxis(op.a.xyz);
            float h = dot(p, n) - op.a.w;
            if (h < 0.0f) { p = mix(p, p - 2.0f * h * n, s); }
            break;                                     // isometric at s = 1
        }

        case ThreshWarpKindKaleidoscope: {             // a.x segment count N ≥ 1
            // atan2(0, 0) is NaN in MSL but 0 in libm — pin the CPU value.
            float theta = (p.z == 0.0f && p.x == 0.0f) ? 0.0f : atan2(p.z, p.x);
            float r = length(p.xz);
            float w = M_PI_F / op.a.x;
            float tf = fabs(threshMod(theta + w, 2.0f * w) - w);
            float tp = mix(theta, tf, s);
            p = float3(r * cos(tp), p.y, r * sin(tp));
            break;                                     // isometric at s = 1
        }

        case ThreshWarpKindCoxeter: {                  // a.x = P, a.y = Q
            float sp = sin(M_PI_F / op.a.x);
            float c = cos(M_PI_F / op.a.y) / sp;
            float3 n1 = float3(1.0f, 0.0f, 0.0f);
            float3 n2 = float3(-cos(M_PI_F / op.a.x), sp, 0.0f);
            // Normalized (op-semantics): non-spherical {P,Q} (c > 1) would
            // otherwise yield a non-unit mirror -> expansive, divergent fold.
            float3 n3 = normalize(float3(0.0f, -c, sqrt(max(1e-6f, 1.0f - c * c))));
            float3 q = p;
            for (int it = 0; it < 24; ++it) {
                bool reflected = false;
                float d1 = dot(q, n1); if (d1 < 0.0f) { q -= 2.0f * d1 * n1; reflected = true; }
                float d2 = dot(q, n2); if (d2 < 0.0f) { q -= 2.0f * d2 * n2; reflected = true; }
                float d3 = dot(q, n3); if (d3 < 0.0f) { q -= 2.0f * d3 * n3; reflected = true; }
                if (!reflected) { break; }
            }
            p = mix(p, q, s);
            break;                                     // isometric at s = 1
        }

        case ThreshWarpKindMengerFold: {               // no payload
            float3 q = fabs(p);
            if (q.x < q.y) { float t = q.x; q.x = q.y; q.y = t; }
            if (q.x < q.z) { float t = q.x; q.x = q.z; q.z = t; }
            if (q.y < q.z) { float t = q.y; q.y = q.z; q.z = t; }
            p = mix(p, q, s);                          // q.x ≥ q.y ≥ q.z
            break;                                     // isometric at s = 1
        }

        case ThreshWarpKindOffsetFold: {               // a.xyz crease center
            float3 c = op.a.xyz;
            p = mix(p, fabs(p - c) + c, s);
            break;                                     // isometric at s = 1
        }

        case ThreshWarpKindSphereFold: {               // a.x minRadius, a.y fixedRadius
            float mR2 = op.a.x * op.a.x;
            float fR2 = op.a.y * op.a.y;
            float r2 = dot(p, p);
            float factor = 1.0f;
            if (r2 < mR2)      { factor = fR2 / mR2; }
            else if (r2 < fR2) { factor = fR2 / r2; }
            float k = mix(1.0f, factor, s);
            p *= k;
            dScale *= k;                               // conformal — exact, unclamped
            break;
        }

        case ThreshWarpKindSphereInvert: {             // a.x radius
            float r2 = max(dot(p, p), 1e-12f);
            float k = mix(1.0f, (op.a.x * op.a.x) / r2, s);
            p *= k;
            dScale *= k;                               // conformal — exact, unclamped
            break;
        }

        case ThreshWarpKindTubeFold: {                 // a.x innerR, a.y outerR
            float mR2 = op.a.x * op.a.x;
            float fR2 = op.a.y * op.a.y;
            float r2 = dot(p.xz, p.xz);
            float factor = 1.0f;
            if (r2 < mR2)      { factor = fR2 / mR2; }
            else if (r2 < fR2) { factor = fR2 / r2; }
            float k = mix(1.0f, factor, s);
            p.x *= k;
            p.z *= k;
            dScale *= max(1.0f, k);                    // in-plane only — Lipschitz, clamped
            break;
        }

        case ThreshWarpKindShells: {                   // a.x spacing > 0
            float t = op.a.x;
            float r = length(p);
            float rp = fabs(threshMod(r, 2.0f * t) - t);
            float k = mix(1.0f, rp / max(r, 1e-9f), s);
            p *= k;
            break;                                     // contraction — no dScale
        }

        case ThreshWarpKindScaleRepeat: {              // a.x factor > 1
            float kf = op.a.x;
            float r = length(p);
            float n = floor(log(max(r, 1e-9f)) / log(kf));
            float m = pow(kf, n * s);
            p /= m;
            dScale *= 1.0f / m;                        // conformal — exact, unclamped
            break;
        }

        case ThreshWarpKindTiling: {                   // a.x cell, b.xyz axis mask
            float c = op.a.x;
            float3 q = p;
            if (op.b.x >= 0.5f) { q.x = threshMod(p.x + 0.5f * c, c) - 0.5f * c; }
            if (op.b.y >= 0.5f) { q.y = threshMod(p.y + 0.5f * c, c) - 0.5f * c; }
            if (op.b.z >= 0.5f) { q.z = threshMod(p.z + 0.5f * c, c) - 0.5f * c; }
            p = mix(p, q, s);
            break;                                     // isometric at s = 1
        }

        case ThreshWarpKindScale: {                    // a.x factor > 0
            float m = mix(1.0f, op.a.x, s);
            p /= m;
            dScale *= 1.0f / m;                        // conformal — exact, unclamped
            break;
        }

        case ThreshWarpKindSphereProject: {            // a.x shell radius
            float r = length(p);
            float rp = mix(r, op.a.x, s);
            float k = rp / max(r, 1e-9f);
            p *= k;
            dScale *= max(1.0f, k);                    // Lipschitz, clamped
            break;
        }

        default:
            break;
        }
    }
    return p;
}

// ========================== distance ops (kind ≥ 64) ========================
//
// Operate on the resolved SDF value AFTER the DE runs, and receive the
// ORIGINAL world-space point (pre-point-ops) — a hand is at a world position;
// it must not be dragged through the folds.

static float applyDistanceOps(float3 worldP, float d, device const ThreshWarpOp* ops,
                              uint count)
{
    for (uint i = 0; i < count; ++i) {
        const ThreshWarpOp op = ops[i];
        if (op.kind < THRESH_WARP_KIND_DISTANCE_OP_BASE) { continue; }
        const float s = op.strength;

        switch (op.kind) {

        case ThreshWarpKindHandAttract: {
            // a.xyz center, a.w radius; b = (ballScale, blendSoftness,
            // pocketSize, pocketSoftness); OPTION_A = pocket enabled.
            float sphere = length(worldP - op.a.xyz) - op.a.w * op.b.x;
            float k = max(op.b.y, 1e-4f);
            if (s > 0.0f) {
                d = mix(d, sminIQ(d, sphere, k), s);
            } else if (s < 0.0f) {
                d = mix(d, smaxIQ(d, -sphere, k), -s);
            }
            if ((op.flags & THRESH_WARP_FLAG_OPTION_A) && s > 0.0f) {
                float pocket = length(worldP - op.a.xyz) - op.a.w * op.b.z;
                d = mix(d, smaxIQ(d, -pocket, max(op.b.w, 1e-4f)), s);
            }
            break;
        }

        case ThreshWarpKindForearmCarve: {
            // a.xyz capsule start, b.xyz capsule end, a.w radius,
            // b.w blendSoftness. ALWAYS subtractive.
            float3 pa = worldP - op.a.xyz;
            float3 ba = op.b.xyz - op.a.xyz;
            float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-9f), 0.0f, 1.0f);
            float cap = length(pa - ba * h) - op.a.w;
            d = mix(d, smaxIQ(d, -cap, max(op.b.w, 1e-4f)), fabs(s));
            break;
        }

        case ThreshWarpKindBounding:                   // reserved — passthrough
        default:
            break;
        }
    }
    return d;
}

// ============================== built-in DEs ================================
//
// Standard formulations. Param slice convention (encoder contract): the DE
// slice = declared params + [iterations] appended as the LAST entry; the DE
// reads iterations = int(ctx.params[ctx.paramCount - 1]).
//
// Orbit trap (.y): min |z| over the visited orbit INCLUDING the initial
// z = p, i.e. min over every |z| value at loop-top / after each update.

// params: [scale, minRadius, fixedRadius, foldLimit] + [iterations]
[[visible]] float2 de_mandelbox(float3 p, thread const ThreshDEContext& ctx)
{
    const float scale = ctx.params[0];
    const float minR  = ctx.params[1];
    const float fixR  = ctx.params[2];
    const float limit = ctx.params[3];
    const int iterations = int(ctx.params[ctx.paramCount - 1]);
    const float mR2 = minR * minR;
    const float fR2 = fixR * fixR;

    float3 z = p;
    float dr = 1.0f;
    float trap = length(z);
    for (int i = 0; i < iterations; ++i) {
        // Box fold.
        z = clamp(z, -limit, limit) * 2.0f - z;
        // Sphere fold (conformal — scales dr by the same factor).
        float r2 = dot(z, z);
        if (r2 < mR2)      { float f = fR2 / mR2; z *= f; dr *= f; }
        else if (r2 < fR2) { float f = fR2 / r2;  z *= f; dr *= f; }
        z = z * scale + p;
        dr = dr * fabs(scale) + 1.0f;
        trap = min(trap, length(z));
        if (dot(z, z) > 1e8f) { break; }   // diverged — further folds are inert
    }
    return float2(length(z) / fabs(dr), trap);
}

// params: [power] + [iterations]. Classic triplex-power formulation
// (Hart-style DE 0.5·log(r)·r/dr), escape radius 4 checked at loop top —
// numerically identical to ReferenceDEs.mandelbulb.
[[visible]] float2 de_mandelbulb(float3 p, thread const ThreshDEContext& ctx)
{
    const float power = ctx.params[0];
    const int iterations = int(ctx.params[ctx.paramCount - 1]);

    float3 z = p;
    float dr = 1.0f;
    float r = length(z);
    float trap = r;
    for (int i = 0; i < iterations; ++i) {
        r = length(z);
        if (r > 4.0f) { break; }           // escape radius 4
        float rSafe = max(r, 1e-9f);
        float theta = acos(clamp(z.z / rSafe, -1.0f, 1.0f)) * power;
        // atan2(0, 0) is NaN in MSL but 0 in libm (C99 F.9.1.4) — points on
        // the z-axis (e.g. a camera ray origin) must match the CPU reference.
        float phi = (z.y == 0.0f && z.x == 0.0f) ? 0.0f : atan2(z.y, z.x) * power;
        dr = pow(rSafe, power - 1.0f) * power * dr + 1.0f;
        float zr = pow(rSafe, power);
        z = zr * float3(sin(theta) * cos(phi), sin(phi) * sin(theta), cos(theta)) + p;
        trap = min(trap, length(z));
    }
    return float2(0.5f * log(max(r, 1e-9f)) * r / dr, trap);
}

// ============================== the scene map ===============================
//
// THE single scene distance function (Invariant 7). March loop, tetrahedron
// normals, and AO all evaluate the identical pipeline:
//   (p', dScale) = applyPointOps(worldP)
//   d = de(p', ctx).x / dScale
//   d = applyDistanceOps(worldP, d)

static float2 mapScene(float3 worldP,
                       constant ThreshFrameUniforms& U,
                       device const float* params,
                       device const ThreshWarpOp* ops,
                       visible_function_table<ThreshDE> deTable)
{
    float dScale = 1.0f;
    float3 q = applyPointOps(worldP, ops, U.meta.x, dScale);

    ThreshDEContext ctx;
    ctx.params = params + U.meta.w;          // DE param slice at deParamOffset
    ctx.paramCount = U.meta.z - U.meta.w;    // slice length (iterations last)
    ctx.time = U.scaleCtx.x;
    ctx.lodScale = U.scaleCtx.w;

    float2 de = deTable[U.meta.y](q, ctx);
    float d = de.x / dScale;
    d = applyDistanceOps(worldP, d, ops, U.meta.x);
    return float2(d, de.y);
}

// ============================ shading helpers ===============================

static inline float3 quatRotate(float4 q, float3 v) {
    // v' = q·v·q⁻¹ for unit quaternion (x,y,z = imaginary, w = real).
    return v + 2.0f * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

// ============================== color pipeline ==============================
// plan §5.5: mapping (coordinate t) → palette (gradient sample) → grading
// (post-process chain). All in LINEAR rgb; sRGB encode is the harness's job.

// Sample the gradient palette at coordinate t. `repeatCount`/`offset` tile and
// phase-shift the gradient (wrapped into [0,1)); `smoothing` blends the
// per-segment interpolation from linear toward smoothstep. Stops arrive sorted
// by position (.w); .xyz is linear rgb.
static float3 samplePalette(float t, constant ThreshPalette& pal,
                            float repeatCount, float offset, float smoothing) {
    uint n = min(pal.stopCount, (uint)THRESH_MAX_GRADIENT_STOPS);
    if (n == 0) { return float3(0.5f); }
    float u = t * max(repeatCount, 1.0f) + offset;
    u = u - floor(u);                        // wrap into [0,1)
    if (n == 1 || u <= pal.stops[0].w) { return pal.stops[0].xyz; }
    if (u >= pal.stops[n - 1].w) { return pal.stops[n - 1].xyz; }
    for (uint i = 0; i + 1 < n; ++i) {
        float p0 = pal.stops[i].w;
        float p1 = pal.stops[i + 1].w;
        if (u >= p0 && u <= p1) {
            float f = (u - p0) / max(p1 - p0, 1e-6f);
            float fs = f * f * (3.0f - 2.0f * f);
            f = mix(f, fs, clamp(smoothing, 0.0f, 1.0f));
            return mix(pal.stops[i].xyz, pal.stops[i + 1].xyz, f);
        }
    }
    return pal.stops[n - 1].xyz;
}

// Narkowicz ACES filmic approximation (opt-in via the tonemap blend).
static inline float3 acesFilmic(float3 x) {
    const float a = 2.51f, b = 0.03f, c = 2.43f, d = 0.59f, e = 0.14f;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0f, 1.0f);
}

// The fixed post-process grade (plan §5.5 stage 3). Identity at the default
// scalars (saturation/contrast/brightness/gamma = 1, vibrance/tonemap = 0),
// so a scene that authors no grading looks exactly like the raw lit color.
static float3 applyGrading(float3 c, device const float* params) {
    const float saturation = params[THRESH_SLOT_SATURATION];
    const float contrast   = params[THRESH_SLOT_CONTRAST];
    const float vibrance   = params[THRESH_SLOT_VIBRANCE];
    const float brightness = params[THRESH_SLOT_BRIGHTNESS];
    const float gamma      = params[THRESH_SLOT_GAMMA];
    const float tonemap    = params[THRESH_SLOT_TONEMAP];

    c = max(c, 0.0f) * brightness;
    const float3 lumaWeights = float3(0.2126f, 0.7152f, 0.0722f);
    float luma = dot(c, lumaWeights);
    c = mix(float3(luma), c, saturation);
    // Vibrance lifts saturation more where the pixel is already dull.
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float vib = vibrance * (1.0f - (mx - mn));
    c = mix(float3(luma), c, 1.0f + vib);
    // Contrast pivoted at mid-gray.
    c = (c - 0.5f) * contrast + 0.5f;
    c = max(c, 0.0f);
    c = mix(c, acesFilmic(c), clamp(tonemap, 0.0f, 1.0f));
    c = pow(max(c, 0.0f), float3(1.0f / max(gamma, 1e-3f)));
    return clamp(c, 0.0f, 1.0f);
}

// Tetrahedron-technique normal of the SAME mapScene (Invariant 7 — never a
// second hand-unrolled gradient sweep).
static float3 calcNormal(float3 pos, float h,
                         constant ThreshFrameUniforms& U,
                         device const float* params,
                         device const ThreshWarpOp* ops,
                         visible_function_table<ThreshDE> deTable)
{
    const float2 k = float2(1.0f, -1.0f);
    return normalize(k.xyy * mapScene(pos + k.xyy * h, U, params, ops, deTable).x +
                     k.yyx * mapScene(pos + k.yyx * h, U, params, ops, deTable).x +
                     k.yxy * mapScene(pos + k.yxy * h, U, params, ops, deTable).x +
                     k.xxx * mapScene(pos + k.xxx * h, U, params, ops, deTable).x);
}

// Cheap 5-tap ambient occlusion along the normal, scaled by aoStrength.
static float cheapAO(float3 pos, float3 n, float aoStrength, float modelScale,
                     constant ThreshFrameUniforms& U,
                     device const float* params,
                     device const ThreshWarpOp* ops,
                     visible_function_table<ThreshDE> deTable)
{
    float occ = 0.0f;
    float sca = 1.0f;
    for (int i = 1; i <= 5; ++i) {
        float h = (0.01f + 0.12f * float(i)) * modelScale;
        float d = mapScene(pos + n * h, U, params, ops, deTable).x;
        occ += (h - d) * sca;
        sca *= 0.7f;
    }
    return clamp(1.0f - 1.5f * aoStrength * occ, 0.0f, 1.0f);
}

// ============================== march kernel ================================
//
// One thread per pixel. Ray generation per docs/op-semantics.md "March
// defaults": NDC x,y ∈ [-1,1] (y up), aspect = width/height, camera looks
// down -Z in its local frame, dir rotated by the camera quaternion.
//
// Output: LINEAR rgba values into an rgba8unorm texture — no gamma; encoding
// to PNG/sRGB is the harness's concern.
//
// NaN policy: a non-finite distance estimate writes the sentinel
// float4(1, 0, 1, 0) — alpha 0 — so tests can assert "no NaNs" on the
// readback (every well-formed pixel, hit or miss, has alpha 1).

kernel void march_offscreen(
    constant ThreshFrameUniforms& U          [[buffer(THRESH_BUFFER_UNIFORMS)]],
    device const float* params               [[buffer(THRESH_BUFFER_PARAMS)]],
    device const ThreshWarpOp* ops           [[buffer(THRESH_BUFFER_WARP_OPS)]],
    device atomic_uint* stats                [[buffer(THRESH_BUFFER_STATS)]],
    visible_function_table<ThreshDE> deTable [[buffer(THRESH_BUFFER_DE_TABLE)]],
    constant ThreshPalette& palette          [[buffer(THRESH_BUFFER_PALETTE)]],
    texture2d<float, access::write> outTex   [[texture(THRESH_TEXTURE_OUTPUT)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    const uint w = outTex.get_width();
    const uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    const float aspect = float(w) / float(h);
    const float fovTan = U.camPosFov.w;
    const float2 ndc = float2((float(gid.x) + 0.5f) / float(w) * 2.0f - 1.0f,
                              1.0f - (float(gid.y) + 0.5f) / float(h) * 2.0f);
    const float3 dirLocal = normalize(float3(ndc.x * aspect * fovTan,
                                             ndc.y * fovTan,
                                             -1.0f));
    const float3 rd = quatRotate(U.camQuat, dirLocal);
    const float3 ro = U.camPosFov.xyz;

    // Engine params from the reserved slots of the FULL param table.
    const int maxSteps     = int(params[THRESH_SLOT_MAX_STEPS]);
    const float maxDist    = params[THRESH_SLOT_MAX_DIST];
    const float stepSafety = params[THRESH_SLOT_STEP_SAFETY];
    const float aoStrength = params[THRESH_SLOT_AO_STRENGTH];
    const float epsBase    = U.scaleCtx.y;
    const float modelScale = U.scaleCtx.z;

    float t = 0.0f;
    float hitEps = 0.0f;
    float trap = 0.0f;
    bool hit = false;
    bool bad = false;
    uint steps = 0;

    for (int i = 0; i < maxSteps; ++i) {
        float3 pos = ro + rd * t;
        float2 dm = mapScene(pos, U, params, ops, deTable);
        steps += 1;
        if (isnan(dm.x) || isinf(dm.x)) { bad = true; break; }
        hitEps = epsBase * modelScale * t;      // distance-proportional epsilon
        if (dm.x < hitEps) { hit = true; trap = dm.y; break; }
        t += dm.x * stepSafety;
        if (t > maxDist) { break; }
    }

    // Per-thread step count added ONCE into the device stats counter.
    atomic_fetch_add_explicit(&stats[0], steps, memory_order_relaxed);

    float4 color;
    if (bad) {
        color = float4(1.0f, 0.0f, 1.0f, 0.0f);              // NaN sentinel
    } else if (hit) {
        float3 pos = ro + rd * t;
        float nEps = max(hitEps, 1e-4f * modelScale);
        float3 n = calcNormal(pos, nEps, U, params, ops, deTable);
        float3 lightDir = normalize(float3(1.0f, 0.8f, 0.6f));
        float lambert = max(dot(n, lightDir), 0.0f);

        // Mapping (plan §5.5 stage 1): derive the palette coordinate t_map.
        // Depth/normal already land in 0..1; orbit trap is wrapped by the
        // sampler. Blend mixes trap with depth.
        float depth = clamp(t / max(maxDist, 1e-3f), 0.0f, 1.0f);
        float facing = clamp(0.5f + 0.5f * dot(n, -rd), 0.0f, 1.0f);
        int mapMode = int(params[THRESH_SLOT_MAP_MODE]);
        float tMap;
        switch (mapMode) {
            case 1:  tMap = depth; break;                         // depth
            case 2:  tMap = facing; break;                        // normal
            case 3:  tMap = 0.5f * fract(trap) + 0.5f * depth; break;  // blend
            default: tMap = trap; break;                          // orbit trap
        }

        float3 albedo = samplePalette(
            tMap, palette,
            params[THRESH_SLOT_GRAD_REPEAT],
            params[THRESH_SLOT_GRAD_OFFSET],
            params[THRESH_SLOT_GRAD_SMOOTH]);
        float occ = cheapAO(pos, n, aoStrength, modelScale, U, params, ops, deTable);
        float3 lit = albedo * (lambert + 0.2f) * occ;
        color = float4(applyGrading(lit, params), 1.0f);
    } else {
        color = float4(0.0f, 0.0f, 0.0f, 1.0f);              // miss: black
    }
    outTex.write(color, gid);
}

// ============================== debug kernels ===============================
//
// The CPU↔GPU contract check. These evaluate the interpreter/DEs on arrays of
// points so the sampled-equivalence tests can compare against the CPU
// reference. Buffer indices are a private contract with OpsEvaluator /
// DEEvaluator — see Evaluators.swift.

// in: float4 per point (xyz = point, w unused)
// out: float4 per point (xyz = transformed point, w = dScale)
kernel void eval_ops(
    device const float4* inPoints  [[buffer(0)]],
    device float4* outPoints       [[buffer(1)]],
    device const ThreshWarpOp* ops [[buffer(2)]],
    constant uint& opCount         [[buffer(3)]],
    constant uint& pointCount      [[buffer(4)]],
    uint gid                       [[thread_position_in_grid]])
{
    if (gid >= pointCount) { return; }
    float dScale = 1.0f;
    float3 q = applyPointOps(inPoints[gid].xyz, ops, opCount, dScale);
    outPoints[gid] = float4(q, dScale);
}

// in: float4 per point (xyz = WORLD point, w = input distance d)
// out: float per point (d')
kernel void eval_dist(
    device const float4* inPoints  [[buffer(0)]],
    device float* outDist          [[buffer(1)]],
    device const ThreshWarpOp* ops [[buffer(2)]],
    constant uint& opCount         [[buffer(3)]],
    constant uint& pointCount      [[buffer(4)]],
    uint gid                       [[thread_position_in_grid]])
{
    if (gid >= pointCount) { return; }
    const float4 v = inPoints[gid];
    outDist[gid] = applyDistanceOps(v.xyz, v.w, ops, opCount);
}

// in: float4 per point (xyz = point, w unused)
// out: float2 per point (DE result: .x distance, .y orbit trap)
// U supplies deIndex (meta.y), paramCount (meta.z), deParamOffset (meta.w),
// time (scaleCtx.x) and lodScale (scaleCtx.w) — same decode as mapScene.
kernel void eval_de(
    device const float4* inPoints            [[buffer(0)]],
    device float2* outDE                     [[buffer(1)]],
    device const float* params               [[buffer(2)]],
    constant ThreshFrameUniforms& U          [[buffer(3)]],
    constant uint& pointCount                [[buffer(4)]],
    visible_function_table<ThreshDE> deTable [[buffer(5)]],
    uint gid                                 [[thread_position_in_grid]])
{
    if (gid >= pointCount) { return; }
    ThreshDEContext ctx;
    ctx.params = params + U.meta.w;
    ctx.paramCount = U.meta.z - U.meta.w;
    ctx.time = U.scaleCtx.x;
    ctx.lodScale = U.scaleCtx.w;
    outDE[gid] = deTable[U.meta.y](inPoints[gid].xyz, ctx);
}
