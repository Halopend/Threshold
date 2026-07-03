// ScaleContextRenderTests.swift — GPU semantics of zoom-as-model-rescale
// (plan §6.3): marching at modelScale s must equal marching the same content
// scaled 1/s in model space, because mapScene scales positions in and divides
// distances back out to world space.

import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("Scale context render", .serialized)
struct ScaleContextRenderTests {

    private func sphereProgram(
        _ loader: ExternalDELoader, radius: Float
    ) throws -> ExternalDEProgram {
        let source = ExternalDETests.sphereSource
        return try loader.load(EmbeddedDE(
            source: source, abiVersion: Int(THRESHOLD_ABI_VERSION),
            hash: ExternalDELoader.sourceHash(source),
            params: [EmbeddedDEParam(name: "radius", defaultValue: radius, min: 0.1, max: 4)]))
    }

    private func render(
        _ renderer: OffscreenRenderer, program: ExternalDEProgram,
        radius: Float, zoomOctaves: Float
    ) throws -> RenderResult {
        // AO probes deliberately follow featureScale (they are world-space
        // walks), so neutralize AO for the pure-geometry equivalence check.
        var engine = EngineParams()
        engine.aoStrength = 0
        let (params, deParamOffset) = ParamTableLayout.build(
            engine: engine, deParams: [radius])
        let scale = ScaleContext(zoomOctaves: zoomOctaves)
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0, 0, 4), target: .zero,
            fovYRadians: Float.pi / 3,
            epsilonBase: scale.epsilonBase, modelScale: scale.modelScale,
            opCount: 0, deIndex: Int(program.descriptor.index),
            paramCount: params.count, deParamOffset: deParamOffset)
        let request = RenderRequest(
            uniforms: uniforms, params: params, ops: [], width: 64, height: 64)
        return try renderer.render(request, program: program)
    }

    @Test(.enabled(if: GPU.available))
    func zoomingOneOctaveEqualsDoublingTheModel() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let renderer = try OffscreenRenderer(context: ctx)

        // Zoom +1 octave (modelScale ½) on a unit sphere: d = (|p/2|−1)·2 =
        // |p|−2 — exactly a radius-2 sphere at zoom 0.
        let unit = try sphereProgram(loader, radius: 1)
        let zoomed = try render(renderer, program: unit, radius: 1, zoomOctaves: 1)
        let big = try sphereProgram(loader, radius: 2)
        let reference = try render(renderer, program: big, radius: 2, zoomOctaves: 0)

        #expect(zoomed.rgba8.count == reference.rgba8.count)
        var maxDiff = 0
        for i in zoomed.rgba8.indices {
            maxDiff = max(maxDiff, abs(Int(zoomed.rgba8[i]) - Int(reference.rgba8[i])))
        }
        #expect(maxDiff <= 3,
                "zoomed render must match the rescaled model within rounding (maxDiff \(maxDiff))")

        // And the zoom actually changed the image versus no zoom.
        let unzoomed = try render(renderer, program: unit, radius: 1, zoomOctaves: 0)
        #expect(unzoomed.rgba8 != zoomed.rgba8)
    }

    @Test(.enabled(if: GPU.available))
    func extremeZoomStaysFiniteAndOpaque() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let renderer = try OffscreenRenderer(context: ctx)
        let unit = try sphereProgram(loader, radius: 1)
        for octaves: Float in [-16, 16] {
            let result = try render(renderer, program: unit, radius: 1, zoomOctaves: octaves)
            #expect(
                stride(from: 3, to: result.rgba8.count, by: 4)
                    .allSatisfy { result.rgba8[$0] == 255 },
                Comment(rawValue: "no NaN sentinel pixels at \(octaves) octaves"))
        }
    }
}
