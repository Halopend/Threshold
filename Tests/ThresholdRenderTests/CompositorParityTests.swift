// CompositorParityTests.swift — the stereo raster path validated OFF-device
// (ADR-001): the fragment march must produce the compute kernel's image for
// the same request, and the per-view math must reproduce the pinhole ray
// model. This is what makes first light on the Vision Pro a mechanics test,
// not a math test.

import Foundation
import Metal
import simd
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

// MARK: - CPU view math

@Suite("Compositor view math")
struct CompositorViewMathTests {

    @Test func pinholeRaysMatchTheComputeKernelsRayModel() {
        // The kernel: dirLocal = normalize(ndc.x·aspect·fovTan, ndc.y·fovTan, -1).
        let fovTan: Float = 0.6
        let aspect: Float = 1.5
        let proj = CompositorViewMath.pinholeProjection(fovTan: fovTan, aspect: aspect)
        for ndc in [SIMD2<Float>(0, 0), SIMD2(0.5, -0.25), SIMD2(-1, 1), SIMD2(0.9, 0.9)] {
            let got = CompositorViewMath.rayDirection(invProj: proj.inverse, ndc: ndc)
            let want = simd_normalize(SIMD3(ndc.x * aspect * fovTan, ndc.y * fovTan, -1))
            #expect(simd_length(got - want) < 1e-5,
                    Comment(rawValue: "ndc \(ndc): got \(got), want \(want)"))
        }
    }

    @Test func identityEyeAtTheAnchorReproducesTheSessionCamera() {
        var base = ThreshFrameUniforms()
        base.camPosFov = SIMD4(1, 2, 3, 0.5)
        base.camQuat = SIMD4(0, 0, 0, 1)
        let anchor = SIMD3<Float>(0, 1.6, 0)  // head position when the space opened
        var eye = matrix_identity_float4x4
        eye.columns.3 = SIMD4(anchor, 1)

        let view = CompositorViewMath.viewUniforms(
            projection: CompositorViewMath.pinholeProjection(fovTan: 0.5, aspect: 1),
            eyeToRoom: eye, anchorPosition: anchor, base: base)
        #expect(view.originScale.x == 1 && view.originScale.y == 2 && view.originScale.z == 3,
                "at the anchor, you stand exactly at the session camera")
        #expect(simd_length(view.orient - SIMD4<Float>(0, 0, 0, 1)) < 1e-6)
    }

    @Test func walkingComposesThroughTheSessionCamerasRotation() {
        // Session camera yawed 180°: stepping room-forward (−z) must move the
        // fractal-world eye toward +z.
        var base = ThreshFrameUniforms()
        base.camPosFov = SIMD4(0, 0, 3, 0.5)
        let yaw180 = simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
        base.camQuat = yaw180.vector

        var eye = matrix_identity_float4x4
        eye.columns.3 = SIMD4(0, 0, -1, 1)  // one meter forward of the anchor

        let view = CompositorViewMath.viewUniforms(
            projection: CompositorViewMath.pinholeProjection(fovTan: 0.5, aspect: 1),
            eyeToRoom: eye, anchorPosition: .zero, base: base)
        #expect(abs(view.originScale.z - 4) < 1e-5,
                Comment(rawValue: "room −z maps through the yaw to world +z (got \(view.originScale.z))"))
    }
}

// MARK: - GPU parity

@Suite("Compositor raster parity", .serialized)
struct CompositorParityTests {

    /// Render `request` through the raster path (single view, pinhole
    /// projection matching the request's camera) into offscreen textures.
    private func rasterRender(
        _ request: RenderRequest, context: GPUContext
    ) throws -> [UInt8] {
        let device = context.device
        let encoder = try ViewPassEncoder(
            context: context,
            colorFormat: .rgba8Unorm, depthFormat: .depth32Float, maxViewCount: 1)

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: request.width, height: request.height, mipmapped: false)
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: request.width, height: request.height, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        let color = try #require(device.makeTexture(descriptor: colorDesc))
        let depth = try #require(device.makeTexture(descriptor: depthDesc))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare

        // A pinhole view at the request's own camera: identical rays to the
        // compute kernel's generation.
        let view = CompositorViewMath.viewUniforms(
            projection: CompositorViewMath.pinholeProjection(
                fovTan: request.uniforms.camPosFov.w,
                aspect: Float(request.width) / Float(request.height)),
            eyeToRoom: matrix_identity_float4x4,
            anchorPosition: .zero,
            base: request.uniforms)

        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoded = encoder.encode(
            request, views: [view], renderPass: pass, commandBuffer: commandBuffer)
        #expect(encoded, "raster encode must accept the parity request")
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.error == nil)

        var rgba8 = [UInt8](repeating: 0, count: request.width * request.height * 4)
        rgba8.withUnsafeMutableBytes { raw in
            color.getBytes(
                raw.baseAddress!, bytesPerRow: request.width * 4,
                from: MTLRegionMake2D(0, 0, request.width, request.height),
                mipmapLevel: 0)
        }
        return rgba8
    }

    @Test(.enabled(if: GPU.available))
    func fragmentMarchMatchesComputeMarch() throws {
        let ctx = try GPU.ctx()

        // A representative request: built-in mandelbulb, warp op, palette,
        // off-axis camera — through the offscreen harness's own wiring.
        var engine = EngineParams()
        engine.aoStrength = 0.6
        let de = DERegistry.descriptor(forKey: "mandelbulb")!
        let (params, deParamOffset) = ParamTableLayout.build(
            engine: engine, deParams: de.paramLayout.map(\.default))

        let (ops, _) = [ThreshWarpOp].fromDTOs([
            WarpOpDTO(kind: WK.twist, strength: 0.4, a: [0, 1, 0, 0], b: [0, 0, 0, 0])
        ])

        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0.4, 0.3, 3.2), target: .zero,
            fovYRadians: Float.pi / 3,
            epsilonBase: 1e-3, modelScale: 1,
            opCount: ops.count, deIndex: Int(de.index),
            paramCount: params.count, deParamOffset: deParamOffset)

        let request = RenderRequest(
            uniforms: uniforms, params: params, ops: ops,
            palette: PaletteWire.defaultStops, width: 96, height: 96)

        let compute = try OffscreenRenderer(context: ctx).render(request)
        let raster = try rasterRender(request, context: ctx)

        #expect(raster.count == compute.rgba8.count)
        // The two paths compute rays differently (direct pinhole formula vs
        // matrix unproject) — sub-ulp ray differences flip hit/miss at
        // silhouettes, so a strict max-diff cannot hold. The contract is:
        // almost every pixel matches within rounding, and the outliers are
        // confined to a tiny silhouette fraction. RGB only: miss ALPHA is
        // shell presentation semantics (raster = transparent passthrough,
        // compute = opaque window background) — asserted separately below.
        var outliers = 0
        var totalDiff = 0
        var comparedChannels = 0
        for i in stride(from: 0, to: raster.count, by: 4) {
            for c in i..<(i + 3) {
                let diff = abs(Int(raster[c]) - Int(compute.rgba8[c]))
                totalDiff += diff
                comparedChannels += 1
                if diff > 3 { outliers += 1 }
            }
        }
        let outlierFraction = Double(outliers) / Double(comparedChannels)
        let meanDiff = Double(totalDiff) / Double(comparedChannels)
        #expect(outlierFraction < 0.005,
                Comment(rawValue: "raster≡compute outside silhouettes (outliers \(outlierFraction))"))
        #expect(meanDiff < 0.5,
                Comment(rawValue: "no systematic shading divergence (mean diff \(meanDiff))"))

        // And it drew SOMETHING (a hit somewhere — not an all-black miss).
        #expect(raster.contains { $0 > 8 }, "parity of two empty images proves nothing")

        // Miss-alpha semantics: the raster path composites over passthrough
        // (mixed immersion), so wherever compute missed (opaque black),
        // raster must be transparent.
        var missAlphaViolations = 0
        for i in stride(from: 3, to: raster.count, by: 4) {
            let computeHit = compute.rgba8[i - 3] > 0 || compute.rgba8[i - 2] > 0
                || compute.rgba8[i - 1] > 0
            if !computeHit && compute.rgba8[i] == 255 && raster[i] != 0 {
                missAlphaViolations += 1
            }
        }
        #expect(Double(missAlphaViolations) < Double(raster.count / 4) * 0.005,
                Comment(rawValue: "miss pixels must be transparent on the raster path (\(missAlphaViolations) violations)"))
    }
}
