// StaticDispatchTests.swift — the THRESH_STATIC_DISPATCH (Simulator) path.
//
// The Simulator's Metal layer cannot create visible function tables, so
// GPUContext compiles the march with a generated switch instead
// (staticDispatchPrelude) and every DE-table property is nil. These tests
// force that mode on macOS (staticDispatchOverride) and pin the ONE invariant
// that could silently drift: the generated switch dispatches by the SAME
// index order as the visible function tables — for every built-in, and for
// the external-DE slot at builtin.count. Images must match EXACTLY (same
// math mode, same kernels — only the dispatch mechanism differs).

import Foundation
import simd
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("Static DE dispatch (Simulator fallback)", .serialized)
struct StaticDispatchTests {

    /// One static-dispatch context per process (a second runtime MSL compile;
    /// same fixture pattern as GPU.context).
    static let staticContext: Result<GPUContext, any Error> =
        Result { try GPUContext(staticDispatchOverride: true) }
    static func staticCtx() throws -> GPUContext { try staticContext.get() }

    private func request(
        for descriptor: DEDescriptor, ops: [ThreshWarpOp]
    ) -> RenderRequest {
        var engine = EngineParams()
        engine.aoStrength = 0.7
        let (params, deParamOffset) = ParamTableLayout.build(
            engine: engine, deParams: descriptor.paramLayout.map(\.default))
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0.3, 0.4, 3.1), target: .zero,
            fovYRadians: Float.pi / 3,
            epsilonBase: 1e-3, modelScale: 1,
            opCount: ops.count, deIndex: Int(descriptor.index),
            paramCount: params.count, deParamOffset: deParamOffset)
        return RenderRequest(
            uniforms: uniforms, params: params, ops: ops,
            palette: PaletteWire.defaultStops, width: 96, height: 96)
    }

    /// The switch cases are generated from DERegistry.builtin — the same
    /// declaration site the tables index — so this can only fail if the
    /// mechanism itself breaks. Every built-in, bit-identical.
    @Test(.enabled(if: GPU.available))
    func staticDispatchMatchesTableDispatchForEveryBuiltin() throws {
        let tableCtx = try GPU.ctx()
        let staticCtx = try Self.staticCtx()
        #expect(staticCtx.staticDEDispatch)
        #expect(staticCtx.marchDETable == nil)
        #expect(staticCtx.deFunctionCount == DERegistry.builtin.count)

        let tableRenderer = try OffscreenRenderer(context: tableCtx)
        let staticRenderer = try OffscreenRenderer(context: staticCtx)

        let (ops, _) = [ThreshWarpOp].fromDTOs([
            WarpOpDTO(kind: WK.twist, strength: 0.5, a: [0, 1, 0, 0], b: [0, 0, 0, 0])
        ])
        for descriptor in DERegistry.builtin {
            let request = request(for: descriptor, ops: ops)
            let viaTable = try tableRenderer.render(request)
            let viaSwitch = try staticRenderer.render(request)
            #expect(viaSwitch.rgba8 == viaTable.rgba8,
                    Comment(rawValue: "\(descriptor.key): static dispatch must be invisible"))
            #expect(viaTable.rgba8.contains { $0 > 8 },
                    Comment(rawValue: "\(descriptor.key): a blank image proves nothing"))
        }
    }

    /// Specialized variants under static dispatch (nil tables end-to-end)
    /// must also encode and render identically.
    @Test(.enabled(if: GPU.available))
    func specializedRendersUnderStaticDispatch() throws {
        let staticCtx = try Self.staticCtx()
        let renderer = try OffscreenRenderer(context: staticCtx)
        let descriptor = DERegistry.builtin[0]
        let request = request(for: descriptor, ops: [])

        let generic = try renderer.render(request)
        let variant = try staticCtx.makeSpecializedMarch(
            deFunctionName: descriptor.mslFunctionName, mathMode: .safe)
        #expect(variant.deTable == nil)
        let specialized = try renderer.render(request, specialized: variant)
        #expect(specialized.rgba8 == generic.rgba8,
                "specialization must stay invisible under static dispatch")
    }

    /// External DEs compile INTO the core translation unit under static
    /// dispatch (no cross-library linking exists) with the generated case at
    /// index builtin.count. Same loader contract: compile → probe → evaluate,
    /// with exact distances.
    @Test(.enabled(if: GPU.available))
    func externalDELoadsAndEvaluatesUnderStaticDispatch() throws {
        let staticCtx = try Self.staticCtx()
        let loader = try ExternalDELoader(context: staticCtx)
        let source = """
            [[visible]] float2 de_main(float3 p, thread const ThreshDEContext& ctx)
            {
                float radius = ctx.paramCount > 1 ? ctx.params[0] : 1.0f;
                return float2(length(p) - radius, 0.5f);
            }
            """
        let program = try loader.load(EmbeddedDE(
            source: source,
            abiVersion: Int(THRESHOLD_ABI_VERSION),
            hash: ExternalDELoader.sourceHash(source),
            params: [EmbeddedDEParam(name: "radius", defaultValue: 1, min: 0.1, max: 4)]))

        #expect(program.descriptor.index == UInt32(DERegistry.builtin.count))
        #expect(program.deFunctionCount == DERegistry.builtin.count + 1)
        #expect(program.marchDETable == nil)

        let evaluator = try DEEvaluator(context: staticCtx)
        let points: [SIMD3<Float>] = [SIMD3(2, 0, 0), SIMD3(0, 0.25, 0), SIMD3(0, 0, -3)]
        let out = try evaluator.evaluate(
            points: points, deIndex: Int(program.descriptor.index),
            deParams: [1.5], iterations: 12, program: program)
        #expect(abs(out[0].x - 0.5) < 1e-5)
        #expect(abs(out[1].x - -1.25) < 1e-5)
        #expect(abs(out[2].x - 1.5) < 1e-5)
    }
}
