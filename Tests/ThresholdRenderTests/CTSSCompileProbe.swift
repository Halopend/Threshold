import Testing
@testable import ThresholdRender
import ThresholdShaderIR
import ThresholdShaderABI
import ThresholdCore

#if os(macOS)
import QuartzCore
import Metal
#endif

@Suite("CTSS wiring", .serialized)
struct CTSSCompileProbe {
    @Test(.enabled(if: GPU.available))
    func ctssCompilesInEveryLiveCombination() throws {
        let ctx = try GPU.ctx()
        for aux in [false, true] {
            for ctss in [false, true] {
                #expect(throws: Never.self, "aux=\(aux) ctss=\(ctss)") {
                    _ = try ctx.makeSpecializedMarch(
                        deFunctionName: "de_mandelbulb",
                        spec: MarchSpec(coneMarch: true, ctss: ctss ? true : nil),
                        auxOutputs: aux)
                }
            }
        }
    }

    /// The knob actually reaches the shader: same spec, ctss off vs on, must
    /// produce DIFFERENT pixels through the offscreen renderer.
    @Test(.enabled(if: GPU.available))
    func ctssChangesOffscreenOutput() throws {
        let ctx = try GPU.ctx()
        let renderer = try OffscreenRenderer(context: ctx)
        var engine = EngineParams()
        engine.aoStrength = 0.5
        let de = DEDescriptor.mandelbulb
        let (params, off) = ParamTableLayout.build(
            engine: engine, deParams: de.paramLayout.map(\.default))
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0.3, 0.4, 3.1), target: .zero,
            fovYRadians: Float.pi / 3, epsilonBase: 1.5e-3, modelScale: 1,
            opCount: 0, deIndex: Int(de.index),
            paramCount: params.count, deParamOffset: off)
        let request = RenderRequest(
            uniforms: uniforms, params: params, ops: [],
            palette: PaletteWire.defaultStops, width: 256, height: 256)

        let plain = try ctx.makeSpecializedMarch(
            deFunctionName: de.mslFunctionName, spec: MarchSpec(coneMarch: true))
        let ctss = try ctx.makeSpecializedMarch(
            deFunctionName: de.mslFunctionName,
            spec: MarchSpec(coneMarch: true, ctss: true))
        let a = try renderer.render(request, specialized: plain)
        let b = try renderer.render(request, specialized: ctss)
        var diff = 0
        for (x, y) in zip(a.rgba8, b.rgba8) where x != y { diff += 1 }
        #expect(diff > 0, "ctss produced byte-identical output — knob is inert")
    }

    #if os(macOS)
    /// The LIVE Mac encoder (the app's actual path) reflects the ctss tuning:
    /// the specialized variant it lands must bake the ctss gate.
    @Test(.enabled(if: GPU.available))
    func liveEncoderBakesCTSS() async throws {
        let ctx = try GPU.ctx()
        let layer = CAMetalLayer()
        layer.device = ctx.device
        InteractiveSession.configure(layer: layer)
        layer.drawableSize = CGSize(width: 128, height: 128)

        let gpu = try SessionGPUEncoder(context: ctx)
        var engine = EngineParams()
        engine.aoStrength = 0.5
        let de = DEDescriptor.mandelbulb
        let (params, off) = ParamTableLayout.build(
            engine: engine, deParams: de.paramLayout.map(\.default))
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0.3, 0.4, 3.1), target: .zero,
            fovYRadians: Float.pi / 3, epsilonBase: 1.5e-3, modelScale: 1,
            opCount: 0, deIndex: Int(de.index),
            paramCount: params.count, deParamOffset: off)
        var request = RenderRequest(
            uniforms: uniforms, params: params, ops: [],
            palette: PaletteWire.defaultStops, width: 128, height: 128)
        var t = RenderTuning.envDefault
        t.ctss = true
        request.tuning = t

        var sawCTSS = false
        for _ in 0..<200 {
            guard let drawable = layer.nextDrawable() else { continue }
            let d = gpu.encode(request, to: drawable)
            if d.pipeline == .specialized || d.pipeline == .specializedAux {
                #expect(d.bakedConstants.contains("ctss"),
                        "live variant must bake ctss (got: \(d.bakedConstants))")
                sawCTSS = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sawCTSS, "specialized ctss variant never landed on live encoder")
    }
    #endif
}
