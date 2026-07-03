// EncodePreamble.swift — the request-contract logic the three render shells
// share before they diverge into compute vs raster encoding.
//
// The three encoders — OffscreenRenderer (headless compute), SessionGPUEncoder
// (Mac/iOS drawable compute, InteractiveSession.swift), and ViewPassEncoder
// (visionOS stereo raster, ViewPass.swift) — each dispatch the SAME march but
// through different Metal APIs, so their encode bodies cannot be one function.
// What they DO share is the pre-encode contract: the same param-table / meta
// invariants and the same specialization-eligibility rule. Before this file
// those were copy-pasted three times and kept in hand-sync; a silent
// divergence renders garbage rather than crashing. They now live here.
//
// The API-specific tail (pipeline/table precedence, buffer binding, dispatch)
// stays in each shell, marked `// SYNC-POINT: render binding contract` where it
// still mirrors the others.

import Metal
import ThresholdShaderABI
import ThresholdShaderIR

enum EncodePreamble {

    /// Why a request failed the shared contract — carried in the `.failure`
    /// case so OffscreenRenderer can surface the message (the live shells just
    /// drop the frame and ignore it).
    struct InvalidRequest: Error { let reason: String }

    /// The param-table / meta-layout invariants EVERY shell enforces before
    /// encoding. Returns `request.uniforms` with `meta.x` set to the op count
    /// (the one field all three shells overwrite), or a failure reason string.
    /// Callers map the failure to their own convention — OffscreenRenderer
    /// throws `RenderError.badRequest`, the live shells drop the frame.
    ///
    /// Shell-specific preconditions (target dimensions, non-empty view list)
    /// are NOT checked here — they belong to each shell.
    ///
    /// SYNC-POINT: single source of truth for the request contract shared by
    /// OffscreenRenderer, SessionGPUEncoder, and ViewPassEncoder.
    static func validatedUniforms(
        _ request: RenderRequest, deFunctionCount: Int
    ) -> Result<ThreshFrameUniforms, InvalidRequest> {
        guard request.params.count >= Int(THRESH_SLOT_ENGINE_COUNT) else {
            return .failure(InvalidRequest(
                reason: "param table smaller than the reserved engine slots"))
        }
        var uniforms = request.uniforms
        uniforms.meta.x = UInt32(request.ops.count) // meta.x always carries ops.count
        guard Int(uniforms.meta.z) <= request.params.count,
              uniforms.meta.w < uniforms.meta.z else {
            return .failure(InvalidRequest(reason:
                "uniforms.meta param layout (count \(uniforms.meta.z), offset \(uniforms.meta.w)) " +
                "inconsistent with params.count \(request.params.count)"))
        }
        guard Int(uniforms.meta.y) < deFunctionCount else {
            return .failure(InvalidRequest(reason: "deIndex \(uniforms.meta.y) out of range"))
        }
        return .success(uniforms)
    }

    /// The specialized (DE source name, baked spec) a shell should look up for
    /// this request, or nil when specialization must NOT be attempted — tuning
    /// disabled, or `deIndex` names an external / non-built-in DE (which has no
    /// core-source function to inline). The shell owns the cache lookup itself
    /// (compute `SpecializationCache` vs raster `RasterSpecializationCache`,
    /// aux-output twin or not); this is only the shared eligibility gate + spec
    /// construction.
    ///
    /// SYNC-POINT: the specialization eligibility rule shared by all three
    /// encoders.
    static func specializationPlan(
        for request: RenderRequest, deIndex: Int
    ) -> (deFunctionName: String, spec: MarchSpec)? {
        guard request.tuning.specializationEnabled,
              DERegistry.builtin.indices.contains(deIndex) else { return nil }
        let spec = MarchSpec.from(
            tuning: request.tuning, params: request.params,
            opCount: UInt32(request.ops.count))
        return (DERegistry.builtin[deIndex].mslFunctionName, spec)
    }
}
