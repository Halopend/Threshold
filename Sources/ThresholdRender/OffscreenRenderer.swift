// OffscreenRenderer.swift — headless render of one RenderRequest to bytes.
//
// Encoding contract (ABI header binding indices):
//   THRESH_BUFFER_UNIFORMS   64-byte ThreshFrameUniforms via setBytes
//   THRESH_BUFFER_PARAMS     resolved param table (device const float*)
//   THRESH_BUFFER_WARP_OPS   warp op buffer (1-element dummy when empty;
//                            meta.x carries 0)
//   THRESH_BUFFER_STATS      zero-initialized device atomic_uint
//   GPUContext.deTableBufferIndex   DE visible function table
//   THRESH_TEXTURE_OUTPUT    rgba8unorm write target
// Dispatch is 8x8 threadgroups covering the texture; the kernel guards the
// grid edge.

import Foundation
import Metal
import ThresholdShaderABI

/// AUDIT — `@unchecked Sendable`: both stored properties are `let`;
/// `GPUContext` is audited Sendable above and `MTLCommandQueue` is documented
/// thread-safe by Metal. `render(_:)` allocates all transient state locally.
public final class OffscreenRenderer: @unchecked Sendable {
    private let context: GPUContext
    private let queue: MTLCommandQueue

    public init(context: GPUContext) throws {
        guard let queue = context.device.makeCommandQueue() else {
            throw RenderError.allocationFailed("command queue")
        }
        self.context = context
        self.queue = queue
    }

    /// Render one request. Pass `program` to dispatch an external DE — its
    /// pipeline/table extend the built-in set, so a request whose
    /// `uniforms.meta.y` is a BUILT-IN index still works through it.
    public func render(
        _ request: RenderRequest, program: ExternalDEProgram? = nil
    ) throws -> RenderResult {
        guard request.width > 0, request.height > 0 else {
            throw RenderError.badRequest("non-positive dimensions")
        }
        guard request.params.count >= Int(THRESH_SLOT_ENGINE_COUNT) else {
            throw RenderError.badRequest("param table smaller than the reserved engine slots")
        }
        var uniforms = request.uniforms
        uniforms.meta.x = UInt32(request.ops.count) // meta.x always carries ops.count
        guard Int(uniforms.meta.z) <= request.params.count,
              uniforms.meta.w < uniforms.meta.z else {
            throw RenderError.badRequest(
                "uniforms.meta param layout (count \(uniforms.meta.z), offset \(uniforms.meta.w)) " +
                "inconsistent with params.count \(request.params.count)")
        }
        guard Int(uniforms.meta.y) < (program?.deFunctionCount ?? context.deFunctionCount) else {
            throw RenderError.badRequest("deIndex \(uniforms.meta.y) out of range")
        }

        let device = context.device

        // --- output texture (linear rgba8unorm; no gamma — see RenderResult)
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: request.width, height: request.height, mipmapped: false)
        textureDesc.usage = [.shaderWrite]
        textureDesc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDesc) else {
            throw RenderError.allocationFailed("output texture")
        }

        let paramsBuffer = try context.makeFloatBuffer(request.params, label: "param table")
        let opsBuffer = try context.makeOpsBuffer(request.ops)
        guard let statsBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            throw RenderError.allocationFailed("stats buffer")
        }
        statsBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.allocationFailed("command buffer/encoder")
        }
        encoder.label = "march_offscreen"
        encoder.setComputePipelineState(program?.marchPipeline ?? context.marchPipeline)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_UNIFORMS))
        }
        encoder.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
        encoder.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
        encoder.setBuffer(statsBuffer, offset: 0, index: Int(THRESH_BUFFER_STATS))
        encoder.setVisibleFunctionTable(program?.marchDETable ?? context.marchDETable,
                                        bufferIndex: GPUContext.deTableBufferIndex)
        let paletteBytes = PaletteWire.bytes(request.palette)
        paletteBytes.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_PALETTE))
        }
        encoder.setTexture(texture, index: Int(THRESH_TEXTURE_OUTPUT))

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(width: (request.width + 7) / 8,
                             height: (request.height + 7) / 8,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RenderError.gpuExecutionFailed(String(describing: error))
        }

        // --- readback ---------------------------------------------------------
        let byteCount = request.width * request.height * 4
        var rgba8 = [UInt8](repeating: 0, count: byteCount)
        rgba8.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: request.width * 4,
                             from: MTLRegionMake2D(0, 0, request.width, request.height),
                             mipmapLevel: 0)
        }

        let totalSteps = UInt64(statsBuffer.contents().load(as: UInt32.self))
        // gpuStartTime/gpuEndTime are command-buffer measurements, not ambient
        // time reads (Invariant 9 stays intact).
        let gpuMs = max(0, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000.0

        return RenderResult(
            rgba8: rgba8,
            width: request.width,
            height: request.height,
            stats: MarchStats(totalSteps: totalSteps, gpuMilliseconds: gpuMs))
    }
}
