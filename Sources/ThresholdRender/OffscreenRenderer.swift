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

/// AUDIT — `@unchecked Sendable`: the immutable properties are `let`
/// (`GPUContext` is audited Sendable above; `MTLCommandQueue` is documented
/// thread-safe by Metal). The size-keyed texture cache is render-thread
/// confined by contract: `render(_:)` is called from ONE thread at a time
/// (the CLI main loop / a session's render thread) — concurrent render()
/// calls on one OffscreenRenderer were never supported (they would also race
/// the single command queue's ordering assumption).
public final class OffscreenRenderer: @unchecked Sendable {
    private let context: GPUContext
    private let queue: MTLCommandQueue

    // Size-keyed caches (perf round 16 — CPU side): the bench loop renders a
    // fixed size, so re-creating a 16 MiB output texture (plus cone/stats
    // objects) every frame is pure allocator churn. Rebuilt on size change.
    private var cachedTexture: MTLTexture?
    private var cachedConeTexture: MTLTexture?
    private var cachedStats: MTLBuffer?

    // Env seams parsed ONCE (ProcessInfo.environment re-bridges the whole
    // dictionary on every access — measurable in a tight frame loop).
    private static let tgOverride: (Int, Int)? = {
        guard let raw = ProcessInfo.processInfo.environment["THRESHOLD_TG"] else {
            return nil
        }
        let parts = raw.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return (parts[0], parts[1])
    }()

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
    /// Pass `specialized` to render through a direct-call DE variant
    /// (Specialization.swift) — same image, faster; ignored when `program`
    /// is set.
    /// `readback: false` skips the 2×16 MiB (at 2048²) zero-fill + copy of
    /// the pixel readback and returns an empty `rgba8` — for benchmark frames
    /// where only `stats` is consumed. GPU work is identical.
    public func render(
        _ request: RenderRequest, program: ExternalDEProgram? = nil,
        specialized: SpecializedMarch? = nil, readback: Bool = true
    ) throws -> RenderResult {
        guard request.width > 0, request.height > 0 else {
            throw RenderError.badRequest("non-positive dimensions")
        }
        let uniforms: ThreshFrameUniforms
        switch EncodePreamble.validatedUniforms(
            request, deFunctionCount: program?.deFunctionCount ?? context.deFunctionCount) {
        case .success(let u): uniforms = u
        case .failure(let invalid): throw RenderError.badRequest(invalid.reason)
        }

        let device = context.device

        // --- output texture (linear rgba8unorm; no gamma — see RenderResult)
        // Reused across same-size frames; every in-bounds texel is written by
        // the dispatch, so stale content cannot leak into the readback.
        let texture: MTLTexture
        if let cached = cachedTexture,
           cached.width == request.width, cached.height == request.height {
            texture = cached
        } else {
            let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: request.width, height: request.height, mipmapped: false)
            textureDesc.usage = [.shaderWrite]
            textureDesc.storageMode = .shared
            guard let fresh = device.makeTexture(descriptor: textureDesc) else {
                throw RenderError.allocationFailed("output texture")
            }
            cachedTexture = fresh
            texture = fresh
        }

        let paramsBuffer = try context.makeFloatBuffer(request.params, label: "param table")
        let opsBuffer = try context.makeOpsBuffer(request.ops)
        let statsBuffer: MTLBuffer
        if let cached = cachedStats {
            statsBuffer = cached
        } else {
            guard let fresh = device.makeBuffer(
                length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
                throw RenderError.allocationFailed("stats buffer")
            }
            cachedStats = fresh
            statsBuffer = fresh
        }
        statsBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw RenderError.allocationFailed("command buffer")
        }

        // Hierarchical prepass (perf round 15): one thread per 8×8 tile
        // cone-marches the tile's shared safe start depth into a small
        // r32float texture the march kernel reads (texture 3). Present iff
        // the specialized variant baked coneMarch.
        var coneTexture: MTLTexture? = nil
        if program == nil, let prepass = specialized?.conePrepass {
            // MUST match THRESH_CONE_TILE in RaymarchCore.metal (the fine
            // kernel maps gid/8 → cone texel).
            let tile = 8
            let cw = (request.width + tile - 1) / tile
            let ch = (request.height + tile - 1) / tile
            let coneTex: MTLTexture
            if let cached = cachedConeTexture, cached.width == cw, cached.height == ch {
                coneTex = cached
            } else {
                let coneDesc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r32Float, width: cw, height: ch, mipmapped: false)
                coneDesc.usage = [.shaderWrite, .shaderRead]
                coneDesc.storageMode = .private
                guard let fresh = device.makeTexture(descriptor: coneDesc) else {
                    throw RenderError.allocationFailed("cone prepass texture")
                }
                cachedConeTexture = fresh
                coneTex = fresh
            }
            guard let pre = commandBuffer.makeComputeCommandEncoder() else {
                throw RenderError.allocationFailed("cone prepass encoder")
            }
            pre.label = "march_cone_prepass"
            pre.setComputePipelineState(prepass)
            withUnsafeBytes(of: uniforms) { raw in
                pre.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_UNIFORMS))
            }
            pre.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
            pre.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
            pre.setVisibleFunctionTable(
                specialized!.deTable, bufferIndex: GPUContext.deTableBufferIndex)
            var dims = SIMD2<UInt32>(UInt32(request.width), UInt32(request.height))
            withUnsafeBytes(of: &dims) { raw in
                pre.setBytes(raw.baseAddress!, length: raw.count, index: 8)
            }
            pre.setTexture(coneTex, index: 3)
            let coneGroups = MTLSize(
                width: (coneTex.width + 7) / 8,
                height: (coneTex.height + 7) / 8, depth: 1)
            pre.dispatchThreadgroups(
                coneGroups,
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            pre.endEncoding()
            coneTexture = coneTex
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.allocationFailed("command encoder")
        }
        encoder.label = "march_offscreen"
        // SYNC-POINT: render binding contract — pipeline/table precedence and
        // buffer/palette binding below mirror SessionGPUEncoder (compute, with
        // an aux twin) and ViewPassEncoder (raster setFragment*). Kept per-shell
        // because the Metal API differs; the indices and precedence must match.
        encoder.setComputePipelineState(
            program?.marchPipeline ?? specialized?.pipeline ?? context.marchPipeline)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_UNIFORMS))
        }
        encoder.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
        encoder.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
        encoder.setBuffer(statsBuffer, offset: 0, index: Int(THRESH_BUFFER_STATS))
        encoder.setVisibleFunctionTable(
            program?.marchDETable ?? specialized?.deTable ?? context.marchDETable,
            bufferIndex: GPUContext.deTableBufferIndex)
        let paletteBytes = PaletteWire.bytes(request.palette)
        paletteBytes.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_PALETTE))
        }
        encoder.setTexture(texture, index: Int(THRESH_TEXTURE_OUTPUT))
        if let coneTexture {
            encoder.setTexture(coneTexture, index: 3)
        }

        // Measurement seam: THRESHOLD_TG=WxH overrides the threadgroup shape
        // for occupancy A/Bs (default 8x8; parsed once — see tgOverride).
        let (tgW, tgH) = Self.tgOverride ?? (8, 8)
        let threadsPerGroup = MTLSize(width: tgW, height: tgH, depth: 1)
        let groups = MTLSize(width: (request.width + tgW - 1) / tgW,
                             height: (request.height + tgH - 1) / tgH,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RenderError.gpuExecutionFailed(String(describing: error))
        }

        // --- readback ---------------------------------------------------------
        // Skipped for pure-timing frames (readback: false → empty rgba8).
        var rgba8: [UInt8] = []
        if readback {
            let byteCount = request.width * request.height * 4
            rgba8 = [UInt8](unsafeUninitializedCapacity: byteCount) { buf, count in
                texture.getBytes(buf.baseAddress!,
                                 bytesPerRow: request.width * 4,
                                 from: MTLRegionMake2D(0, 0, request.width, request.height),
                                 mipmapLevel: 0)
                count = byteCount
            }
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
