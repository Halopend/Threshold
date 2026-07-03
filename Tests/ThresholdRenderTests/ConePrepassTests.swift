// ConePrepassTests.swift — the hierarchical cone-march prepass (perf block 9)
// actually renders: the coarse dispatch runs, the fine kernel reads its tile
// depths, and the image stays close to the non-cone reference (the prepass
// changes float start points, so equality is a tolerance, not bytes).

import Foundation
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

#if os(macOS)
import QuartzCore
#endif

@Suite("Cone-march prepass", .serialized)
struct ConePrepassTests {

    private func makeRequest(_ descriptor: DEDescriptor) -> RenderRequest {
        var engine = EngineParams()
        engine.aoStrength = 0.5
        let (params, deParamOffset) = ParamTableLayout.build(
            engine: engine, deParams: descriptor.paramLayout.map(\.default))
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0.3, 0.4, 3.1), target: .zero,
            fovYRadians: Float.pi / 3,
            epsilonBase: 1.5e-3, modelScale: 1,
            opCount: 0, deIndex: Int(descriptor.index),
            paramCount: params.count, deParamOffset: deParamOffset)
        return RenderRequest(
            uniforms: uniforms, params: params, ops: [],
            palette: PaletteWire.defaultStops, width: 96, height: 96)
    }

    /// Offscreen path: a coneMarch-baked variant carries the prepass
    /// pipeline, OffscreenRenderer dispatches it, and the result is a sane
    /// image near the non-cone specialized render.
    @Test(.enabled(if: GPU.available))
    func coneVariantRendersCloseToNonCone() throws {
        let ctx = try GPU.ctx()
        let renderer = try OffscreenRenderer(context: ctx)
        let descriptor = DEDescriptor.mandelbox
        let request = makeRequest(descriptor)

        let plain = try ctx.makeSpecializedMarch(
            deFunctionName: descriptor.mslFunctionName,
            spec: MarchSpec(coneMarch: false))
        let cone = try ctx.makeSpecializedMarch(
            deFunctionName: descriptor.mslFunctionName,
            spec: MarchSpec(coneMarch: true))
        #expect(plain.conePrepass == nil)
        #expect(cone.conePrepass != nil,
                "coneMarch: true must carry the prepass pipeline")

        let reference = try renderer.render(request, specialized: plain)
        let result = try renderer.render(request, specialized: cone)

        #expect(reference.rgba8.contains { $0 > 8 }, "blank proves nothing")
        // No NaN sentinel (alpha 0) anywhere: the prepass must never poison
        // a tile into the bad-DE path.
        var alphaZero = 0
        for i in stride(from: 3, to: result.rgba8.count, by: 4)
        where result.rgba8[i] == 0 { alphaZero += 1 }
        #expect(alphaZero == 0, "NaN-sentinel pixels under cone prepass")

        // Tolerance: this guards WIRING (gross artifacts, poisoned tiles,
        // wrong tile mapping), not precision — start-t shifts legitimately
        // move silhouette shading within the epsilon band, and at 96×96 the
        // silhouette fraction is large. A mapping/binding bug shows up as
        // means in the tens; measured healthy values are ≈1-3.
        var total = 0
        var big = 0
        for (a, b) in zip(reference.rgba8, result.rgba8) {
            let d = abs(Int(a) - Int(b))
            total += d
            if d > 48 { big += 1 }
        }
        let mean = Double(total) / Double(reference.rgba8.count)
        #expect(mean < 6.0, "cone image drifted (meanΔ \(mean))")
        #expect(Double(big) / Double(reference.rgba8.count) < 0.05,
                "cone image has large-delta regions (\(big) bytes)")
    }

    /// Cone Stability (function_constant 9): the tuning level maps to the
    /// baked margin, a higher margin builds a distinct variant that renders
    /// without poisoned tiles, and the default (.fast / nil) is unchanged.
    @Test func coneStabilityMapsToMargin() {
        #expect(ConeStability.fast.margin == 3)
        #expect(ConeStability.balanced.margin == 6)
        #expect(ConeStability.stable.margin == 12)

        var engine = EngineParams()
        let (params, _) = ParamTableLayout.build(
            engine: engine, deParams: DEDescriptor.mandelbox.paramLayout.map(\.default))
        // Cone off → no margin baked.
        var tuning = RenderTuning(conePrepass: false, coneStability: .stable)
        #expect(MarchSpec.from(tuning: tuning, params: params, opCount: 0).coneMargin == nil)
        // Cone on → the level's margin.
        tuning = RenderTuning(conePrepass: true, coneStability: .stable)
        #expect(MarchSpec.from(tuning: tuning, params: params, opCount: 0).coneMargin == 12)
        tuning = RenderTuning(conePrepass: true, coneStability: .fast)
        #expect(MarchSpec.from(tuning: tuning, params: params, opCount: 0).coneMargin == 3)
        _ = engine  // silence unused-mutation
    }

    @Test(.enabled(if: GPU.available))
    func stableMarginRendersWithoutPoisonedTiles() throws {
        let ctx = try GPU.ctx()
        let renderer = try OffscreenRenderer(context: ctx)
        let de = DEDescriptor.mandelbox
        let request = makeRequest(de)
        // A distinct high-margin variant must build (its own cache key) and
        // render a sane, sentinel-free image.
        let stable = try ctx.makeSpecializedMarch(
            deFunctionName: de.mslFunctionName,
            spec: MarchSpec(coneMarch: true, coneMargin: 12))
        #expect(stable.conePrepass != nil)
        let result = try renderer.render(request, specialized: stable)
        #expect(result.rgba8.contains { $0 > 8 }, "blank proves nothing")
        var sentinels = 0
        for i in stride(from: 0, to: result.rgba8.count, by: 4)
        where result.rgba8[i] == 255 && result.rgba8[i + 1] == 0
            && result.rgba8[i + 2] == 255 && result.rgba8[i + 3] == 0 {
            sentinels += 1
        }
        #expect(sentinels == 0, "stable-margin cone produced NaN-sentinel tiles")
    }

    #if os(macOS)
    /// Live path: SessionGPUEncoder with conePrepass tuning renders through
    /// a real CAMetalLayer drawable once the specialized variant lands —
    /// exercising the cone texture ring + prepass encode + texture-3 binding.
    @Test(.enabled(if: GPU.available))
    func liveEncoderRendersConeVariant() async throws {
        let ctx = try GPU.ctx()
        let layer = CAMetalLayer()
        layer.device = ctx.device
        InteractiveSession.configure(layer: layer)
        layer.drawableSize = CGSize(width: 128, height: 128)

        let gpu = try SessionGPUEncoder(context: ctx)
        var request = makeRequest(DEDescriptor.mandelbox)
        request.width = 128
        request.height = 128
        request.tuning = RenderTuning.envDefault  // conePrepass: true

        // The specialization compiles off-thread: encode frames until the
        // diagnostics report the specialized pipeline (or time out).
        var sawSpecialized = false
        for _ in 0..<200 {
            guard let drawable = layer.nextDrawable() else { continue }
            let diagnostics = gpu.encode(request, to: drawable)
            if diagnostics.pipeline == RenderDiagnostics.Pipeline.specialized {
                sawSpecialized = true
                #expect(diagnostics.bakedConstants.contains("cone"),
                        "live specialized variant should bake the cone gate")
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sawSpecialized, "specialized cone variant never landed")
    }
    #endif
}
