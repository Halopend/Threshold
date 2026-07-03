// SpecializationTests.swift — the specialized (direct-call, inlined DE)
// march pipeline is a pure performance overlay: for every built-in it must
// produce the generic table-dispatch pipeline's image EXACTLY (same source,
// same safe math mode — inlining may not change a single bit).

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
                deFunctionName: descriptor.mslFunctionName)
            let fast = try renderer.render(request, specialized: variant)

            #expect(fast.rgba8 == generic.rgba8,
                    Comment(rawValue: "\(descriptor.key): specialization must be invisible"))
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
}
