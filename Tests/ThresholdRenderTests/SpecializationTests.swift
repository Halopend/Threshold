// SpecializationTests.swift — the specialized (direct-call, inlined DE)
// march pipeline is a pure performance overlay: for every built-in it must
// produce the generic table-dispatch pipeline's image EXACTLY when compiled
// at the SAME math mode (inlining may not change a single bit). Production
// specialized variants default to .relaxed for perf — these tests pin .safe
// so they verify the specialization mechanism, not the math mode.

import Foundation
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("Pipeline specialization", .serialized)
struct SpecializationTests {

    @Test(.enabled(if: GPU.available))
    func specializedMatchesGenericForEveryBuiltin() throws {
        let ctx = try GPU.ctx()
        let renderer = try OffscreenRenderer(context: ctx)

        for descriptor in DERegistry.builtin {
            var engine = EngineParams()
            engine.aoStrength = 0.7
            let (params, deParamOffset) = ParamTableLayout.build(
                engine: engine, deParams: descriptor.paramLayout.map(\.default))
            let (ops, _) = [ThreshWarpOp].fromDTOs([
                WarpOpDTO(kind: WK.twist, strength: 0.5, a: [0, 1, 0, 0], b: [0, 0, 0, 0])
            ])
            let uniforms = CameraMath.makeUniforms(
                cameraPos: SIMD3(0.3, 0.4, 3.1), target: .zero,
                fovYRadians: Float.pi / 3,
                epsilonBase: 1e-3, modelScale: 1,
                opCount: ops.count, deIndex: Int(descriptor.index),
                paramCount: params.count, deParamOffset: deParamOffset)
            let request = RenderRequest(
                uniforms: uniforms, params: params, ops: ops,
                palette: PaletteWire.defaultStops, width: 96, height: 96)

            let generic = try renderer.render(request)
            let variant = try ctx.makeSpecializedMarch(
                deFunctionName: descriptor.mslFunctionName, mathMode: .safe)
            let fast = try renderer.render(request, specialized: variant)

            #expect(fast.rgba8 == generic.rgba8,
                    Comment(rawValue: "\(descriptor.key): specialization must be invisible"))
            #expect(generic.rgba8.contains { $0 > 8 },
                    Comment(rawValue: "\(descriptor.key): a blank image proves nothing"))

            // The FULLY-baked variant (all 5 function constants set to the
            // resolved values, with a warp op present and AO on) must ALSO be
            // bit-identical: every baked value IS the runtime value, so
            // unrolling / DCE / dropped branches may not change a pixel.
            let full = MarchSpec(
                iterations: Int(params[Int(THRESH_SLOT_ITERATIONS)]),
                maxSteps: Int(params[Int(THRESH_SLOT_MAX_STEPS)]),
                hasWarpOps: uniforms.meta.x > 0,
                colorMapMode: Int(params[Int(THRESH_SLOT_MAP_MODE)]),
                aoEnabled: params[Int(THRESH_SLOT_AO_STRENGTH)] > 0)
            let baked = try ctx.makeSpecializedMarch(
                deFunctionName: descriptor.mslFunctionName, spec: full,
                mathMode: .safe)
            let bakedResult = try renderer.render(request, specialized: baked)
            #expect(bakedResult.rgba8 == generic.rgba8,
                    Comment(rawValue: "\(descriptor.key): fully-baked specialization must be invisible"))
        }
    }

    /// The GATING constants (hasWarpOps=false → DCE the interpreter,
    /// aoEnabled=false → skip the AO taps) are the ones that could actually
    /// change the image if the "off" path diverged. Render with no warp ops
    /// and AO strength 0, then bake both gates OFF — must be bit-identical.
    @Test(.enabled(if: GPU.available))
    func gatedOffConstantsMatchGeneric() throws {
        let ctx = try GPU.ctx()
        let renderer = try OffscreenRenderer(context: ctx)

        for descriptor in DERegistry.builtin {
            var engine = EngineParams()
            engine.aoStrength = 0  // AO off — the gate must skip AND match
            let (params, deParamOffset) = ParamTableLayout.build(
                engine: engine, deParams: descriptor.paramLayout.map(\.default))
            let uniforms = CameraMath.makeUniforms(
                cameraPos: SIMD3(0.3, 0.4, 3.1), target: .zero,
                fovYRadians: Float.pi / 3,
                epsilonBase: 1e-3, modelScale: 1,
                opCount: 0, deIndex: Int(descriptor.index),  // NO warp ops
                paramCount: params.count, deParamOffset: deParamOffset)
            let request = RenderRequest(
                uniforms: uniforms, params: params, ops: [],
                palette: PaletteWire.defaultStops, width: 96, height: 96)

            let generic = try renderer.render(request)
            let gated = MarchSpec(hasWarpOps: false, aoEnabled: false)
            let variant = try ctx.makeSpecializedMarch(
                deFunctionName: descriptor.mslFunctionName, spec: gated,
                mathMode: .safe)
            let result = try renderer.render(request, specialized: variant)
            #expect(result.rgba8 == generic.rgba8,
                    Comment(rawValue: "\(descriptor.key): gated-off (no-ops, no-AO) must be invisible"))
            #expect(generic.rgba8.contains { $0 > 8 },
                    Comment(rawValue: "\(descriptor.key): a blank image proves nothing"))
        }
    }

    @Test func nonBuiltinNamesAreRejected() throws {
        let ctx = try GPU.ctx()
        #expect(throws: RenderError.self) {
            _ = try ctx.makeSpecializedMarch(deFunctionName: "de_notreal")
        }
    }

    @Test(.enabled(if: GPU.available))
    func cacheCompilesOnceAndServesTheVariant() async throws {
        let ctx = try GPU.ctx()
        let cache = SpecializationCache(context: ctx)
        let name = DERegistry.builtin[0].mslFunctionName

        // First lookup misses and schedules the async compile.
        #expect(cache.lookup(deFunctionName: name) == nil)
        var landed = false
        for _ in 0..<200 {  // compiles in well under 20 s on any dev machine
            if cache.lookup(deFunctionName: name) != nil { landed = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(landed, "the background compile must eventually land")
    }

    @Test(.enabled(if: GPU.available))
    func cacheNegativelyCachesAndSurfacesCompilerFailure() async throws {
        let ctx = try GPU.ctx()
        let cache = SpecializationCache(context: ctx)
        let name = "de_notreal"

        // The stability gate schedules on the eighth lookup.
        for _ in 0..<8 {
            #expect(cache.lookup(deFunctionName: name) == nil)
        }

        var surfaced: String?
        for _ in 0..<100 {
            surfaced = cache.failureDescription(deFunctionName: name)
            if surfaced != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(surfaced != nil, "the async compiler error must become terminal state")

        // Further lookups stay on the generic fallback without scheduling a
        // fresh compile storm for the same deterministic failure.
        for _ in 0..<100 {
            #expect(cache.lookup(deFunctionName: name) == nil)
        }
        #expect(cache.failureDescription(deFunctionName: name) == surfaced)
    }
}
