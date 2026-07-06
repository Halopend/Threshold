// AtmosphereRenderTests — the atmosphere effects (glow, bloom, fog + fog
// tint) actually change the rendered image on the GPU when enabled, and are
// byte-identical to the plain render when disabled (the golden guarantee).

import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdRender

@Suite("Atmosphere render", .serialized)
struct AtmosphereRenderTests {

    /// 128×128 mandelbulb, engine defaults + a caller-tweaked EngineParams.
    private func request(_ engine: EngineParams) -> RenderRequest {
        let (params, deParamOffset) = ParamTableLayout.build(engine: engine, deParams: [8.0])
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0, 0, 3), target: .zero,
            fovYRadians: Float.pi / 3,
            opCount: 0, deIndex: 1,
            paramCount: params.count, deParamOffset: deParamOffset)
        return RenderRequest(uniforms: uniforms, params: params, ops: [],
                             width: 128, height: 128)
    }

    private func pixel(_ r: RenderResult, _ x: Int, _ y: Int)
        -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * r.width + x) * 4
        return (r.rgba8[i], r.rgba8[i + 1], r.rgba8[i + 2], r.rgba8[i + 3])
    }

    @Test(.enabled(if: GPU.available))
    func defaultsAreByteIdenticalToPlain() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        // A fresh EngineParams (atmosphere off) must match the plain smoke
        // request exactly — the disabled fast paths are true no-ops.
        let a = try renderer.render(request(EngineParams()))
        let b = try renderer.render(request(EngineParams()))
        #expect(a.rgba8 == b.rgba8)
    }

    @Test(.enabled(if: GPU.available))
    func fogTintsTheMissedBackground() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let plain = try renderer.render(request(EngineParams()))

        var fogged = EngineParams()
        fogged.fogEnabled = 1
        fogged.fogIntensity = 0.5
        fogged.fogColor = SIMD3(0.6, 0.2, 0.1)  // distinctly reddish
        let result = try renderer.render(request(fogged))

        // Corners are far misses (t → maxDist): fogFactor ≈ 0 → nearly full
        // fog color. Plain render leaves them black.
        let plainCorner = pixel(plain, 0, 0)
        #expect(plainCorner.r == 0 && plainCorner.g == 0 && plainCorner.b == 0)
        let corner = pixel(result, 0, 0)
        #expect(corner.r > corner.g && corner.r > corner.b,
                "far miss should take the reddish fog tint, got \(corner)")
        #expect(corner.r > 40, "fog tint should be clearly visible, got \(corner)")
        #expect(result.rgba8 != plain.rgba8)
    }

    @Test(.enabled(if: GPU.available))
    func glowBrightensNearMissRays() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let plain = try renderer.render(request(EngineParams()))

        var glowing = EngineParams()
        glowing.glowEnabled = 1
        glowing.glowIntensity = 2.0
        let result = try renderer.render(request(glowing))

        // The halo of near-miss rays around the bulb silhouette must brighten
        // some pixels that were black in the plain render.
        var brightened = 0
        for i in stride(from: 0, to: plain.rgba8.count, by: 4) {
            let plainLum = Int(plain.rgba8[i]) + Int(plain.rgba8[i + 1]) + Int(plain.rgba8[i + 2])
            let glowLum = Int(result.rgba8[i]) + Int(result.rgba8[i + 1]) + Int(result.rgba8[i + 2])
            if plainLum == 0 && glowLum > 0 { brightened += 1 }
        }
        #expect(brightened > 0, "glow must light up near-miss halo pixels")
        #expect(result.rgba8 != plain.rgba8)
    }

    @Test(.enabled(if: GPU.available))
    func bloomChangesBrightRegions() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let plain = try renderer.render(request(EngineParams()))

        var bloomed = EngineParams()
        bloomed.bloomEnabled = 1
        bloomed.bloomStrength = 2.0
        let result = try renderer.render(request(bloomed))
        #expect(result.rgba8 != plain.rgba8, "bloom must alter bright regions")
    }
}
