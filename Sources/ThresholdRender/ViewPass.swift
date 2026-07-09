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
import Synchronization
import ThresholdShaderABI
import ThresholdShaderIR

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
    /// nil under static dispatch (the fragment has no table argument there).
    private let deTable: MTLVisibleFunctionTable?
    private let depthState: MTLDepthStencilState
    /// Ring of 3, zeroed CPU-side before reuse — safe because the ring is
    /// deeper than the compositor's frames in flight (same reasoning as
    /// SessionGPUEncoder's ring, without the blit pass: the raster path has
    /// no queue-ordering hazard on a fresh buffer either, but we keep the
    /// blit for symmetry and GPU-ordering).
    private let statsRing: [MTLBuffer]
    private var ringCursor = 0
    private let statsSlot = FrameStatsSlot()
    /// GPU-fault check for completed command buffers (observability phase 1).
    private let health = CommandBufferHealth(shell: "compositor.raster")
    /// Specialized (direct-call, inlined DE) raster variants — the visionOS
    /// counterpart of SessionGPUEncoder's SpecializationCache. Non-blocking:
    /// frames render generic until a variant compiles off-thread. nil when the
    /// target formats can't host specialization (never today; kept explicit).
    private let specializations: RasterSpecializationCache
    /// Per-view cone-prepass depth textures (texture2d_array, one slice per
    /// amplified view), one per in-flight frame slot — frame N+1's prepass must
    /// not overwrite the array frame N's fragment is still reading. Rebuilt on
    /// size/slice change. Shares the statsRing cursor. Reuse across frames is
    /// safe by GPU hazard ordering (tracked .private texture, same queue), so a
    /// slot collision only costs pipelining, never a torn read. LAYERED (device
    /// default under foveation) encodes once/frame → 3 frames of headroom;
    /// DEDICATED (no-foveation fallback) encodes twice/frame → ~1.5 frames, the
    /// same marginal contract the statsRing already carries.
    private var coneRing: [MTLTexture?]

    /// Builds the raster pipeline for the target formats. `maxViewCount` is
    /// the vertex amplification ceiling (2 on device, 1 for tests/simulator).
    init(
        context: GPUContext,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        maxViewCount: Int
    ) throws {
        self.context = context
        self.specializations = RasterSpecializationCache(
            context: context, colorFormat: colorFormat,
            depthFormat: depthFormat, maxViewCount: maxViewCount)
        self.coneRing = [nil, nil, nil]
        let device = context.device

        guard let vertex = context.library.makeFunction(name: "thresh_fullscreen_vertex")
        else { throw RenderError.missingFunction("thresh_fullscreen_vertex") }
        // The fragment now has a THRESH_CONE-gated cone-texture argument, so —
        // like the compute march kernel — it must be created through the
        // constant-values path even for the generic variant. Empty values
        // leave THRESH_CONE (and THRESH_AUX) undefined → false, so the cone
        // argument is eliminated and this pipeline binds no cone texture.
        let fragment: MTLFunction
        do {
            fragment = try context.library.makeFunction(
                name: "thresh_march_fragment",
                constantValues: MTLFunctionConstantValues())
        } catch {
            throw RenderError.missingFunction(
                "thresh_march_fragment: \(String(describing: error))")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "thresh_march_raster"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = colorFormat
        desc.depthAttachmentPixelFormat = depthFormat
        desc.inputPrimitiveTopology = .triangle
        // Guard on device support, not just view count — requesting
        // amplification on a device without it (the Simulator) is a Metal
        // validation ABORT, not an error return.
        if maxViewCount > 1, device.supportsVertexAmplificationCount(maxViewCount) {
            desc.maxVertexAmplificationCount = maxViewCount
        }
        if !context.builtinDEFunctions.isEmpty {
            let linked = MTLLinkedFunctions()
            linked.functions = context.builtinDEFunctions
            desc.fragmentLinkedFunctions = linked
        }

        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RenderError.pipelineCreationFailed(
                "thresh_march_raster: \(String(describing: error))")
        }
        self.pipeline = pipeline

        if context.staticDEDispatch {
            self.deTable = nil
        } else {
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
        }

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
    /// `overrideSpecialized` injects a specific specialized variant instead of
    /// consulting the async cache — the deterministic test seam (production
    /// callers leave it nil and let the cache land the variant off-thread).
    @discardableResult
    func encode(
        _ request: RenderRequest,
        views: [ThreshViewUniforms],
        viewsByteOffset: Int = 0,
        renderPass: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        amplificationCount: Int = 1,
        overrideSpecialized: SpecializedRaster? = nil
    ) -> Bool {
        // Raster links built-ins only (external DEs render on the compute
        // shells), so the shared contract's deFunctionCount is the built-in set.
        guard !views.isEmpty else { return false }
        let uniforms: ThreshFrameUniforms
        switch EncodePreamble.validatedUniforms(
            request, deFunctionCount: context.deFunctionCount) {
        case .success(let u): uniforms = u
        case .failure: return false
        }

        guard let paramsBuffer = try? context.makeFloatBuffer(
                  request.params, label: "raster param table"),
              let opsBuffer = try? context.makeOpsBuffer(request.ops)
        else { return false }

        // Pipeline choice: the specialized (direct-call inlined DE) raster
        // variant once it has compiled and tuning enables it — else generic
        // (the always-correct fallback that renders while the variant builds
        // off-thread). Built-ins only; external DEs render on the compute
        // shells (guarded above by deFunctionCount / spike scope).
        var chosenPipeline = pipeline
        var chosenTable = deTable
        var specialized: SpecializedRaster? = overrideSpecialized
        let deIndex = Int(uniforms.meta.y)
        if overrideSpecialized == nil,
           let plan = EncodePreamble.specializationPlan(for: request, deIndex: deIndex) {
            specialized = specializations.lookup(
                deFunctionName: plan.deFunctionName, spec: plan.spec)
        }
        if let s = specialized {
            chosenPipeline = s.pipeline
            chosenTable = s.deTable
        }

        let ringSlot = ringCursor
        let statsBuffer = statsRing[ringSlot]
        ringCursor = (ringCursor + 1) % statsRing.count
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.label = "raster stats zero"
        blit.fill(buffer: statsBuffer, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
        blit.endEncoding()

        // Hierarchical cone prepass (perf block 11): one coarse compute
        // dispatch per view finds each tile's safe start depth into an array
        // texture the fragment reads. Runs BEFORE the render pass; Metal's
        // automatic hazard tracking orders the compute-write → fragment-read.
        var coneTexture: MTLTexture? = nil
        if let s = specialized, let prepass = s.conePrepass,
           let target = renderPass.colorAttachments[0].texture {
            let tile = 8   // MUST match THRESH_CONE_TILE in RaymarchCore.metal
            let cw = (target.width + tile - 1) / tile
            let ch = (target.height + tile - 1) / tile
            let slices = max(1, amplificationCount)
            var coneTex = coneRing[ringSlot]
            if coneTex == nil || coneTex!.width != cw || coneTex!.height != ch
                || coneTex!.arrayLength != slices {
                let desc = MTLTextureDescriptor()
                desc.textureType = .type2DArray
                desc.pixelFormat = .r32Float
                desc.width = cw
                desc.height = ch
                desc.arrayLength = slices
                desc.usage = [.shaderWrite, .shaderRead]
                desc.storageMode = .private
                coneTex = context.device.makeTexture(descriptor: desc)
                coneRing[ringSlot] = coneTex
            }
            if let coneTex, let pre = commandBuffer.makeComputeCommandEncoder() {
                pre.label = "raster cone prepass"
                pre.setComputePipelineState(prepass)
                withUnsafeBytes(of: uniforms) { raw in
                    pre.setBytes(raw.baseAddress!, length: raw.count,
                                 index: Int(THRESH_BUFFER_UNIFORMS))
                }
                pre.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
                pre.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
                if let prepassTable = s.conePrepassDETable {
                    pre.setVisibleFunctionTable(
                        prepassTable, bufferIndex: GPUContext.deTableBufferIndex)
                }
                views.withUnsafeBytes { raw in
                    let base = raw.baseAddress!.advanced(by: viewsByteOffset)
                    pre.setBytes(base, length: raw.count - viewsByteOffset,
                                 index: Int(THRESH_BUFFER_VIEWS))
                }
                pre.setTexture(coneTex, index: 3)
                pre.dispatchThreadgroups(
                    MTLSize(width: (cw + 7) / 8, height: (ch + 7) / 8, depth: slices),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                pre.endEncoding()
                coneTexture = coneTex
            }
        }
        // A cone-baked pipeline REQUIRES the fragment cone texture; if the
        // prepass couldn't run, fall back to generic this frame.
        if specialized?.conePrepass != nil, coneTexture == nil {
            chosenPipeline = pipeline
            chosenTable = deTable
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPass)
        else { return false }
        encoder.label = "raster march"
        encoder.setRenderPipelineState(chosenPipeline)
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

        // SYNC-POINT: render binding contract — the same buffer indices /
        // palette layout the compute shells bind (OffscreenRenderer,
        // SessionGPUEncoder), through the fragment-stage API. Indices must match.
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setFragmentBytes(
                raw.baseAddress!, length: raw.count, index: Int(THRESH_BUFFER_UNIFORMS))
        }
        encoder.setFragmentBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
        encoder.setFragmentBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
        encoder.setFragmentBuffer(statsBuffer, offset: 0, index: Int(THRESH_BUFFER_STATS))
        if let chosenTable {
            encoder.setFragmentVisibleFunctionTable(
                chosenTable, bufferIndex: GPUContext.deTableBufferIndex)
        }
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
        if let coneTexture {
            encoder.setFragmentTexture(coneTexture, index: 3)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // AUDIT — nonisolated(unsafe): same contract as SessionGPUEncoder —
        // the handler reads the buffer only after the writing command buffer
        // completed, on Metal's completion thread; FrameStatsSlot is Sendable.
        nonisolated(unsafe) let completedStats = statsBuffer
        let slot = statsSlot
        let health = health
        commandBuffer.addCompletedHandler { completed in
            health.check(completed)
            let steps = UInt64(completedStats.contents().load(as: UInt32.self))
            let ms = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000.0
            slot.store(gpuMilliseconds: ms, totalSteps: steps)
        }
        return true
    }
}

// MARK: - RasterSpecializationCache

/// Non-blocking cache of specialized STEREO RASTER variants — the visionOS
/// counterpart of SpecializationCache. `lookup` never blocks: a miss schedules
/// ONE off-thread compile (source library once per DE, reused across baked
/// variants) and returns nil until it lands (the generic pipeline renders
/// meanwhile). Compiler-checked Sendable (a Mutex over Sendable state).
final class RasterSpecializationCache: Sendable {
    private struct State {
        var libraries: [String: MTLLibrary] = [:]        // per DE function name
        var ready: [String: SpecializedRaster] = [:]     // per (DE, spec)
        var inFlight: Set<String> = []
    }

    private let context: GPUContext
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private let maxViewCount: Int
    private let state = Mutex<State>(State())

    init(
        context: GPUContext, colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat, maxViewCount: Int
    ) {
        self.context = context
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.maxViewCount = maxViewCount
    }

    /// The specialized raster pipeline for a built-in DE, if compiled; nil on a
    /// miss (schedules the compile). Formats/maxViewCount are fixed per cache,
    /// so the key is just (DE, spec).
    func lookup(deFunctionName: String, spec: MarchSpec) -> SpecializedRaster? {
        let key = "\(deFunctionName)#\(spec.keyFragment)"
        if let hit = state.withLock({ $0.ready[key] }) { return hit }

        let shouldCompile: Bool = state.withLock { s in
            if s.ready[key] != nil { return false }
            return s.inFlight.insert(key).inserted
        }
        if shouldCompile {
            let context = context
            let colorFormat = colorFormat
            let depthFormat = depthFormat
            let maxViewCount = maxViewCount
            PipelineCompilationScheduler.shared.submit(
                label: "view-raster-specialization:\(deFunctionName)"
            ) { [self] in
                let library: MTLLibrary? = resolveLibrary(deFunctionName)
                let compiled = library.flatMap {
                    try? context.makeSpecializedRaster(
                        from: $0, deFunctionName: deFunctionName, spec: spec,
                        colorFormat: colorFormat, depthFormat: depthFormat,
                        maxViewCount: maxViewCount)
                }
                state.withLock { s in
                    s.inFlight.remove(key)
                    if let compiled { s.ready[key] = compiled }
                }
            }
        }
        return nil
    }

    /// Get-or-compile the per-DE specialized source library (shared shape with
    /// the OS Metal cache dedups a rare concurrent double-compile).
    private func resolveLibrary(_ deFunctionName: String) -> MTLLibrary? {
        if let cached = state.withLock({ $0.libraries[deFunctionName] }) {
            return cached
        }
        guard let library = try? context.compileSpecializedLibrary(
            deFunctionName: deFunctionName) else { return nil }
        state.withLock { $0.libraries[deFunctionName] = library }
        return library
    }
}
