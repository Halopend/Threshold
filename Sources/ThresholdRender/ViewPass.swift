// ViewPass.swift — the stereo raster march path, platform-neutral.
//
// The visionOS Compositor shell renders the SAME march the compute shells
// dispatch, through `thresh_fullscreen_vertex` + `thresh_march_fragment`
// (RaymarchCore.metal "stereo raster path"): per-view ThreshViewUniforms
// generate rays through the real Compositor projection, and the fragment
// writes projection-consistent depth for reprojection.
//
// This file is deliberately NOT #if os(visionOS): the encoder renders into
// any color+depth texture pair, so the Mac test suite proves fragment ≡
// compute on the same request (CompositorParityTests) — the stereo math is
// validated before it ever reaches the device.

import Foundation
import Metal
import simd
import ThresholdShaderABI

// MARK: - CompositorViewMath

/// Pure per-view uniform derivation — the one place Compositor eye poses
/// compose with the session's fractal-world camera. CPU-only, unit-tested.
public enum CompositorViewMath {

    /// Build one view's uniforms.
    ///
    /// The composition (plan §6.4/§8.3): the user STANDS AT the session
    /// camera. `anchorPosition` is the head's room position when the
    /// immersive space opened; the offset from it, scaled by `roomScale`
    /// (room meters → fractal units), rides on top of the session pose —
    /// so the desktop framing is exactly what you see at open, and walking
    /// moves you through fractal space.
    public static func viewUniforms(
        projection: simd_float4x4,
        eyeToRoom: simd_float4x4,
        anchorPosition: SIMD3<Float>,
        base: ThreshFrameUniforms,
        roomScale: Float = 1
    ) -> ThreshViewUniforms {
        let baseRot = baseRotation(base)
        let eyePos = SIMD3(
            eyeToRoom.columns.3.x, eyeToRoom.columns.3.y, eyeToRoom.columns.3.z)
        let eyeRot = simd_quatf(eyeToRoom)

        let origin = fractalPoint(
            room: eyePos, base: base, anchorPosition: anchorPosition,
            roomScale: roomScale)
        let orient = simd_normalize(baseRot * eyeRot)

        return ThreshViewUniforms(
            proj: projection,
            invProj: projection.inverse,
            originScale: SIMD4(origin, roomScale),
            orient: orient.vector)
    }

    /// Room point → fractal-world point: the SAME mapping the eyes use, so
    /// hand geometry lands exactly where you see your hand (plan §4.3).
    public static func fractalPoint(
        room: SIMD3<Float>,
        base: ThreshFrameUniforms,
        anchorPosition: SIMD3<Float>,
        roomScale: Float = 1
    ) -> SIMD3<Float> {
        let basePos = SIMD3(base.camPosFov.x, base.camPosFov.y, base.camPosFov.z)
        return basePos + baseRotation(base).act(roomScale * (room - anchorPosition))
    }

    private static func baseRotation(_ base: ThreshFrameUniforms) -> simd_quatf {
        let q = simd_quatf(vector: base.camQuat)
        guard q.vector.x.isFinite, simd_length(q.vector) > 1e-6 else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_normalize(q)
    }

    /// Symmetric pinhole projection whose rays match the compute kernel's
    /// ray model exactly (RaymarchCore.metal march ray gen) — the parity
    /// test's reference, and a sane default for single-view hosts.
    public static func pinholeProjection(
        fovTan: Float, aspect: Float, near: Float = 0.01, far: Float = 100
    ) -> simd_float4x4 {
        let sy = 1 / fovTan
        let sx = sy / aspect
        let zRange = far - near
        return simd_float4x4(columns: (
            SIMD4(sx, 0, 0, 0),
            SIMD4(0, sy, 0, 0),
            SIMD4(0, 0, -far / zRange, -1),
            SIMD4(0, 0, -far * near / zRange, 0)))
    }

    /// The view-local ray direction the fragment shader derives for `ndc` —
    /// the CPU mirror of the MSL unproject-two-points math, for tests.
    public static func rayDirection(
        invProj: simd_float4x4, ndc: SIMD2<Float>
    ) -> SIMD3<Float> {
        let h0 = invProj * SIMD4(ndc.x, ndc.y, 0.25, 1)
        let h1 = invProj * SIMD4(ndc.x, ndc.y, 0.75, 1)
        let p0 = SIMD3(h0.x, h0.y, h0.z) / h0.w
        let p1 = SIMD3(h1.x, h1.y, h1.z) / h1.w
        var dir = simd_normalize(p1 - p0)
        if dir.z > 0 { dir = -dir }
        return dir
    }
}

// MARK: - ViewPassEncoder

/// Render-thread-confined encoder for the raster march. Mirrors
/// SessionGPUEncoder's contract (stats ring, never blocks, drops bad frames)
/// but encodes a render pass per drawable instead of a compute dispatch.
final class ViewPassEncoder {
    private let context: GPUContext
    private let pipeline: MTLRenderPipelineState
    private let deTable: MTLVisibleFunctionTable
    private let depthState: MTLDepthStencilState
    /// Ring of 3, zeroed CPU-side before reuse — safe because the ring is
    /// deeper than the compositor's frames in flight (same reasoning as
    /// SessionGPUEncoder's ring, without the blit pass: the raster path has
    /// no queue-ordering hazard on a fresh buffer either, but we keep the
    /// blit for symmetry and GPU-ordering).
    private let statsRing: [MTLBuffer]
    private var ringCursor = 0
    private let statsSlot = FrameStatsSlot()

    /// Builds the raster pipeline for the target formats. `maxViewCount` is
    /// the vertex amplification ceiling (2 on device, 1 for tests/simulator).
    init(
        context: GPUContext,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        maxViewCount: Int
    ) throws {
        self.context = context
        let device = context.device

        guard let vertex = context.library.makeFunction(name: "thresh_fullscreen_vertex"),
              let fragment = context.library.makeFunction(name: "thresh_march_fragment")
        else { throw RenderError.missingFunction("thresh_fullscreen_vertex/fragment") }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "thresh_march_raster"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = colorFormat
        desc.depthAttachmentPixelFormat = depthFormat
        desc.inputPrimitiveTopology = .triangle
        if maxViewCount > 1 {
            desc.maxVertexAmplificationCount = maxViewCount
        }
        let linked = MTLLinkedFunctions()
        linked.functions = context.builtinDEFunctions
        desc.fragmentLinkedFunctions = linked

        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RenderError.pipelineCreationFailed(
                "thresh_march_raster: \(String(describing: error))")
        }
        self.pipeline = pipeline

        let tableDesc = MTLVisibleFunctionTableDescriptor()
        tableDesc.functionCount = context.builtinDEFunctions.count
        guard let table = pipeline.makeVisibleFunctionTable(
            descriptor: tableDesc, stage: .fragment)
        else { throw RenderError.functionTableCreationFailed("raster DE table") }
        for (index, f) in context.builtinDEFunctions.enumerated() {
            guard let handle = pipeline.functionHandle(function: f, stage: .fragment) else {
                throw RenderError.functionTableCreationFailed(
                    "raster DE table: no handle for \(f.name)")
            }
            table.setFunction(handle, index: index)
        }
        self.deTable = table

        // The fullscreen triangle writes fragment depth; nothing occludes it.
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .always
        depthDesc.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else {
            throw RenderError.allocationFailed("raster depth state")
        }
        self.depthState = depthState

        var ring: [MTLBuffer] = []
        for i in 0..<3 {
            guard let buffer = device.makeBuffer(
                length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else { throw RenderError.allocationFailed("raster stats buffer \(i)") }
            buffer.label = "raster stats \(i)"
            ring.append(buffer)
        }
        self.statsRing = ring
    }

    /// Stats of the most recently COMPLETED frame (zeros until one finishes).
    func lastCompleted() -> FrameStatsSlot.Stats {
        statsSlot.load()
    }

    /// Encode the march into `renderPass` (caller-configured attachments —
    /// drawable textures on device, offscreen textures in tests).
    ///
    /// `views` carries one ThreshViewUniforms per amplification;
    /// `viewsByteOffset` selects the slice for dedicated-layout passes.
    /// Returns false (encoding skipped) on a malformed request or an external
    /// DE index — the raster path links built-ins only for now (spike scope;
    /// external DEs render on the compute shells).
    @discardableResult
    func encode(
        _ request: RenderRequest,
        views: [ThreshViewUniforms],
        viewsByteOffset: Int = 0,
        renderPass: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        amplificationCount: Int = 1
    ) -> Bool {
        guard !views.isEmpty,
              request.params.count >= Int(THRESH_SLOT_ENGINE_COUNT),
              Int(request.uniforms.meta.z) <= request.params.count,
              request.uniforms.meta.w < request.uniforms.meta.z,
              Int(request.uniforms.meta.y) < context.deFunctionCount
        else { return false }

        var uniforms = request.uniforms
        uniforms.meta.x = UInt32(request.ops.count)

        guard let paramsBuffer = try? context.makeFloatBuffer(
                  request.params, label: "raster param table"),
              let opsBuffer = try? context.makeOpsBuffer(request.ops)
        else { return false }

        let statsBuffer = statsRing[ringCursor]
        ringCursor = (ringCursor + 1) % statsRing.count
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.label = "raster stats zero"
        blit.fill(buffer: statsBuffer, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
        blit.endEncoding()

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPass)
        else { return false }
        encoder.label = "raster march"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        if amplificationCount > 1 {
            var mappings = (0..<amplificationCount).map { _ in
                // The shader drives render_target_array_index from
                // [[amplification_id]]; mappings stay zero-offset.
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0)
            }
            encoder.setVertexAmplificationCount(amplificationCount, viewMappings: &mappings)
        }

        withUnsafeBytes(of: uniforms) { raw in
            encoder.setFragmentBytes(
                raw.baseAddress!, length: raw.count, index: Int(THRESH_BUFFER_UNIFORMS))
        }
        encoder.setFragmentBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
        encoder.setFragmentBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
        encoder.setFragmentBuffer(statsBuffer, offset: 0, index: Int(THRESH_BUFFER_STATS))
        encoder.setFragmentVisibleFunctionTable(
            deTable, bufferIndex: GPUContext.deTableBufferIndex)
        let paletteBytes = PaletteWire.bytes(request.palette)
        paletteBytes.withUnsafeBytes { raw in
            encoder.setFragmentBytes(
                raw.baseAddress!, length: raw.count, index: Int(THRESH_BUFFER_PALETTE))
        }
        views.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: viewsByteOffset)
            encoder.setFragmentBytes(
                base, length: raw.count - viewsByteOffset,
                index: Int(THRESH_BUFFER_VIEWS))
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // AUDIT — nonisolated(unsafe): same contract as SessionGPUEncoder —
        // the handler reads the buffer only after the writing command buffer
        // completed, on Metal's completion thread; FrameStatsSlot is Sendable.
        nonisolated(unsafe) let completedStats = statsBuffer
        let slot = statsSlot
        commandBuffer.addCompletedHandler { completed in
            let steps = UInt64(completedStats.contents().load(as: UInt32.self))
            let ms = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000.0
            slot.store(gpuMilliseconds: ms, totalSteps: steps)
        }
        return true
    }
}
