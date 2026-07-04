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

#define THRESHOLD_ABI_VERSION 2

#ifdef __METAL_VERSION__
  #include <metal_stdlib>
  #define THRESH_FLOAT4   float4
  #define THRESH_FLOAT4X4 metal::float4x4
  #define THRESH_UINT4    uint4
  #define THRESH_UINT     uint
  #define THRESH_STATIC_ASSERT(cond, msg) static_assert(cond, msg)
#else
  #include <simd/simd.h>
  #include <stdint.h>
  #include <assert.h>
  #define THRESH_FLOAT4   simd_float4
  #define THRESH_FLOAT4X4 simd_float4x4
  #define THRESH_UINT4    simd_uint4
  #define THRESH_UINT     uint32_t
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
// Hand-drive flags (plan §4.3 spatial path): CPU-side markers — the shell
// stamps the op's geometry fields from live hand joints each frame before
// encode (HandOpStamper). The kernel never reads them. An op without a drive
// flag is an ordinary slider-driven op (the mandated non-hand control path).
#define THRESH_WARP_FLAG_DRIVE_RIGHT (1u << 1)  // geometry follows the RIGHT hand
#define THRESH_WARP_FLAG_DRIVE_LEFT  (1u << 2)  // geometry follows the LEFT hand

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
// Color: mapping + palette-sampling controls + the grading chain (plan §5.5).
// All are ordinary catalog scalars (.scene-persisted, music-bindable) that
// resolve into these fixed slots so the kernel reads them positionally. The
// palette STOPS themselves are scene content and travel in a separate buffer
// (ThreshPalette), not the param table.
#define THRESH_SLOT_GRAD_REPEAT   6   // palette repeat count (>= 1)
#define THRESH_SLOT_GRAD_OFFSET   7   // palette phase offset (wraps), music/anim bindable
#define THRESH_SLOT_GRAD_SMOOTH   8   // stop-edge smoothing 0..1
#define THRESH_SLOT_MAP_MODE      9   // ThreshColorMapMode (as float)
#define THRESH_SLOT_SATURATION    10  // 0 = grayscale, 1 = identity, >1 boosts
#define THRESH_SLOT_CONTRAST      11  // pivoted at 0.5; 1 = identity
#define THRESH_SLOT_VIBRANCE      12  // saturation lift weighted toward low-sat pixels
#define THRESH_SLOT_BRIGHTNESS    13  // linear gain, 1 = identity
#define THRESH_SLOT_GAMMA         14  // output gamma exponent, 1 = identity
#define THRESH_SLOT_TONEMAP       15  // ACES filmic blend 0..1, 0 = plain clamp (default)
// Safety bubble (legacy "safe space"): a CSG-subtracted shape carved around the
// camera so scenes can never bury the viewer inside geometry — the fix for the
// mandelboxSphereProjection family whose r→0 projection singularity otherwise
// fills the frame. Applied to the final march distance at the camera center.
// Disabled by default (BUBBLE_ENABLED = 0) so authored scenes are untouched.
#define THRESH_SLOT_BUBBLE_ENABLED 16  // 1 = carve the bubble, 0 = identity
#define THRESH_SLOT_BUBBLE_RADIUS  17  // carve radius in fractal units
#define THRESH_SLOT_BUBBLE_SHAPE   18  // 0..1 sphere→cube morph; 2..6 platonic solids
#define THRESH_SLOT_BUBBLE_BLEND   19  // strength / temporal blend 0..1 (legacy "blend")
#define THRESH_SLOT_ENGINE_COUNT  20

// Color mapping mode: how the palette coordinate t in [0,1] is derived per
// pixel (plan §5.5 stage 1). Values persist in scenes — never renumber.
typedef enum ThreshColorMapMode {
    ThreshColorMapOrbitTrap = 0,  // DE .y orbit-trap channel (classic default)
    ThreshColorMapDepth     = 1,  // normalized ray depth (t / maxDist)
    ThreshColorMapNormal    = 2,  // facing ratio from the surface normal
    ThreshColorMapBlend     = 3,  // 0.5*(trap) + 0.5*(depth)
} ThreshColorMapMode;

// ---------------------------------------------------------------------------
// Palette — scene content (up to 8 RGB gradient stops), uploaded as its own
// buffer. Sampled at the mapped coordinate t with the repeat/offset/smoothing
// scalars above. Stops are pre-sorted by position on the CPU side.
// ---------------------------------------------------------------------------

#define THRESH_MAX_GRADIENT_STOPS 8

typedef struct ThreshPalette {
    THRESH_UINT   stopCount;   // 1..THRESH_MAX_GRADIENT_STOPS; 0 → identity gray
    THRESH_UINT   _pad0;
    THRESH_UINT   _pad1;
    THRESH_UINT   _pad2;
    THRESH_FLOAT4 stops[THRESH_MAX_GRADIENT_STOPS];  // .xyz = linear rgb, .w = position 0..1
} ThreshPalette;

// ---------------------------------------------------------------------------
// Per-view uniforms for the stereo raster path (visionOS Compositor shell).
// One entry per drawable view; the frame's shared state stays in
// ThreshFrameUniforms (the 64-byte cap is untouched). Ray generation is
// projection-convention-agnostic: the fragment unprojects two NDC points
// through invProj and normalizes their difference, so any Compositor
// projection (reverse-Z, infinite far, asymmetric frusta) yields correct
// rays. `proj` is the SAME matrix forward — the depth the fragment writes is
// consistent with the compositor's reprojection by construction.
// ---------------------------------------------------------------------------

typedef struct ThreshViewUniforms {
    THRESH_FLOAT4X4 proj;         // view-local -> clip (depth write)
    THRESH_FLOAT4X4 invProj;      // clip -> view-local (ray generation)
    THRESH_FLOAT4   originScale;  // xyz = eye origin in FRACTAL world,
                                  //   w = room meters -> fractal units scale
    THRESH_FLOAT4   orient;       // quaternion view-local -> fractal world
} ThreshViewUniforms;

// ---------------------------------------------------------------------------
// Buffer/texture binding indices for the march kernel.
// ---------------------------------------------------------------------------

#define THRESH_BUFFER_UNIFORMS    0   // ThreshFrameUniforms, by-value (setBytes)
#define THRESH_BUFFER_PARAMS     1   // device const float*  (resolved param table)
#define THRESH_BUFFER_WARP_OPS   2   // device const ThreshWarpOp*
#define THRESH_BUFFER_STATS      3   // device atomic_uint*  (total march steps)
// index 4 is the DE visible-function table (GPUContext.deTableBufferIndex,
// not an ABI-header constant — it is bound by the Swift encoder).
#define THRESH_BUFFER_PALETTE    5   // ThreshPalette, by-value (setBytes)
#define THRESH_BUFFER_VIEWS      6   // device const ThreshViewUniforms* (raster path)
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
THRESH_STATIC_ASSERT(sizeof(ThreshPalette) == 16 + 16 * THRESH_MAX_GRADIENT_STOPS,
                     "Palette must be 16-byte header + 16B per stop, 16-aligned");
THRESH_STATIC_ASSERT(sizeof(ThreshViewUniforms) == 160,
                     "ViewUniforms must be two 4x4 matrices + two float4s");

#endif // THRESHOLD_SHADER_ABI_H
