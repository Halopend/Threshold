// LegacyFormulaShim.swift — adapts ORIGINAL-app embedded formulas
// (`embeddedFormula.metalSource`, written against the original's
// FormulaParams/OrbitData ABI) to the rebuild's external-DE ABI
// (`de_main(float3, ThreshDEContext)`) by wrapping the untouched legacy
// source between a compatibility prelude and a generated entry point.
//
// The legacy convention is load-bearing: every formula defines
// `DE_<functionStem>(pos, fp, rot, iterations, colorIterations, orbit)`
// (plus helpers that live inside its own source). The prelude recreates the
// original's small shared surface (FractalFormulaCommon.h, captured from
// TEMP/MetalRaymarch-main); the trailer builds FormulaParams from the
// rebuild's param slice (iterations LAST, plan §5.1) and returns
// (distance, √trap) — the original's trap was minimum r².
//
// Rotation matrices: the original precomputed rotMatrix1/2 CPU-side from
// per-formula rotation params; no corpus scene sets them, so the shim pins
// identity (rotationFlags = 0). A later pass can surface them as params.

public enum LegacyFormulaShim {
    /// The original's shared helper surface, recreated. Everything else a
    /// formula needs lives inside its own metalSource.
    public static let prelude = """
    // ---- Threshold legacy-formula compatibility shim (migration 0 -> 1) ----
    #define FORCE_INLINE inline
    constant float kEpsLen   = 1e-16f;
    constant float kEpsAcos  = 1e-8f;
    constant float kLn2      = 0.6931471805599453f;
    constant float kLog2_10  = 3.32192809488736234787f;
    struct FormulaParams {
        float params[16];
        float3x3 rotMatrix1;
        float3x3 rotMatrix2;
        uint rotationFlags;
    };
    struct OrbitData {
        float trap;
        int   trapIteration;
        float3 trapPosition;
        float3 finalP;
        int   iterationsUsed;
    };
    inline bool hasRot1Precomputed(FormulaParams fp) { return (fp.rotationFlags & 1u) != 0u; }
    inline bool hasRot2Precomputed(FormulaParams fp) { return (fp.rotationFlags & 2u) != 0u; }
    inline void UpdateTrapMinR2(thread float& trap, thread int& trapIter, thread float3& trapPos,
                                float r2, int i, int colorIterations, float3 p) {
        if (i < colorIterations && r2 < trap) { trap = r2; trapIter = i; trapPos = p; }
    }
    inline float clamp11(float x) { return clamp(x, -1.0f, 1.0f); }
    inline float3x3 rotationMatrix3(float3 v, float angleDeg) {
        float angle = angleDeg * M_PI_F / 180.0f;
        float c = cos(angle), s = sin(angle);
        float t = 1.0f - c;
        v = normalize(v);
        return float3x3(
            float3(t*v.x*v.x + c,      t*v.x*v.y - s*v.z,  t*v.x*v.z + s*v.y),
            float3(t*v.x*v.y + s*v.z,  t*v.y*v.y + c,      t*v.y*v.z - s*v.x),
            float3(t*v.x*v.z - s*v.y,  t*v.y*v.z + s*v.x,  t*v.z*v.z + c));
    }
    inline bool isIdentityRotation3(float3x3 m) {
        const float eps = 1e-6f;
        return all(abs(m[0] - float3(1.0f, 0.0f, 0.0f)) <= eps) &&
               all(abs(m[1] - float3(0.0f, 1.0f, 0.0f)) <= eps) &&
               all(abs(m[2] - float3(0.0f, 0.0f, 1.0f)) <= eps);
    }
    FORCE_INLINE float fastPowR(float r, float power) {
        if (power == 2.0f)  { return r * r; }
        if (power == 3.0f)  { return r * r * r; }
        if (power == 4.0f)  { float r2 = r * r; return r2 * r2; }
        if (power == 8.0f)  { float r2 = r * r; float r4 = r2 * r2; return r4 * r4; }
        return powr(max(r, 1e-10f), power);
    }
    FORCE_INLINE float fastPowFromR2(float r2, float power) {
        if (power == 2.0f)  return r2;
        if (power == 4.0f)  return r2 * r2;
        if (power == 6.0f)  return r2 * r2 * r2;
        if (power == 8.0f)  { float r4 = r2 * r2; return r4 * r4; }
        return fastPowR(sqrt(max(r2, 1e-20f)), power);
    }
    // ---- end shim prelude; untouched legacy source follows ----

    """

    /// The generated entry point calling the legacy convention's full-orbit
    /// function. `slotIndices[k]` is the legacy `fp.params` slot that
    /// declared param `k` (ctx.params[k]) feeds — legacy formulas may skip
    /// slots (Embedded Mandelbulb declares 0,1,2,4), so position ≠ slot.
    /// The iterations entry appended after the declared params is not listed.
    public static func trailer(stem: String, slotIndices: [Int]) -> String {
        let contiguous = slotIndices == Array(0..<slotIndices.count)
        let routing: String
        if contiguous {
            // Unchanged text for the common case (stable source hash).
            routing = """
                for (int i = 0; i < 16; ++i) {
                    fp.params[i] = i < \(slotIndices.count) && uint(i) + 1u < ctx.paramCount
                        ? ctx.params[i] : 0.0f;
                }
            """
        } else {
            let lines = slotIndices.enumerated().map { k, slot in
                "    if (\(k + 1)u < ctx.paramCount) fp.params[\(slot)] = ctx.params[\(k)];"
            }
            routing = (["    for (int i = 0; i < 16; ++i) { fp.params[i] = 0.0f; }"] + lines)
                .joined(separator: "\n")
        }
        return """


        // ---- shim entry point (generated by migration) ----
        [[visible]] float2 de_main(float3 p, thread const ThreshDEContext& ctx)
        {
            FormulaParams fp;
        \(routing)
            fp.rotMatrix1 = float3x3(1.0f);
            fp.rotMatrix2 = float3x3(1.0f);
            fp.rotationFlags = 0u;
            const int iterations = int(ctx.params[ctx.paramCount - 1]);
            OrbitData orbit;
            orbit.trap = 1e20f;
            orbit.trapIteration = 0;
            orbit.trapPosition = p;
            orbit.finalP = p;
            orbit.iterationsUsed = 0;
            float d = DE_\(stem)(p, fp, float3x3(1.0f), iterations, iterations, orbit);
            return float2(d, sqrt(max(orbit.trap, 0.0f)));
        }
        """
    }

    /// Full adapted source for one legacy formula.
    public static func adapt(metalSource: String, stem: String, slotIndices: [Int]) -> String {
        prelude + metalSource + trailer(stem: stem, slotIndices: slotIndices)
    }
}
