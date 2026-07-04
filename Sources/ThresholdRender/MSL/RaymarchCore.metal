// RaymarchCore.metal — the ONE march core (plan Invariant 8, ARCHITECTURE
// Invariant 15, ADR-001). Every march feature lives here; presentation
// differences (blit / Compositor Services / offscreen readback) are shell
// concerns and never touch this file.
//
// IMPORTANT: this file deliberately does NOT #include the ABI header.
// The Swift side (GPUContext) prepends the byte-identical header copy at
// MSL/ThresholdShaderABI.h to this source before
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

// ==================== specialization function constants =====================
//
// Compile-time knobs the CPU bakes into a specialized pipeline variant
// (GPUContext.makeSpecializedMarch) via MTLFunctionConstantValues. A function
// constant is a true compile-time constant for the specialized function, so
// the optimizer can act on it: a baked iteration bound lets the DE fold loop
// UNROLL and hoist per-iteration invariants — which a device-memory trip count
// (re-read every march step, every pixel) structurally prevents. The GENERIC
// library never defines THRESH_SPEC_DE, so this constant is declared ONLY in
// the specialized library and the base DE visible-function table carries no
// function constant at all. GPUContext ALWAYS provides index 1 on a
// specialized kernel (the real count, or -1 = "use the runtime value"), so the
// constant is never referenced-but-undefined. Either way the specialized image
// is bit-identical to the generic one (SpecializationTests).
//
// Function-constant index registry (private contract with
// GPUContext.makeLinkedPipeline — keep in sync). Each is an int with -1 =
// "use the runtime value" (the sentinel), so the constant is ALWAYS provided
// where declared and the specialized image equals the generic one:
//   0 = thresh_aux_defined   (temporal-upscale aux path, declared below)
//   1 = thresh_de_iterations (DE fold-loop bound)
//   2 = thresh_max_steps     (march step cap)
//   3 = thresh_has_ops       (warp stack present: 1/0 → DCE the interpreter)
//   4 = thresh_map_mode       (color mapping mode → drop the per-pixel switch)
//   5 = thresh_ao_enabled     (AO on: 1/0 → drop the 5-tap AO when off)
#ifdef THRESH_SPEC_DE
constant int thresh_de_iterations [[function_constant(1)]];
constant int thresh_max_steps     [[function_constant(2)]];
constant int thresh_has_ops       [[function_constant(3)]];
constant int thresh_map_mode      [[function_constant(4)]];
constant int thresh_ao_enabled    [[function_constant(5)]];
constant int thresh_has_dist_ops  [[function_constant(6)]];
constant int thresh_stats_enabled [[function_constant(7)]];
constant int thresh_cone_margin   [[function_constant(9)]];
#endif

// Cone-prepass stop margin (function_constant 9): the prepass stops when the
// tile's clearance falls to `margin × epsBase × t` (block 9 fixed it at 3×).
// A LARGER margin backs each tile's shared start depth further from the
// surface, so the per-pixel march refines more and fewer edge pixels
// immediate-hit at the tile depth — that is the shimmer (tile-quantized
// silhouettes jittering frame-to-frame). A small discrete set of levels, each
// a cached pipeline variant (a continuous value would recompile per tick), is
// the UI's "Cone Stability" lever. -1 / absent → the 3× default.
static inline float threshConeMargin() {
#ifdef THRESH_SPEC_DE
    return (thresh_cone_margin > 0) ? float(thresh_cone_margin) : 3.0f;
#else
    return 3.0f;
#endif
}

// The DE fold-loop bound: the baked compile-time count in a specialized
// variant (the loop unrolls), else the runtime slice value — the iterations
// appended as the last DE param (DERegistry encoder convention). Both resolve
// to the SAME number, so specialized output equals generic output.
static inline int threshDEIterations(thread const ThreshDEContext& ctx) {
#ifdef THRESH_SPEC_DE
    int n = (thresh_de_iterations >= 0) ? thresh_de_iterations
                                        : int(ctx.params[ctx.paramCount - 1]);
#else
    int n = int(ctx.params[ctx.paramCount - 1]);
#endif
    // lodScale < 1 → reduced-iteration evaluation (normal/AO taps, perf
    // round 7 — legacy "cheap gradient" port). Primary march passes 1.
    return (ctx.lodScale >= 1.0f) ? n : max(1, int(float(n) * ctx.lodScale));
}

// March step cap: baked compile-time when specialized, else the runtime
// engine slot. Same value either way.
static inline int threshMaxSteps(int runtimeMaxSteps) {
#ifdef THRESH_SPEC_DE
    return (thresh_max_steps >= 0) ? thresh_max_steps : runtimeMaxSteps;
#else
    return runtimeMaxSteps;
#endif
}

// Warp-stack presence: when a specialized variant bakes FALSE (empty stack),
// the compiler DCEs the whole point/distance-op interpreter (the 22-case
// switch + op-buffer reads) out of the march. An empty stack already no-ops
// those loops, so gating them off is bit-identical. Generic falls back to the
// runtime op count.
static inline bool threshHasOps(uint runtimeOpCount) {
#ifdef THRESH_SPEC_DE
    return (thresh_has_ops >= 0) ? (thresh_has_ops != 0) : (runtimeOpCount > 0u);
#else
    return runtimeOpCount > 0u;
#endif
}

// Distance-op presence (kind ≥ 64): a stack of pure point ops keeps
// threshHasOps true but never has work in applyDistanceOps — baking FALSE
// DCEs that per-mapScene loop (2 device op loads per call otherwise). The
// loop skips those kinds anyway, so gating it off is bit-identical.
static inline bool threshHasDistOps(uint runtimeOpCount) {
#ifdef THRESH_SPEC_DE
    return (thresh_has_dist_ops >= 0) ? (thresh_has_dist_ops != 0)
                                      : (runtimeOpCount > 0u);
#else
    return runtimeOpCount > 0u;
#endif
}

// Tile cone-march prepass (function_constant 8, aux-style bool gate):
// hierarchical march — a COARSE DISPATCH (march_cone_prepass, one thread per
// 8x8 tile) cone-marches each tile's central ray and writes the shared safe
// start depth into a small r32float texture; the fine kernel reads its
// tile's depth instead of re-marching the same near-field empty space 64
// times. Absent constant → false: goldens and the specialized==generic
// equivalence tests are untouched; perf pipelines bake TRUE.
constant bool thresh_cone_defined [[function_constant(8)]];
constant bool THRESH_CONE = is_function_constant_defined(thresh_cone_defined)
    ? thresh_cone_defined : false;
#define THRESH_TEXTURE_CONE    3
#define THRESH_BUFFER_CONE_DIMS 8
#define THRESH_CONE_TILE       8

// Stats instrumentation: the per-pixel atomic step-count add is telemetry,
// not image data — a variant that bakes FALSE drops one device atomic per
// thread per frame (totalSteps reads back 0). Generic always counts.
static inline bool threshStatsEnabled() {
#ifdef THRESH_SPEC_DE
    return thresh_stats_enabled != 0;   // -1 sentinel (runtime) also counts
#else
    return true;
#endif
}

// Color mapping mode: baked → the per-hit-pixel switch collapses to one case.
static inline int threshMapMode(int runtimeMapMode) {
#ifdef THRESH_SPEC_DE
    return (thresh_map_mode >= 0) ? thresh_map_mode : runtimeMapMode;
#else
    return runtimeMapMode;
#endif
}

// AO enablement: cheapAO at aoStrength == 0 returns exactly 1.0 (no darkening),
// so a specialized variant that bakes FALSE skips the 5 mapScene AO taps for a
// bit-identical result. Generic falls back to (aoStrength > 0).
static inline bool threshAOEnabled(float aoStrength) {
#ifdef THRESH_SPEC_DE
    return (thresh_ao_enabled >= 0) ? (thresh_ao_enabled != 0) : (aoStrength > 0.0f);
#else
    return aoStrength > 0.0f;
#endif
}

// ============================== built-in DEs ================================
//
// Standard formulations. Param slice convention (encoder contract): the DE
// slice = declared params + [iterations] appended as the LAST entry; the DE
// reads its fold-loop bound via threshDEIterations(ctx) — the baked
// function-constant count when specialized, else int(ctx.params[paramCount-1]).
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
    const int iterations = threshDEIterations(ctx);
    const float mR2 = minR * minR;
    const float fR2 = fixR * fixR;

    // Orbit trap tracked SQUARED (min commutes with sqrt) — one sqrt at
    // return instead of one per iteration (perf round 9).
    float3 z = p;
    float dr = 1.0f;
    float trap2 = dot(z, z);
    for (int i = 0; i < iterations; ++i) {
        // Box fold.
        z = clamp(z, -limit, limit) * 2.0f - z;
        // Sphere fold (conformal — scales dr by the same factor).
        float r2 = dot(z, z);
        if (r2 < mR2)      { float f = fR2 / mR2; z *= f; dr *= f; }
        else if (r2 < fR2) { float f = fR2 / r2;  z *= f; dr *= f; }
        z = z * scale + p;
        dr = dr * fabs(scale) + 1.0f;
        float zz = dot(z, z);
        trap2 = min(trap2, zz);
        if (zz > 1e8f) { break; }          // diverged — further folds are inert
    }
    return float2(length(z) / fabs(dr), sqrt(trap2));
}

// params: [scale, minRadius, fixedRadius, foldLimit, projBlend, projRadius]
//         + [iterations]
// Mandelbox with a built-in sphere projection: the sample point is projected
// radially toward the shell ONCE (p·((1−b)+b·R/|p|), identical to the
// ThreshWarpKindSphereProject op) before the standard fold loop runs. The
// projection's tangential stretch k is divided back out of the returned
// distance (max(1,k), the op's Lipschitz-conservative bound) so a march stays
// safe — self-contained, so no warp-stack entry is needed. Reproduces the
// original app's dedicated "mandelboxSphereProjection" type (good luck / mono).
[[visible]] float2 de_mandelboxSphereProjection(float3 p, thread const ThreshDEContext& ctx)
{
    const float blend  = ctx.params[4];
    const float radius = ctx.params[5];

    // Sphere projection domain warp (once). Identity when blend <= 0.
    // `k` = the tangential stretch s(r) = (1-b) + b·R/r (the Jacobian's max
    // singular value); `rInput` is the pre-projection radius, used below to cap
    // the step away from the r→0 singularity.
    float k = 1.0f;
    float rInput = 0.0f;
    if (blend > 0.0f) {
        rInput = length(p);
        if (rInput > 1e-5f) {
            float b  = clamp(blend, 0.0f, 0.98f);
            float rp = (1.0f - b) * rInput + b * radius;   // mix(rInput, radius, b)
            k = rp / max(rInput, 1e-9f);
            p *= k;
        }
    }

    const float scale = ctx.params[0];
    const float minR  = ctx.params[1];
    const float fixR  = ctx.params[2];
    const float limit = ctx.params[3];
    const int iterations = threshDEIterations(ctx);
    const float mR2 = minR * minR;
    const float fR2 = fixR * fixR;

    float3 z = p;
    float dr = 1.0f;
    float trap2 = dot(z, z);
    for (int i = 0; i < iterations; ++i) {
        z = clamp(z, -limit, limit) * 2.0f - z;
        float r2 = dot(z, z);
        if (r2 < mR2)      { float f = fR2 / mR2; z *= f; dr *= f; }
        else if (r2 < fR2) { float f = fR2 / r2;  z *= f; dr *= f; }
        z = z * scale + p;
        dr = dr * fabs(scale) + 1.0f;
        float zz = dot(z, z);
        trap2 = min(trap2, zz);
        if (zz > 1e8f) { break; }
    }
    // Divide by the projection stretch (conservative bound) — matches the op's
    // dScale *= max(1,k) followed by mapScene's d = de.x / dScale.
    float dist = (length(z) / fabs(dr)) / max(1.0f, k);
    // Step-cap against the r→0 projection singularity: the pointwise stretch k
    // underestimates what a single step heading inward actually experiences
    // (s(r) blows up as r→0), so cap the reported distance at half the distance
    // to the origin. Under-reporting distance is always safe for sphere tracing
    // (smaller steps), and this keeps the march from tunnelling through the
    // tangentially-compressed shell at high blend. No cap when projection is off.
    if (blend > 0.0f) {
        dist = min(dist, 0.5f * rInput);
    }
    return float2(dist, sqrt(trap2));
}

// params: [power] + [iterations]. Classic triplex-power formulation
// (Hart-style DE 0.5·log(r)·r/dr), escape radius 4 checked at loop top —
// numerically identical to ReferenceDEs.mandelbulb.
[[visible]] float2 de_mandelbulb(float3 p, thread const ThreshDEContext& ctx)
{
    const float power = ctx.params[0];
    const int iterations = threshDEIterations(ctx);

    // Trap reuses the loop-top r (was a second length(z) per iteration —
    // perf round 9): min over |z| at every orbit position is preserved
    // because each new z's |z| is read at the next loop top (or by the
    // final post-loop min below).
    float3 z = p;
    float dr = 1.0f;
    float r = length(z);
    float trap = r;
    for (int i = 0; i < iterations; ++i) {
        r = length(z);
        trap = min(trap, r);
        if (r > 4.0f) { break; }           // escape radius 4
        float rSafe = max(r, 1e-9f);
        float theta = acos(clamp(z.z / rSafe, -1.0f, 1.0f)) * power;
        // atan2(0, 0) is NaN in MSL but 0 in libm (C99 F.9.1.4) — points on
        // the z-axis (e.g. a camera ray origin) must match the CPU reference.
        float phi = (z.y == 0.0f && z.x == 0.0f) ? 0.0f : atan2(z.y, z.x) * power;
        // One transcendental instead of two: r^power = r^(power-1) · r.
        float rp = pow(rSafe, power - 1.0f);
        dr = rp * power * dr + 1.0f;
        float zr = rp * rSafe;
        z = zr * float3(sin(theta) * cos(phi), sin(phi) * sin(theta), cos(theta)) + p;
    }
    trap = min(trap, length(z));
    return float2(0.5f * log(max(r, 1e-9f)) * r / dr, trap);
}

// params: [minX, minY, minZ, sphereFold, maxX, maxY, maxZ, crossRadius]
// + [iterations]. Knighty's Pseudo Kleinian — numerically identical to
// ReferenceDEs.kleinian.
[[visible]] float2 de_kleinian(float3 p, thread const ThreshDEContext& ctx)
{
    const float3 mins = float3(ctx.params[0], ctx.params[1], ctx.params[2]);
    const float sphereFold = ctx.params[3];
    const float3 maxs = float3(ctx.params[4], ctx.params[5], ctx.params[6]);
    const float crossR = ctx.params[7];
    const int iterations = threshDEIterations(ctx);

    float3 z = p;
    float scale = 1.0f;
    float trap2 = dot(z, z);   // squared trap — one sqrt at return (round 9)

    for (int i = 0; i < iterations; ++i) {
        z = clamp(z, mins, maxs) * 2.0f - z;
        float r2 = dot(z, z);
        float k = max(sphereFold / max(r2, 1e-6f), 1.0f);
        z *= k;
        scale *= k;
        trap2 = min(trap2, dot(z, z));
    }
    float trap = sqrt(trap2);

    float rxy = length(z.xy);
    float de = 0.7f * max(rxy - crossR, rxy * z.z / max(length(z), 1e-6f))
        / max(scale, 1e-6f);
    return float2(de, trap);
}

// params: [scale, offsetX, offsetY, offsetZ] + [iterations]. Classic Menger
// sponge — numerically identical to ReferenceDEs.menger.
[[visible]] float2 de_menger(float3 p, thread const ThreshDEContext& ctx)
{
    const float scale = ctx.params[0];
    const float3 offset = float3(ctx.params[1], ctx.params[2], ctx.params[3]);
    const int iterations = threshDEIterations(ctx);

    float3 z = p;
    float dr = 1.0f;
    float trap2 = dot(z, z);   // squared trap — one sqrt at return (round 9)

    for (int i = 0; i < iterations; ++i) {
        z = fabs(z);
        if (z.x < z.y) { float t = z.x; z.x = z.y; z.y = t; }
        if (z.x < z.z) { float t = z.x; z.x = z.z; z.z = t; }
        if (z.y < z.z) { float t = z.y; z.y = z.z; z.z = t; }

        float3 offsetScaled = offset * (scale - 1.0f);
        z = z * scale - offsetScaled;
        if (z.z < -0.5f * offsetScaled.z) {
            z.z += offsetScaled.z;
        }
        dr = dr * fabs(scale) + 1.0f;
        trap2 = min(trap2, dot(z, z));
    }
    return float2((length(z) - 1.0f) / dr, sqrt(trap2));
}

// params: [cX, cY, cZ, cW, threshold] + [iterations]. Quaternion Julia —
// numerically identical to ReferenceDEs.quaternionJulia.
[[visible]] float2 de_quaternion_julia(float3 p, thread const ThreshDEContext& ctx)
{
    const float4 c = float4(ctx.params[0], ctx.params[1], ctx.params[2], ctx.params[3]);
    const float threshold = ctx.params[4];
    const int iterations = threshDEIterations(ctx);

    float4 q = float4(p, 0.0f);
    float4 dq = float4(1.0f, 0.0f, 0.0f, 0.0f);
    float trap2 = dot(q, q);   // squared trap — one sqrt at return (round 9)

    for (int i = 0; i < iterations; ++i) {
        dq = 2.0f * float4(
            q.x * dq.x - q.y * dq.y - q.z * dq.z - q.w * dq.w,
            q.x * dq.y + q.y * dq.x + q.z * dq.w - q.w * dq.z,
            q.x * dq.z - q.y * dq.w + q.z * dq.x + q.w * dq.y,
            q.x * dq.w + q.y * dq.z - q.z * dq.y + q.w * dq.x);
        q = float4(
            q.x * q.x - q.y * q.y - q.z * q.z - q.w * q.w,
            2.0f * q.x * q.y,
            2.0f * q.x * q.z,
            2.0f * q.x * q.w) + c;
        float qq = dot(q, q);
        trap2 = min(trap2, qq);
        if (qq > threshold) { break; }
    }

    float r = max(length(q), 1e-6f);
    return float2(0.5f * r * log(r) / max(length(dq), 1e-9f), sqrt(trap2));
}

// params: [power, cX, cY, cZ] + [iterations]. Julia-mode Mandelbulb (fixed
// additive constant, NO +1 derivative term) — numerically identical to
// ReferenceDEs.mandelbulbJulia.
[[visible]] float2 de_mandelbulb_julia(float3 p, thread const ThreshDEContext& ctx)
{
    const float power = ctx.params[0];
    const float3 c = float3(ctx.params[1], ctx.params[2], ctx.params[3]);
    const int iterations = threshDEIterations(ctx);

    float3 z = p;
    float dr = 1.0f;
    float r = length(z);
    float trap = r;

    for (int i = 0; i < iterations; ++i) {
        r = length(z);
        trap = min(trap, r);
        if (r > 4.0f) { break; }
        float rSafe = max(r, 1e-9f);
        float theta = acos(clamp(z.z / rSafe, -1.0f, 1.0f)) * power;
        // atan2(0, 0): pin to the CPU (libm) value, see de_mandelbulb.
        float phi = (z.y == 0.0f && z.x == 0.0f) ? 0.0f : atan2(z.y, z.x) * power;
        float rp = pow(rSafe, power - 1.0f);   // r^power = r^(power-1) · r
        dr = rp * power * dr;
        float zr = rp * rSafe;
        z = zr * float3(sin(theta) * cos(phi), sin(phi) * sin(theta), cos(theta)) + c;
    }
    trap = min(trap, length(z));
    return float2(0.5f * log(max(r, 1e-9f)) * r / max(dr, 1e-9f), trap);
}

// ============================== the scene map ===============================
//
// THE single scene distance function (Invariant 7). March loop, tetrahedron
// normals, and AO all evaluate the identical pipeline:
//   (p', dScale) = applyPointOps(worldP * modelScale), dScale seeded modelScale
//   d = de(p', ctx).x / dScale          — a WORLD-space bound at any zoom
//   d = applyDistanceOps(worldP, d)     — hand/world-space ops stay unscaled
//
// modelScale (scaleCtx.z) is the zoom: model space shrinks relative to the
// world, positions scale in, distances divide back out (plan §6.3 —
// ScaleContext.swift is the CPU derivation site).

static float2 mapScene(float3 worldP,
                       constant ThreshFrameUniforms& U,
                       device const float* params,
                       device const ThreshWarpOp* ops,
                       visible_function_table<ThreshDE> deTable,
                       float iterScale = 1.0f)
{
    const float modelScale = U.scaleCtx.z;
    // Warp-stack gate: a specialized variant with an empty stack bakes this
    // FALSE and the compiler DCEs applyPointOps/applyDistanceOps entirely.
    // With an empty stack those loops are already no-ops, so the image is
    // unchanged (the generic path evaluates the same runtime condition).
    const bool hasOps = threshHasOps(U.meta.x);
    float dScale = modelScale;
    float3 q;
    if (hasOps) {
        q = applyPointOps(worldP * modelScale, ops, U.meta.x, dScale);
    } else {
        q = worldP * modelScale;
    }

    ThreshDEContext ctx;
    ctx.params = params + U.meta.w;          // DE param slice at deParamOffset
    ctx.paramCount = U.meta.z - U.meta.w;    // slice length (iterations last)
    ctx.time = U.scaleCtx.x;
    ctx.lodScale = U.scaleCtx.w * iterScale;

    // Specialization seam (GPUContext.makeSpecializedMarch): a pipeline
    // variant compiled with THRESH_SPEC_DE defined calls that DE DIRECTLY —
    // same translation unit, so the compiler inlines it across the march
    // loop, which the generic table dispatch structurally cannot. The
    // generic path below stays the always-correct fallback and the ONLY
    // path externals + debug kernels use.
#ifdef THRESH_SPEC_DE
    float2 de = THRESH_SPEC_DE(q, ctx);
#else
    float2 de = deTable[U.meta.y](q, ctx);
#endif
    float d = de.x / dScale;
    if (hasOps && threshHasDistOps(U.meta.x)) {
        d = applyDistanceOps(worldP, d, ops, U.meta.x);
    }
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
    // Identity fast paths (perf round 14): tonemap 0 / gamma 1 are the
    // catalog defaults — skip the ACES polynomial and the 3 pows there.
    // Branches are uniform across the frame (engine params), so no
    // divergence; results are identical at the defaults.
    if (tonemap > 0.0f) {
        c = mix(c, acesFilmic(c), clamp(tonemap, 0.0f, 1.0f));
    }
    if (gamma != 1.0f) {
        c = pow(max(c, 0.0f), float3(1.0f / max(gamma, 1e-3f)));
    }
    return clamp(c, 0.0f, 1.0f);
}

// Forward-difference normal of the SAME mapScene (Invariant 7 — never a
// second hand-unrolled gradient sweep). 3 taps against the hit point's own
// DE value d0 (perf round 12; was the 4-tap tetrahedron), evaluated at
// reduced fold iterations (perf round 10) — the normal needs local surface
// orientation, not full fold depth. Shading-only.
static float3 calcNormal(float3 pos, float h, float d0,
                         constant ThreshFrameUniforms& U,
                         device const float* params,
                         device const ThreshWarpOp* ops,
                         visible_function_table<ThreshDE> deTable)
{
    const float NI = 0.6f;
    float3 g = float3(
        mapScene(pos + float3(h, 0.0f, 0.0f), U, params, ops, deTable, NI).x,
        mapScene(pos + float3(0.0f, h, 0.0f), U, params, ops, deTable, NI).x,
        mapScene(pos + float3(0.0f, 0.0f, h), U, params, ops, deTable, NI).x) - d0;
    float len = length(g);
    return (len > 1e-12f) ? g / len : float3(0.0f, 1.0f, 0.0f);
}

// Cheap 5-tap ambient occlusion along the normal, scaled by aoStrength.
// `featureScale` = 1/modelScale — world-space size of a unit model feature
// (ScaleContext.swift): AO probes walk world distances, so they scale with it.
static float cheapAO(float3 pos, float3 n, float aoStrength, float featureScale,
                     constant ThreshFrameUniforms& U,
                     device const float* params,
                     device const ThreshWarpOp* ops,
                     visible_function_table<ThreshDE> deTable)
{
    // 2 probes (was 5 → 3 → 2, perf rounds 3/13): near + far occlusion
    // sample over the same [0.13, 0.61] walk, weights re-tuned to keep the
    // overall darkening in the original range. Shading-only.
    float h1 = 0.16f * featureScale;
    float h2 = 0.55f * featureScale;
    float d1 = mapScene(pos + n * h1, U, params, ops, deTable, 0.5f).x;
    float d2 = mapScene(pos + n * h2, U, params, ops, deTable, 0.5f).x;
    float occ = (h1 - d1) * 1.45f + (h2 - d2) * 0.65f;
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

// Shared march + shade body — the ONE implementation both the compute kernel
// (offscreen/interactive) and the stereo raster path (visionOS Compositor)
// call, so visual features cannot diverge per shell (plan §6.2, Invariant 8).
struct ThreshMarchResult {
    float4 color;   // linear rgba; NaN sentinel (1,0,1,0); miss = opaque black
    float  t;       // ray distance in WORLD units, clamped to maxDist on miss
    bool   hit;
    uint   steps;   // march steps taken (the caller adds to the stats atomic)
};

static inline ThreshMarchResult marchShade(
    float3 ro, float3 rd,
    constant ThreshFrameUniforms& U,
    device const float* params,
    device const ThreshWarpOp* ops,
    visible_function_table<ThreshDE> deTable,
    constant ThreshPalette& palette,
    float startT = 0.0f)   // hierarchical prepass hands a tile-safe depth
{
    // Engine params from the reserved slots of the FULL param table.
    const int maxSteps     = threshMaxSteps(int(params[THRESH_SLOT_MAX_STEPS]));
    const float maxDist    = params[THRESH_SLOT_MAX_DIST];
    const float stepSafety = params[THRESH_SLOT_STEP_SAFETY];
    const float aoStrength = params[THRESH_SLOT_AO_STRENGTH];
    const float epsBase    = U.scaleCtx.y;
    // World-space size of a unit model feature at this zoom — scales the
    // normal-probe floor and AO walk (mapScene returns WORLD distances).
    const float featureScale = 1.0f / max(U.scaleCtx.z, 1e-6f);

    float t = startT;
    float hitEps = 0.0f;
    float trap = 0.0f;
    float hitRadius = 0.0f;   // DE value at the accepted hit (normal center)
    bool hit = false;
    bool bad = false;
    uint steps = 0;

    // Enhanced sphere tracing (Keinert et al. 2014). `stepSafety` doubles as
    // the over-relaxation factor ω: at ω > 1 the march steps PAST the DE
    // sphere to cross empty space in fewer mapScene evaluations, and RETREATS
    // (falling back to plain tracing) whenever an over-step's sphere fails to
    // overlap the previous one — so a surface is never tunneled through. At
    // ω ≤ 1 (the default 0.9) the sorFail branch can never fire, so this is
    // bit-identical to a plain `t += dm.x * stepSafety` sphere trace.
    float omega = stepSafety;
    float prevRadius = 0.0f;
    float stepLength = 0.0f;

    for (int i = 0; i < maxSteps; ++i) {
        if (t > maxDist) { break; }   // loop-top: a prepass start at/near the
                                      // far plane must MISS, not sample there
        float3 pos = ro + rd * t;
        float2 dm = mapScene(pos, U, params, ops, deTable);
        steps += 1;
        // Non-finite guard by BIT PATTERN (exponent all-ones ⇒ Inf/NaN):
        // isnan/isinf fold to false under -ffinite-math-only (mathMode
        // .fast), which would silence the sentinel — integer classify
        // survives every math mode.
        if ((as_type<uint>(dm.x) & 0x7F800000u) == 0x7F800000u) {
            bad = true; break;
        }
        // Poisoned-start recovery (verified finding): a fractal DE is only
        // approximately Lipschitz-corrected under warp ops, so the tile
        // prepass can rarely overshoot INSIDE the surface — every pixel
        // would then false-hit at the frozen tile depth. A first sample
        // that is already inside (negative distance) restarts the ray from
        // the camera as if there were no prepass.
        if (i == 0 && t > 0.0f && dm.x < 0.0f && startT > 0.0f) {
            t = 0.0f;
            continue;
        }
        const float radius = dm.x;
        const bool sorFail = (omega > 1.0f) && (radius + prevRadius) < stepLength;
        if (sorFail) {
            stepLength -= omega * stepLength;   // undo the over-step (t retreats)
            omega = 1.0f;                        // conservative for the rest of the ray
        } else {
            stepLength = radius * omega;
        }
        prevRadius = radius;
        hitEps = epsBase * t;   // distance-proportional (cone) epsilon —
                                // scale-invariant: dm.x is already world-space
        if (!sorFail && radius < hitEps) {
            hit = true; trap = dm.y; hitRadius = radius; break;
        }
        t += stepLength;
        if (t > maxDist) { break; }
    }

    float4 color;
    if (bad) {
        color = float4(1.0f, 0.0f, 1.0f, 0.0f);              // NaN sentinel
    } else if (hit) {
        float3 pos = ro + rd * t;
        float nEps = max(hitEps, 1e-4f * featureScale);
        // Center value for the forward difference: the march's own DE value
        // at the hit. It is full-iteration while the taps are reduced — a
        // small constant bias that mostly normalizes away; costs zero taps.
        float3 n = calcNormal(pos, nEps, hitRadius, U, params, ops, deTable);
        float3 lightDir = normalize(float3(1.0f, 0.8f, 0.6f));
        float lambert = max(dot(n, lightDir), 0.0f);

        // Mapping (plan §5.5 stage 1): derive the palette coordinate t_map.
        // Depth/normal already land in 0..1; orbit trap is wrapped by the
        // sampler. Blend mixes trap with depth.
        float depth = clamp(t / max(maxDist, 1e-3f), 0.0f, 1.0f);
        float facing = clamp(0.5f + 0.5f * dot(n, -rd), 0.0f, 1.0f);
        int mapMode = threshMapMode(int(params[THRESH_SLOT_MAP_MODE]));
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
        // AO gate: skip the 5 mapScene taps when disabled (a specialized bake
        // of FALSE, or aoStrength == 0 — cheapAO returns exactly 1.0 there, so
        // this is bit-identical).
        float occ = threshAOEnabled(aoStrength)
            ? cheapAO(pos, n, aoStrength, featureScale, U, params, ops, deTable)
            : 1.0f;
        float3 lit = albedo * (lambert + 0.2f) * occ;
        color = float4(applyGrading(lit, params), 1.0f);
    } else {
        color = float4(0.0f, 0.0f, 0.0f, 1.0f);              // miss: black
    }

    ThreshMarchResult result;
    result.color = color;
    result.t = hit ? t : maxDist;
    result.hit = hit;
    result.steps = steps;
    return result;
}

// ------------------------- temporal-upscale aux path ------------------------
//
// The live Mac/iOS path renders at reduced resolution and reconstructs with
// MetalFX *temporal* upscaling, which needs per-pixel depth + motion and a
// sub-pixel-jittered projection. All of it is gated behind one function
// constant so the offscreen/golden path compiles to EXACTLY the same code as
// before (constant defaults to false; the aux arguments vanish).
//
// Buffer 7 / textures 1–2 are a private contract with SessionGPUEncoder
// (same standing as THRESH_BUFFER_DE_TABLE = 4) — not part of the ABI header.
constant bool thresh_aux_defined [[function_constant(0)]];
constant bool THRESH_AUX = is_function_constant_defined(thresh_aux_defined)
    ? thresh_aux_defined : false;
#define THRESH_BUFFER_AUX      7
#define THRESH_TEXTURE_DEPTH   1
#define THRESH_TEXTURE_MOTION  2

// Pixel-center → world ray direction for the compute path's pinhole model
// (one derivation for the per-pixel rays AND the tile prepass ray).
static inline float3 threshRayDir(float2 pixel, float w, float h,
                                  float aspect, float fovTan, float4 camQuat)
{
    const float2 ndc = float2(pixel.x / w * 2.0f - 1.0f,
                              1.0f - pixel.y / h * 2.0f);
    const float3 dirLocal = normalize(float3(ndc.x * aspect * fovTan,
                                             ndc.y * fovTan,
                                             -1.0f));
    return quatRotate(camQuat, dirLocal);
}

struct ThreshAuxUniforms {
    float4 prevCamPosFov;  // xyz previous camera position, w previous fovTan
    float4 prevCamQuat;    // previous camera orientation
    float4 jitter;         // xy sub-pixel jitter (input pixels), zw unused
};

kernel void march_offscreen(
    constant ThreshFrameUniforms& U          [[buffer(THRESH_BUFFER_UNIFORMS)]],
    device const float* params               [[buffer(THRESH_BUFFER_PARAMS)]],
    device const ThreshWarpOp* ops           [[buffer(THRESH_BUFFER_WARP_OPS)]],
    device atomic_uint* stats                [[buffer(THRESH_BUFFER_STATS)]],
    visible_function_table<ThreshDE> deTable [[buffer(THRESH_BUFFER_DE_TABLE)]],
    constant ThreshPalette& palette          [[buffer(THRESH_BUFFER_PALETTE)]],
    texture2d<float, access::write> outTex   [[texture(THRESH_TEXTURE_OUTPUT)]],
    constant ThreshAuxUniforms& aux          [[buffer(THRESH_BUFFER_AUX),
                                               function_constant(THRESH_AUX)]],
    texture2d<float, access::write> depthTex [[texture(THRESH_TEXTURE_DEPTH),
                                               function_constant(THRESH_AUX)]],
    texture2d<float, access::write> motionTex [[texture(THRESH_TEXTURE_MOTION),
                                                function_constant(THRESH_AUX)]],
    texture2d<float, access::read> coneTex   [[texture(THRESH_TEXTURE_CONE),
                                               function_constant(THRESH_CONE)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    const uint w = outTex.get_width();
    const uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    const float aspect = float(w) / float(h);
    const float fovTan = U.camPosFov.w;
    const float3 ro = U.camPosFov.xyz;

    // Hierarchical start (perf round 15): the coarse dispatch already
    // cone-marched this tile — start where it stopped. Every prepass step
    // was empty space for EVERY pixel ray in the tile (shared origin;
    // |p_pixel(t) − p_center(t)| = t·|rd_p − rd_c| ≤ coneK·t).
    float tileStart = 0.0f;
    if (THRESH_CONE) {
        tileStart = coneTex.read(gid / THRESH_CONE_TILE).x;
    }

    // Aux path: the jitter shifts this frame's sample point within the pixel
    // (the ray-gen equivalent of MetalFX's expected clip-space projection
    // translate); the scaler receives the same offset and removes it while
    // accumulating history into sub-pixel detail.
    float2 pixel = float2(gid) + 0.5f;
    if (THRESH_AUX) { pixel -= aux.jitter.xy; }
    const float3 rd = threshRayDir(pixel, float(w), float(h),
                                   aspect, fovTan, U.camQuat);

    ThreshMarchResult m = marchShade(ro, rd, U, params, ops, deTable, palette,
                                     tileStart);

    // Per-thread step count added ONCE into the device stats counter
    // (baked off in benchmark variants — pure telemetry).
    if (threshStatsEnabled()) {
        atomic_fetch_add_explicit(&stats[0], m.steps, memory_order_relaxed);
    }

    outTex.write(m.color, gid);

    if (THRESH_AUX) {
        // Depth: linear 0 (near) … 1 (far) against the march far threshold —
        // monotonic is all the scaler's disocclusion logic needs.
        const float maxDist = max(params[THRESH_SLOT_MAX_DIST], 1e-6f);
        depthTex.write(float4(saturate(m.t / maxDist), 0.0f, 0.0f, 0.0f), gid);

        // Motion: where this frame's hit point sat LAST frame, in input
        // pixels (y-down), previous − current, both ends UNJITTERED. A miss
        // uses the far point along the ray, so camera rotation still tracks
        // the background instead of tearing history at silhouettes.
        const float3 worldPos = ro + rd * m.t;
        const float3 v = worldPos - aux.prevCamPosFov.xyz;
        const float4 prevQ = aux.prevCamQuat;
        const float3 local = quatRotate(float4(-prevQ.xyz, prevQ.w), v);
        float2 motion = float2(0.0f);
        if (local.z < -1e-6f) {
            const float prevFovTan = max(aux.prevCamPosFov.w, 1e-6f);
            const float2 pndc = float2(
                local.x / (-local.z * aspect * prevFovTan),
                local.y / (-local.z * prevFovTan));
            const float2 prevPixel = float2(
                (pndc.x + 1.0f) * 0.5f * float(w),
                (1.0f - pndc.y) * 0.5f * float(h));
            motion = prevPixel - (float2(gid) + 0.5f);
        }
        motionTex.write(float4(motion, 0.0f, 0.0f), gid);
    }
}

// ---------------------- hierarchical cone prepass ---------------------------
//
// One thread per 8x8 output tile: cone-march the tile's central ray with an
// acceptance radius covering the tile's whole angular footprint (coneK·t) and
// write the safe start depth. Fully parallel — no intra-group serialization;
// the fine kernel reads the result (function constant 8 gates both sides).
// dims buffer (private contract with OffscreenRenderer, buffer 8): the FULL
// output w/h — the coarse texture's own dims are rounded up and cannot
// reproduce exact ray directions.
kernel void march_cone_prepass(
    constant ThreshFrameUniforms& U          [[buffer(THRESH_BUFFER_UNIFORMS)]],
    device const float* params               [[buffer(THRESH_BUFFER_PARAMS)]],
    device const ThreshWarpOp* ops           [[buffer(THRESH_BUFFER_WARP_OPS)]],
    visible_function_table<ThreshDE> deTable [[buffer(THRESH_BUFFER_DE_TABLE)]],
    constant uint2& fullDims                 [[buffer(THRESH_BUFFER_CONE_DIMS)]],
    texture2d<float, access::write> coneTex  [[texture(THRESH_TEXTURE_CONE)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    const uint cw = coneTex.get_width();
    const uint ch = coneTex.get_height();
    if (gid.x >= cw || gid.y >= ch) { return; }

    const float w = float(fullDims.x);
    const float h = float(fullDims.y);
    const float aspect = w / h;
    const float fovTan = U.camPosFov.w;
    const float3 ro = U.camPosFov.xyz;

    const float2 base = float2(gid) * float(THRESH_CONE_TILE);
    const float2 centerPx = base + 0.5f * float(THRESH_CONE_TILE);
    const float3 rdC = threshRayDir(centerPx, w, h, aspect, fovTan, U.camQuat);

    // Angular spread bound: max deviation of the tile's corner rays (±1 px
    // beyond the corners to cover the aux path's sub-pixel jitter) + 10%.
    float coneK = 0.0f;
    for (int cy = 0; cy <= 1; ++cy) {
        for (int cx = 0; cx <= 1; ++cx) {
            const float2 px = base
                + float2(cx, cy) * (float(THRESH_CONE_TILE) + 2.0f) - 1.0f;
            const float3 rdX = threshRayDir(px, w, h, aspect, fovTan, U.camQuat);
            coneK = max(coneK, length(rdX - rdC));
        }
    }
    coneK *= 1.1f;

    const float maxDist = params[THRESH_SLOT_MAX_DIST];
    const float epsBase = U.scaleCtx.y;
    float t = 0.0f;
    for (int i = 0; i < 48; ++i) {
        float d = mapScene(ro + rdC * t, U, params, ops, deTable).x;
        // Bit-pattern non-finite test — survives mathMode .fast (see march).
        if ((as_type<uint>(d) & 0x7F800000u) == 0x7F800000u) {
            t = 0.0f; break;                             // fall back: no skip
        }
        // Largest Δt keeping the WHOLE advanced cone segment inside the
        // empty sphere: Δ + coneK·(t+Δ) ≤ d.
        const float slack = d - coneK * t;
        // Stop ABOVE the fine march's hit epsilon (verified finding: an equal
        // threshold lets edge pixels immediate-hit at the tile-shared depth —
        // 8×8-quantized silhouettes). The margin (Cone Stability) leaves the
        // per-pixel march refinement room; larger = less shimmer, slightly
        // slower.
        if (slack <= threshConeMargin() * epsBase * t) { break; }
        t += slack * 0.9f / (1.0f + coneK);
        if (t > maxDist) { t = maxDist; break; }
    }
    coneTex.write(float4(t, 0.0f, 0.0f, 0.0f), gid);
}

// ========================== stereo raster path ==============================
//
// The visionOS Compositor shell (and its Mac-hosted parity test) renders the
// SAME march through a fullscreen triangle: one vertex amplification per
// drawable view, per-view ThreshViewUniforms for ray generation, and a
// [[depth(any)]] write so the compositor's reprojection gets real geometry.
//
// Ray generation is projection-agnostic: two NDC points unproject through
// invProj and their difference is the view-local ray — correct for any
// asymmetric/reverse-Z/infinite-far Compositor projection. The interpolated
// `ndc` varying is in LOGICAL coordinates, so foveated rendering (variable
// rasterization rate) yields correct rays with no rate-map decode here.

struct ThreshViewVertexOut {
    float4 position [[position]];
    float2 ndc;
    ushort viewIndex [[render_target_array_index]];
    ushort ampIndex  [[flat]];
};

// View-local ray direction for a logical NDC point — the ONE derivation the
// fragment AND the per-view cone prepass share (unproject two points through
// this view's invProj; camera looks down -Z). Projection-convention-agnostic.
static inline float3 threshViewDirLocal(float4x4 invProj, float2 ndc) {
    const float4 h0 = invProj * float4(ndc, 0.25f, 1.0f);
    const float4 h1 = invProj * float4(ndc, 0.75f, 1.0f);
    float3 dirLocal = normalize(h1.xyz / h1.w - h0.xyz / h0.w);
    if (dirLocal.z > 0.0f) { dirLocal = -dirLocal; }
    return dirLocal;
}

vertex ThreshViewVertexOut thresh_fullscreen_vertex(
    uint vid   [[vertex_id]],
    ushort amp [[amplification_id]])
{
    // One triangle covering NDC: (-1,-1) (3,-1) (-1,3).
    const float2 pos = float2(vid == 1 ? 3.0f : -1.0f,
                              vid == 2 ? 3.0f : -1.0f);
    ThreshViewVertexOut out;
    out.position = float4(pos, 0.5f, 1.0f);
    out.ndc = pos;
    out.viewIndex = amp;
    out.ampIndex = amp;
    return out;
}

struct ThreshFragmentOut {
    float4 color [[color(0)]];
    float  depth [[depth(any)]];
};

fragment ThreshFragmentOut thresh_march_fragment(
    ThreshViewVertexOut in                     [[stage_in]],
    constant ThreshFrameUniforms& U            [[buffer(THRESH_BUFFER_UNIFORMS)]],
    device const float* params                 [[buffer(THRESH_BUFFER_PARAMS)]],
    device const ThreshWarpOp* ops             [[buffer(THRESH_BUFFER_WARP_OPS)]],
    device atomic_uint* stats                  [[buffer(THRESH_BUFFER_STATS)]],
    visible_function_table<ThreshDE> deTable   [[buffer(THRESH_BUFFER_DE_TABLE)]],
    constant ThreshPalette& palette            [[buffer(THRESH_BUFFER_PALETTE)]],
    device const ThreshViewUniforms* views     [[buffer(THRESH_BUFFER_VIEWS)]],
    // Per-view cone-prepass depths (perf block 11), THRESH_CONE-gated so the
    // generic raster pipeline never binds it. One array slice per amplified
    // view; indexed by the fragment's LOGICAL tile (in.ndc → tile), which is
    // foveation-agnostic — the interpolated ndc is in logical coordinates.
    texture2d_array<float, access::read> coneTex [[texture(THRESH_TEXTURE_CONE),
                                                   function_constant(THRESH_CONE)]])
{
    const ThreshViewUniforms view = views[in.ampIndex];

    float3 dirLocal = threshViewDirLocal(view.invProj, in.ndc);
    const float roomScale = max(view.originScale.w, 1e-6f);
    const float3 ro = view.originScale.xyz;
    const float3 rd = quatRotate(view.orient, dirLocal);

    // Hierarchical start: this fragment's logical tile was cone-marched by
    // march_cone_prepass_view. tuv maps ndc→[0,1] the SAME way the prepass
    // lays out its texels (centerNdc = (texel+0.5)/dims·2−1).
    float startT = 0.0f;
    if (THRESH_CONE) {
        const float2 tuv = clamp(in.ndc * 0.5f + 0.5f, 0.0f, 1.0f);
        const uint cw = coneTex.get_width();
        const uint ch = coneTex.get_height();
        const uint2 tile = uint2(min(uint(tuv.x * float(cw)), cw - 1u),
                                 min(uint(tuv.y * float(ch)), ch - 1u));
        startT = coneTex.read(tile, uint(in.ampIndex)).x;
    }

    ThreshMarchResult m = marchShade(ro, rd, U, params, ops, deTable, palette,
                                     startT);
    if (threshStatsEnabled()) {
        atomic_fetch_add_explicit(&stats[0], m.steps, memory_order_relaxed);
    }

    // Depth consistent with THIS view's projection: the hit point (or the
    // far threshold on a miss) back in view-local meters.
    const float4 clip = view.proj * float4(dirLocal * (m.t / roomScale), 1.0f);

    ThreshFragmentOut out;
    // Shell presentation semantics: the compositor composites this layer
    // over PASSTHROUGH (mixed immersion), so a miss is transparent — the
    // fractal floats in the user's room. The compute shells keep opaque
    // black (a window has nothing behind it). Shading is identical
    // (CompositorParityTests compares RGB); only the miss alpha differs.
    out.color = m.hit ? m.color : float4(0.0f);
    out.depth = clamp(clip.z / max(clip.w, 1e-9f), 0.0f, 1.0f);
    return out;
}

// ----------------------- per-view compute march -----------------------------
//
// The COMPUTE alternative to thresh_march_fragment (ADR-001 "compute phase
// 2", perf block 13): the identical per-view ray model and presentation
// semantics, dispatched as a compute grid (w, h, viewCount) instead of a
// rasterized fullscreen triangle. Color and clip-depth land in intermediate
// texture arrays the encoder blits into the drawable — compositor drawables
// don't expose compute-write usage, and depth formats are never compute-
// writable (depth goes through an r32Float ↔ depth32Float blit, a documented
// copy-compatible pair).
//
// Trade against the fragment path (why this is an OPTION, not the default):
// compute cannot consume rasterization rate maps, so the foveated-rendering
// win is unavailable — the backend choice is made at layer configuration
// (foveation off). What compute may win back: threadgroup-coherent scheduling
// of the march and freedom from fragment-interlock overheads. Device A/B is
// the point.
//
// Texture 4 (depth out) is a private contract with ViewComputeEncoder — same
// standing as THRESH_TEXTURE_CONE.
#define THRESH_TEXTURE_VIEW_DEPTH 4

kernel void march_view_compute(
    constant ThreshFrameUniforms& U          [[buffer(THRESH_BUFFER_UNIFORMS)]],
    device const float* params               [[buffer(THRESH_BUFFER_PARAMS)]],
    device const ThreshWarpOp* ops           [[buffer(THRESH_BUFFER_WARP_OPS)]],
    device atomic_uint* stats                [[buffer(THRESH_BUFFER_STATS)]],
    visible_function_table<ThreshDE> deTable [[buffer(THRESH_BUFFER_DE_TABLE)]],
    constant ThreshPalette& palette          [[buffer(THRESH_BUFFER_PALETTE)]],
    device const ThreshViewUniforms* views   [[buffer(THRESH_BUFFER_VIEWS)]],
    texture2d_array<float, access::write> outColor [[texture(THRESH_TEXTURE_OUTPUT)]],
    texture2d_array<float, access::write> outDepth [[texture(THRESH_TEXTURE_VIEW_DEPTH)]],
    texture2d_array<float, access::read> coneTex   [[texture(THRESH_TEXTURE_CONE),
                                                     function_constant(THRESH_CONE)]],
    uint3 gid                                [[thread_position_in_grid]])
{
    const uint w = outColor.get_width();
    const uint h = outColor.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    const ThreshViewUniforms view = views[gid.z];

    // Pixel center → NDC (y up) — the compute mirror of the fragment's
    // interpolated `in.ndc` for this pixel; then the SAME two-point
    // unproject through this view's projection.
    const float2 ndc = float2(
        (float(gid.x) + 0.5f) / float(w) * 2.0f - 1.0f,
        1.0f - (float(gid.y) + 0.5f) / float(h) * 2.0f);
    float3 dirLocal = threshViewDirLocal(view.invProj, ndc);
    const float roomScale = max(view.originScale.w, 1e-6f);
    const float3 ro = view.originScale.xyz;
    const float3 rd = quatRotate(view.orient, dirLocal);

    // Hierarchical start: same logical-NDC tile map as the fragment.
    float startT = 0.0f;
    if (THRESH_CONE) {
        const float2 tuv = clamp(ndc * 0.5f + 0.5f, 0.0f, 1.0f);
        const uint cw = coneTex.get_width();
        const uint ch = coneTex.get_height();
        const uint2 tile = uint2(min(uint(tuv.x * float(cw)), cw - 1u),
                                 min(uint(tuv.y * float(ch)), ch - 1u));
        startT = coneTex.read(tile, gid.z).x;
    }

    ThreshMarchResult m = marchShade(ro, rd, U, params, ops, deTable, palette,
                                     startT);
    if (threshStatsEnabled()) {
        atomic_fetch_add_explicit(&stats[0], m.steps, memory_order_relaxed);
    }

    // Raster-shell presentation semantics: miss = transparent (the compositor
    // composites over passthrough), and depth in THIS view's projection —
    // identical formulas to thresh_march_fragment.
    const float4 clip = view.proj * float4(dirLocal * (m.t / roomScale), 1.0f);
    outColor.write(m.hit ? m.color : float4(0.0f), gid.xy, gid.z);
    outDepth.write(
        float4(clamp(clip.z / max(clip.w, 1e-9f), 0.0f, 1.0f), 0.0f, 0.0f, 0.0f),
        gid.xy, gid.z);
}

// -------------------- per-view hierarchical cone prepass --------------------
//
// The raster counterpart of march_cone_prepass: one thread per (tile, view).
// Each thread cone-marches its LOGICAL tile's central ray — generated through
// the view's invProj/orient exactly as the fragment does — and writes the
// tile-safe start depth to that view's array slice. The fragment reads its
// tile from in.ndc. Everything is in logical NDC space, so foveation (variable
// rasterization rate) needs no rate-map decode: a "tile" is a fixed NDC rect.
//
// grid: (coneW, coneH, viewCount). views[gid.z] is this thread's view. In the
// dedicated (non-amplified) layout the encoder binds the views buffer at the
// per-view offset, so gid.z stays 0 and views[0] is that eye.
kernel void march_cone_prepass_view(
    constant ThreshFrameUniforms& U          [[buffer(THRESH_BUFFER_UNIFORMS)]],
    device const float* params               [[buffer(THRESH_BUFFER_PARAMS)]],
    device const ThreshWarpOp* ops           [[buffer(THRESH_BUFFER_WARP_OPS)]],
    visible_function_table<ThreshDE> deTable [[buffer(THRESH_BUFFER_DE_TABLE)]],
    device const ThreshViewUniforms* views   [[buffer(THRESH_BUFFER_VIEWS)]],
    texture2d_array<float, access::write> coneTex [[texture(THRESH_TEXTURE_CONE)]],
    uint3 gid                                [[thread_position_in_grid]])
{
    const uint cw = coneTex.get_width();
    const uint ch = coneTex.get_height();
    if (gid.x >= cw || gid.y >= ch) { return; }

    const ThreshViewUniforms view = views[gid.z];
    const float3 ro = view.originScale.xyz;
    const float2 inv = float2(1.0f / float(cw), 1.0f / float(ch));

    // Central ray of this texel's NDC rectangle.
    const float2 centerNdc = (float2(gid.xy) + 0.5f) * inv * 2.0f - 1.0f;
    const float3 rdC = quatRotate(view.orient,
                                  threshViewDirLocal(view.invProj, centerNdc));

    // Angular footprint: max deviation over the four texel corners, pushed a
    // quarter-texel OUTWARD for coverage margin, + 10% (matches the compute
    // prepass's corner-bound construction).
    float coneK = 0.0f;
    for (int cy = 0; cy <= 1; ++cy) {
        for (int cx = 0; cx <= 1; ++cx) {
            const float2 outward = (float2(cx, cy) * 2.0f - 1.0f) * 0.25f;
            const float2 cNdc =
                (float2(gid.xy) + float2(cx, cy) + outward) * inv * 2.0f - 1.0f;
            const float3 rdX = quatRotate(view.orient,
                                          threshViewDirLocal(view.invProj, cNdc));
            coneK = max(coneK, length(rdX - rdC));
        }
    }
    coneK *= 1.1f;

    const float maxDist = params[THRESH_SLOT_MAX_DIST];
    const float epsBase = U.scaleCtx.y;
    float t = 0.0f;
    for (int i = 0; i < 48; ++i) {
        float d = mapScene(ro + rdC * t, U, params, ops, deTable).x;
        if ((as_type<uint>(d) & 0x7F800000u) == 0x7F800000u) {
            t = 0.0f; break;                             // non-finite: no skip
        }
        const float slack = d - coneK * t;
        if (slack <= threshConeMargin() * epsBase * t) { break; }  // Cone Stability
        t += slack * 0.9f / (1.0f + coneK);
        if (t > maxDist) { t = maxDist; break; }
    }
    coneTex.write(float4(t, 0.0f, 0.0f, 0.0f), gid.xy, gid.z);
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
