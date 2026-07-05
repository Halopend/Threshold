// RenderTests.swift — end-to-end offscreen march: smoke, warp stacks,
// determinism.
//
// NaN policy: the kernel writes alpha 0 (magenta sentinel) for any pixel
// whose distance estimate went non-finite; every well-formed pixel (hit or
// miss) has alpha 255. rgba8unorm cannot represent NaN directly, so the
// alpha channel IS the NaN check on readback.

import Foundation
import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdRender

private struct Image {
    let result: RenderResult

    func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * result.width + x) * 4
        return (result.rgba8[i], result.rgba8[i + 1], result.rgba8[i + 2], result.rgba8[i + 3])
    }

    var allAlphaOpaque: Bool {
        stride(from: 3, to: result.rgba8.count, by: 4).allSatisfy { result.rgba8[$0] == 255 }
    }
}

/// 128×128 mandelbulb (power 8), camera (0,0,3) → origin, fov 60°, engine
/// defaults from docs/op-semantics.md.
private func smokeRequest(ops: [ThreshWarpOp] = []) -> RenderRequest {
    let (params, deParamOffset) = ParamTableLayout.build(deParams: [8.0])
    let uniforms = CameraMath.makeUniforms(
        cameraPos: SIMD3(0, 0, 3), target: .zero,
        fovYRadians: Float.pi / 3,
        opCount: ops.count, deIndex: 1,
        paramCount: params.count, deParamOffset: deParamOffset)
    return RenderRequest(uniforms: uniforms, params: params, ops: ops,
                         width: 128, height: 128)
}

@Suite("Offscreen render", .serialized)
struct RenderTests {

    @Test(.enabled(if: GPU.available))
    func mandelbulbSmoke() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let result = try renderer.render(smokeRequest())
        let image = Image(result: result)

        #expect(result.rgba8.count == 128 * 128 * 4)
        #expect(image.allAlphaOpaque, "no NaN sentinel pixels")

        let center = image.pixel(64, 64)
        #expect(Int(center.r) + Int(center.g) + Int(center.b) > 0,
                "center ray must hit the bulb (extends to ~0.65 along +Z)")

        for (x, y) in [(0, 0), (127, 0), (0, 127), (127, 127)] {
            let corner = image.pixel(x, y)
            #expect(corner.r == 0 && corner.g == 0 && corner.b == 0,
                    "corner ray (\(x),\(y)) passes ~1.9 from origin — must miss and shade black")
        }

        #expect(result.stats.totalSteps > 0, "march step counter must accumulate")
        #expect(result.stats.gpuMilliseconds >= 0)
    }

    @Test(.enabled(if: GPU.available))
    func warpStackRender() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let warped = try renderer.render(smokeRequest(ops: [
            makeOp(WK.kaleidoscope, s: 1, a: SIMD4(6, 0, 0, 0)),
            makeOp(WK.twist, s: 0.5, a: SIMD4(0, 1, 0, 0)),
        ]))
        let unwarped = try renderer.render(smokeRequest())

        #expect(Image(result: warped).allAlphaOpaque, "no NaN sentinel pixels under warps")
        #expect(warped.stats.totalSteps > 0)
        #expect(warped.rgba8 != unwarped.rgba8,
                "kaleidoscope+twist must change the image")
    }

    /// End-to-end Bounding op (§66) through the real march — the equivalence
    /// tests validate the CSG math in isolation; this catches march
    /// INSTABILITY (a hard clip surface tunnelled by the over-relaxed tracer
    /// would show as NaN-sentinel pixels, i.e. alpha 0).
    @Test(.enabled(if: GPU.available))
    func boundingRender() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let unbounded = try renderer.render(smokeRequest())

        // In-stack sphere bound (intersect) clips the bulb to a small sphere.
        let inStack = try renderer.render(smokeRequest(ops: [
            makeOp(WK.bounding, s: 1, a: SIMD4(0, 0.35, 0.05, 0)),   // sphere, scale, in-stack intersect
        ]))
        #expect(Image(result: inStack).allAlphaOpaque, "clip must not destabilize the march (no NaN)")
        #expect(inStack.stats.totalSteps > 0)
        #expect(inStack.rgba8 != unbounded.rgba8, "a tight intersect bound must change the image")

        // Subtract mode (carve a sphere out of the bulb).
        let subtract = try renderer.render(smokeRequest(ops: [
            makeOp(WK.bounding, s: 1, a: SIMD4(0, 0.3, 0.05, 0), flags: WK.flagOptionA),
        ]))
        #expect(Image(result: subtract).allAlphaOpaque, "subtract must not destabilize the march")
        #expect(subtract.rgba8 != unbounded.rgba8, "subtract must change the image")

        // Fixed (world-space) cube bound.
        let fixed = try renderer.render(smokeRequest(ops: [
            makeOp(WK.bounding, s: 1, a: SIMD4(1, 0.5, 0.05, 0),
                   b: SIMD4(0, 0, 0, 0), flags: WK.flagOptionB),
        ]))
        #expect(Image(result: fixed).allAlphaOpaque, "fixed bound must not destabilize the march")
        #expect(fixed.rgba8 != unbounded.rgba8, "a fixed cube bound must change the image")
    }

    @Test(.enabled(if: GPU.available))
    func renderIsDeterministic() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let request = smokeRequest(ops: [
            makeOp(WK.kaleidoscope, s: 1, a: SIMD4(6, 0, 0, 0)),
            makeOp(WK.twist, s: 0.5, a: SIMD4(0, 1, 0, 0)),
        ])
        let first = try renderer.render(request)
        let second = try renderer.render(request)
        #expect(first.rgba8 == second.rgba8, "same request twice → byte-identical rgba8")
        #expect(first.stats.totalSteps == second.stats.totalSteps,
                "step totals are order-independent integer sums — identical too")
    }

    @Test(.enabled(if: GPU.available))
    func badRequestsAreRejected() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        var request = smokeRequest()
        request.width = 0
        #expect(throws: RenderError.self) { _ = try renderer.render(request) }

        var badDE = smokeRequest()
        badDE.uniforms.meta.y = 7
        #expect(throws: RenderError.self) { _ = try renderer.render(badDE) }

        var badTable = smokeRequest()
        badTable.params = [Float](repeating: 0, count: 4)
        #expect(throws: RenderError.self) { _ = try renderer.render(badTable) }
    }
}
