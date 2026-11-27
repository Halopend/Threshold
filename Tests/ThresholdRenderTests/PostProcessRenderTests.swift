// PostProcessRenderTests.swift — ordered GPU filter composition and identity
// contracts. Assertions use relationships rather than exact filtered bytes so
// they remain portable across Metal GPU families.

import Foundation
import Metal
import simd
import Testing
import ThresholdCore
import ThresholdShaderABI
@testable import ThresholdRender

@Suite("Post-process render", .serialized)
struct PostProcessRenderTests {
    private func request(
        stack: [PostProcessFilterDTO] = []
    ) -> RenderRequest {
        let (params, deParamOffset) = ParamTableLayout.build(deParams: [8.0])
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0, 0, 3), target: .zero,
            fovYRadians: Float.pi / 3,
            opCount: 0, deIndex: 1,
            paramCount: params.count, deParamOffset: deParamOffset)
        return RenderRequest(
            uniforms: uniforms, params: params, ops: [],
            postProcessStack: stack, width: 96, height: 96)
    }

    @Test("Active filtering preserves duplicate instances and authored order")
    func activeFilterSelection() {
        let first = PostProcessFilterDTO.makeDefault(.gaussianBlur)
        var disabled = PostProcessFilterDTO.makeDefault(.vignette)
        disabled.enabled = false
        let unknown = PostProcessFilterDTO(
            kind: 999, enabled: true, strength: 1,
            a: [0, 0, 0, 0], b: [0, 0, 0, 0])
        let duplicate = PostProcessFilterDTO.makeDefault(.gaussianBlur)

        let selected = PostProcessor.activeFilters(
            [first, disabled, unknown, duplicate])
        #expect(selected.map(\.id) == [first.id, duplicate.id])
        #expect(selected.allSatisfy { $0.knownKind == .gaussianBlur })
    }

    @Test(.enabled(if: GPU.available))
    func disabledAndUnknownFiltersAreByteIdenticalToEmpty() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let plain = try renderer.render(request())
        var disabled = PostProcessFilterDTO.makeDefault(.invert)
        disabled.enabled = false
        let unknown = PostProcessFilterDTO(
            kind: 4_000_000_000, enabled: true, strength: 1,
            a: [9, 8, 7, 6], b: [5, 4, 3, 2])
        let skipped = try renderer.render(request(stack: [disabled, unknown]))
        #expect(skipped.rgba8 == plain.rgba8)
    }

    @Test(.enabled(if: GPU.available))
    func spatialUpscaleExpandsAReducedColorTexture() throws {
        let context = try GPU.ctx()
        let processor = try PostProcessor(context: context)
        guard let queue = context.device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            Issue.record("could not allocate spatial-upscale command objects")
            return
        }

        func texture(
            width: Int, height: Int, storage: MTLStorageMode
        ) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false)
            descriptor.storageMode = storage
            descriptor.usage = [.shaderRead, .shaderWrite]
            return try #require(context.device.makeTexture(descriptor: descriptor))
        }

        let destination = try texture(width: 8, height: 8, storage: .shared)
        let staging = try texture(width: 2, height: 2, storage: .shared)
        let color: [UInt8] = [13, 67, 201, 255] // BGRA memory order
        let sourceBytes = Array(repeating: color, count: 4).flatMap { $0 }
        sourceBytes.withUnsafeBytes { bytes in
            staging.replace(
                region: MTLRegionMake2D(0, 0, 2, 2),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: 2 * 4)
        }

        let pass = try processor.prepareSpatialPass(
            inputWidth: 2,
            inputHeight: 2,
            matching: destination,
            inFlightSlot: 0)
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: staging,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(),
            sourceSize: MTLSize(width: 2, height: 2, depth: 1),
            to: pass.input,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init())
        blit.endEncoding()
        try processor.encodeSpatial(commandBuffer: commandBuffer, pass: pass)
        try processor.encode(
            commandBuffer: commandBuffer,
            source: pass.output,
            destination: destination,
            stack: [],
            time: 0)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var actual = [UInt8](repeating: 0, count: 8 * 8 * 4)
        actual.withUnsafeMutableBytes { bytes in
            destination.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 8 * 4,
                from: MTLRegionMake2D(0, 0, 8, 8),
                mipmapLevel: 0)
        }
        for offset in stride(from: 0, to: actual.count, by: 4) {
            #expect(Array(actual[offset..<(offset + 4)]) == color)
        }
    }

    @Test(.enabled(if: GPU.available))
    func authoredOrderChangesTheImage() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        var blur = PostProcessFilterDTO.makeDefault(.gaussianBlur)
        blur.strength = 1
        blur.a[0] = 7
        blur.a[1] = 4
        var vignette = PostProcessFilterDTO.makeDefault(.vignette)
        vignette.strength = 1
        vignette.a[0] = 0.12
        vignette.a[1] = 0.58

        let blurThenVignette = try renderer.render(request(stack: [blur, vignette]))
        let vignetteThenBlur = try renderer.render(request(stack: [vignette, blur]))
        #expect(blurThenVignette.rgba8 != vignetteThenBlur.rgba8,
                "a sequential stack must execute in authored order")
    }

    @Test(.enabled(if: GPU.available))
    func duplicateFilterRunsTwice() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        var blur = PostProcessFilterDTO.makeDefault(.gaussianBlur)
        blur.strength = 1
        blur.a[0] = 5
        blur.a[1] = 3
        var second = blur
        second.id = UUID()

        let once = try renderer.render(request(stack: [blur]))
        let twice = try renderer.render(request(stack: [blur, second]))
        #expect(once.rgba8 != twice.rgba8,
                "duplicate kinds are independent sequential stages")
    }

    @Test(.enabled(if: GPU.available))
    func spatialBloomSpreadsIntoPreviouslyBlackPixels() throws {
        let renderer = try OffscreenRenderer(context: GPU.ctx())
        let plain = try renderer.render(request())
        var bloom = PostProcessFilterDTO.makeDefault(.bloom)
        bloom.strength = 2
        bloom.a = [0.08, 0.12, 6, 1]
        let bloomed = try renderer.render(request(stack: [bloom]))

        var spreadPixels = 0
        for i in stride(from: 0, to: plain.rgba8.count, by: 4) {
            let before = Int(plain.rgba8[i]) + Int(plain.rgba8[i + 1])
                + Int(plain.rgba8[i + 2])
            let after = Int(bloomed.rgba8[i]) + Int(bloomed.rgba8[i + 1])
                + Int(bloomed.rgba8[i + 2])
            if before == 0 && after > 0 { spreadPixels += 1 }
        }
        #expect(spreadPixels > 0,
                "bloom must sample neighboring highlights, not only boost its own pixel")
    }
}
