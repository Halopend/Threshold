import Foundation
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("3D frequency volume", .serialized)
struct FrequencyVolumeTests {
    private func request(camera: SIMD3<Float> = SIMD3(0, 0, 3)) -> RenderRequest {
        var engine = EngineParams()
        engine.aoStrength = 0
        let descriptor = DEDescriptor.mandelbulb
        let (params, offset) = ParamTableLayout.build(
            engine: engine, deParams: descriptor.paramLayout.map(\.default))
        let uniforms = CameraMath.makeUniforms(
            cameraPos: camera, target: .zero, fovYRadians: .pi / 3,
            epsilonBase: 1.5e-3, modelScale: 1, opCount: 0,
            deIndex: Int(descriptor.index), paramCount: params.count,
            deParamOffset: offset)
        return RenderRequest(
            uniforms: uniforms, params: params, ops: [], width: 96, height: 96)
    }

    @Test func uniformsLayoutMatchesMSL() {
        #expect(MemoryLayout<FrequencyVolume.Uniforms>.size == 48)
        #expect(MemoryLayout<FrequencyVolume.Uniforms>.stride == 48)
        #expect(MemoryLayout<FrequencyVolume.Uniforms>.offset(of: \.gridDim) == 16)
        #expect(MemoryLayout<FrequencyVolume.Uniforms>.offset(of: \.threshold) == 32)
    }

    @Test(.enabled(if: GPU.available))
    func viewChangeReusesVolumeAndAAIsFinite() throws {
        let ctx = try GPU.ctx()
        let renderer = try OffscreenRenderer(context: ctx)
        let volume = try FrequencyVolume(
            context: ctx, gridResolution: 32, worldHalfExtent: 3,
            threshold: 0.5)
        let a = request()
        let plain = try renderer.render(a)
        let filtered = try renderer.render(a, frequencyVolume: volume)
        #expect(volume.metrics.builds == 1)
        #expect(filtered.rgba8.count == plain.rgba8.count)
        #expect(stride(from: 3, to: filtered.rgba8.count, by: 4)
            .allSatisfy { filtered.rgba8[$0] != 0 })
        #expect(volume.metrics.lastTriggeredPixels > 0,
                "low threshold should exercise adaptive sub-pixel rays")

        _ = try renderer.render(request(camera: SIMD3(2, 1, 4)),
                                frequencyVolume: volume)
        #expect(volume.metrics.builds == 1)
        #expect(volume.metrics.hits > 0, "camera-only change should reuse 3D field")
        let diagnostic = try #require(volume.diagnosticImage())
        #expect(diagnostic.rgba8.contains { $0 > 0 })
    }

    @Test(.enabled(if: GPU.available))
    func nilFrequencyVolumeIsBaselineExact() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let a = try renderer.render(request())
        let b = try renderer.render(request(), frequencyVolume: nil)
        #expect(a.rgba8 == b.rgba8)
    }
}
