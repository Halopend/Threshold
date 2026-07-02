// ThresholdShaderABI.h — the CPU↔GPU contract.
//
// This header is compiled as C (imported by Swift) and as MSL (prepended to
// runtime-compiled shader source). It is the ONLY definition of the structs
// that cross the CPU→GPU boundary. Layout rules are enforced by the static
// asserts at the bottom on both compilers.
//
// ABI evolution: bump THRESHOLD_ABI_VERSION on any layout or semantic change.
// Never reorder or renumber existing enum values — they persist in scene files.

#ifndef THRESHOLD_SHADER_ABI_H
#define THRESHOLD_SHADER_ABI_H

#define THRESHOLD_ABI_VERSION 1

#ifdef __METAL_VERSION__
  #include <metal_stdlib>
  #define THRESH_FLOAT4 float4
  #define THRESH_UINT4  uint4
  #define THRESH_UINT   uint
  #define THRESH_STATIC_ASSERT(cond, msg) static_assert(cond, msg)
#else
  #include <simd/simd.h>
  #include <stdint.h>
  #include <assert.h>
  #define THRESH_FLOAT4 simd_float4
  #define THRESH_UINT4  simd_uint4
  #define THRESH_UINT   uint32_t
  #define THRESH_STATIC_ASSERT(cond, msg) _Static_assert(cond, msg)
#endif

// ---------------------------------------------------------------------------
// Warp op kinds. Values < 64 are POINT ops (transform the sample point before
// the DE runs). Values >= 64 are DISTANCE ops (operate on the resolved SDF
// value after the DE runs, using the untransformed world-space point).
// Exact math for every kind is specified in docs/op-semantics.md; the CPU
// reference (ThresholdShaderIR) and the MSL interpreter (ThresholdRender)
// both implement that document and are cross-checked by sampled-equivalence
// tests.
// ---------------------------------------------------------------------------

typedef enum ThreshWarpKind {
    ThreshWarpKindNone         = 0,
    // Bend & Wave
    ThreshWarpKindTwist        = 1,
    ThreshWarpKindBend         = 2,
    ThreshWarpKindRipple       = 3,
    // Mirrors & Folds
    ThreshWarpKindMirror       = 4,
    ThreshWarpKindBoxFold      = 5,
    ThreshWarpKindPlaneFold    = 6,
    ThreshWarpKindKaleidoscope = 7,
    ThreshWarpKindCoxeter      = 8,
    ThreshWarpKindMengerFold   = 9,
    ThreshWarpKindOffsetFold   = 10,
    // Spherical & Radial
    ThreshWarpKindSphereFold   = 11,
    ThreshWarpKindSphereInvert = 12,
    ThreshWarpKindTubeFold     = 13,
    ThreshWarpKindShells       = 14,
    // Self-Similar Repeats
    ThreshWarpKindScaleRepeat  = 15,
    ThreshWarpKindTiling       = 16,
    ThreshWarpKindScale        = 17,
    // Space projection
    ThreshWarpKindSphereProject = 18,
    // --- distance-space ops (>= 64) ---
    ThreshWarpKindHandAttract  = 64,
    ThreshWarpKindForearmCarve = 65,
    ThreshWarpKindBounding     = 66,
} ThreshWarpKind;

#define THRESH_WARP_KIND_DISTANCE_OP_BASE 64u

// Per-instance flag bits (WarpOp.flags). Kind-specific meaning where noted.
#define THRESH_WARP_FLAG_OPTION_A  (1u << 0)  // BoxFold: Hall of Mirrors; HandAttract: pocket enabled

// ---------------------------------------------------------------------------
// WarpOp — 48 bytes, 16-aligned. ADR-002.
// ---------------------------------------------------------------------------

typedef struct ThreshWarpOp {
    THRESH_UINT   kind;      // ThreshWarpKind
    THRESH_UINT   flags;     // THRESH_WARP_FLAG_*
    float         strength;  // master amount; semantics per kind (docs/op-semantics.md)
    float         _pad0;
    THRESH_FLOAT4 a;         // per-kind payload
    THRESH_FLOAT4 b;         // per-kind payload
} ThreshWarpOp;

// ---------------------------------------------------------------------------
// FrameUniforms — the ONLY by-value data per frame. Hard cap 64 bytes (CI).
// Everything else crosses as pointer+count in the argument buffers.
// ---------------------------------------------------------------------------

typedef struct ThreshFrameUniforms {
    THRESH_FLOAT4 camPosFov;  // xyz camera position, w = tan(fovY/2)
    THRESH_FLOAT4 camQuat;    // orientation quaternion (x,y,z,w), rotates -Z forward
    THRESH_FLOAT4 scaleCtx;   // x = time, y = epsilonBase, z = modelScale, w = lodScale
    THRESH_UINT4  meta;       // x = opCount, y = deIndex, z = paramCount, w = deParamOffset
} ThreshFrameUniforms;

// ---------------------------------------------------------------------------
// Reserved engine slots in the resolved param table. The catalog registers
// engine params at these fixed slots so the kernel can read them without
// knowing catalog registration order. Slots [0, THRESH_SLOT_ENGINE_COUNT)
// are engine-reserved; catalog content params start after.
// ---------------------------------------------------------------------------

#define THRESH_SLOT_MAX_STEPS     0   // march step cap (as float)
#define THRESH_SLOT_MAX_DIST      1   // far threshold
#define THRESH_SLOT_STEP_SAFETY   2   // global step scale (0..1], default 0.9
#define THRESH_SLOT_ITERATIONS    3   // DE iteration cap (as float)
#define THRESH_SLOT_AO_STRENGTH   4
#define THRESH_SLOT_SHADOW_SOFT   5
#define THRESH_SLOT_ENGINE_COUNT  16

// ---------------------------------------------------------------------------
// Buffer/texture binding indices for the march kernel.
// ---------------------------------------------------------------------------

#define THRESH_BUFFER_UNIFORMS    0   // ThreshFrameUniforms, by-value (setBytes)
#define THRESH_BUFFER_PARAMS     1   // device const float*  (resolved param table)
#define THRESH_BUFFER_WARP_OPS   2   // device const ThreshWarpOp*
#define THRESH_BUFFER_STATS      3   // device atomic_uint*  (total march steps)
#define THRESH_TEXTURE_OUTPUT    0

// ---------------------------------------------------------------------------
// DE ABI (MSL side only — contains a device pointer).
// Every distance estimator, built-in or external, is a [[visible]] function:
//
//   float2 de_<name>(float3 p, thread const ThreshDEContext& ctx)
//     .x = distance estimate, .y = orbit trap / material channel
//
// linked through a visible function table indexed by FrameUniforms.meta.y.
// ---------------------------------------------------------------------------

#ifdef __METAL_VERSION__
struct ThreshDEContext {
    device const float* params;   // DE param slice: params + meta.w
    uint  paramCount;
    float time;
    float lodScale;
};
#endif

// ---------------------------------------------------------------------------
// Layout asserts — fire at compile time on BOTH compilers. ADR-002 / plan §9.
// ---------------------------------------------------------------------------

THRESH_STATIC_ASSERT(sizeof(ThreshWarpOp) == 48, "WarpOp must be exactly 48 bytes");
THRESH_STATIC_ASSERT(sizeof(ThreshFrameUniforms) == 64, "FrameUniforms must be exactly 64 bytes");

#endif // THRESHOLD_SHADER_ABI_H
