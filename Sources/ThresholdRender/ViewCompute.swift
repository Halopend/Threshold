// ViewCompute.swift — the per-view COMPUTE march backend (ADR-001 "compute
// phase 2", perf block 13): the compositor shell's optional alternative to
// the raster fragment path.
//
// Same per-frame contract as ViewPassEncoder (stats ring, never blocks, drops
// bad frames, async specialization, cone prepass) but the march is a compute
// dispatch over (w, h, viewCount) into intermediate color/depth ARRAYS, then
// blits into the drawable's textures:
//   color: same pixel format as the drawable (sRGB variants are
//          copy-compatible; compute writes linear → hardware sRGB encode)
//   depth: r32Float intermediate → depth32Float drawable (the documented
//          copy-compatible pair; depth formats are never compute-writable)
//
// Why an OPTION and not the default: compute cannot consume rasterization
// rate maps, so foveated rendering is unavailable — the backend is chosen at
// layer configuration (foveation off). What compute may win back on device:
// threadgroup-coherent march scheduling and no fragment-interlock overhead.
// The Mac parity test proves compute-view ≡ raster-view off-device; the FPS
// answer needs a Vision Pro sweep.
//
// This file is deliberately NOT #if os(visionOS) — same reasoning as
// ViewPass.swift: the encoder renders into any texture pair, so the Mac
// suite validates it before it reaches the device.

import Foundation
import Metal
import Synchronization
import ThresholdShaderABI
import ThresholdShaderIR

// MARK: - ViewComputeEncoder

/// Render-thread-confined encoder for the per-view compute march.
final class ViewComputeEncoder {
    private let context: GPUContext
    private let pipeline: MTLComputePipelineState
    private let deTable: MTLVisibleFunctionTable
    private let colorFormat: MTLPixelFormat
    /// Ring of 3 — the same in-flight contract as ViewPassEncoder's rings.
    private let statsRing: [MTLBuffer]
    private var ringCursor = 0
    private let statsSlot = FrameStatsSlot()
    private let specializations: ViewComputeSpecializationCache
    /// Intermediate (color, depth) array pairs + cone textures, one per
    /// in-flight slot; rebuilt on size/slice change. Cross-frame slot reuse
    /// is ordered by GPU hazard tracking (tracked .private resources) — a
    /// collision costs pipelining, never a torn read.
    private var colorRing: [MTLTexture?] = [nil, nil, nil]
    private var depthRing: [MTLTexture?] = [nil, nil, nil]
    /// Per-ring-slot cone textures, ONE ARRAY PER LEVEL (block 18 multi-level);
    /// each entry is a texture2d_array (one slice per view).
    private var coneRing: [[MTLTexture]] = [[], [], []]

    /// `colorFormat` must match the drawable's (blit copies require identical
    /// or sRGB-variant formats).
    init(context: GPUContext, colorFormat: MTLPixelFormat) throws {
        self.context = context
        self.colorFormat = colorFormat
        self.specializations = ViewComputeSpecializationCache(context: context)

        // Generic pipeline: the always-correct fallback while variants build.
        self.pipeline = try GPUContext.makeLinkedPipeline(
            device: context.device, library: context.library,
            kernelName: "march_view_compute",
            deFunctions: context.builtinDEFunctions)
        self.deTable = try GPUContext.makeDETable(
            pipeline, functions: context.builtinDEFunctions,
            label: "view-compute DE table")

        var ring: [MTLBuffer] = []
        for i in 0..<3 {
            guard let buffer = context.device.makeBuffer(
                length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else { throw RenderError.allocationFailed("view-compute stats buffer \(i)") }
            buffer.label = "view-compute stats \(i)"
            ring.append(buffer)
        }
        self.statsRing = ring
    }

    /// Stats of the most recently COMPLETED frame (zeros until one finishes).
    func lastCompleted() -> FrameStatsSlot.Stats {
        statsSlot.load()
    }

    /// March every view into intermediates and blit into the drawable's
    /// textures. `colorTargets`/`depthTargets` are per-view destination
    /// (texture, slice) pairs — array textures in the layered layout, distinct
    /// textures (slice 0) in the dedicated layout. Returns false on a
    /// malformed request / external DE (compute backend links built-ins only,
    /// same spike scope as the raster path).
    ///
    /// `overrideSpecialized` is the deterministic test seam (production
    /// callers leave it nil — the async cache lands variants off-thread).
    @discardableResult
    func encode(
        _ request: RenderRequest,
        views: [ThreshViewUniforms],
        colorTargets: [(texture: MTLTexture, slice: Int)],
        depthTargets: [(texture: MTLTexture, slice: Int)],
        commandBuffer: MTLCommandBuffer,
        overrideSpecialized: SpecializedViewCompute? = nil
    ) -> Bool {
        guard !views.isEmpty, views.count == colorTargets.count,
              depthTargets.count == colorTargets.count,
              let first = colorTargets.first,
              request.params.count >= Int(THRESH_SLOT_ENGINE_COUNT),
              Int(request.uniforms.meta.z) <= request.params.count,
              request.uniforms.meta.w < request.uniforms.meta.z,
              Int(request.uniforms.meta.y) < context.deFunctionCount
        else { return false }
        let w = first.texture.width
        let h = first.texture.height
        let slices = views.count

        var uniforms = request.uniforms
        uniforms.meta.x = UInt32(request.ops.count)

        guard let paramsBuffer = try? context.makeFloatBuffer(
                  request.params, label: "view-compute param table"),
              let opsBuffer = try? context.makeOpsBuffer(request.ops)
        else { return false }

        // Pipeline choice: specialized once compiled + tuning allows, else
        // generic (renders while the variant builds off-thread).
        var chosenPipeline = pipeline
        var chosenTable = deTable
        var specialized: SpecializedViewCompute? = overrideSpecialized
        let deIndex = Int(uniforms.meta.y)
        if overrideSpecialized == nil,
           request.tuning.specializationEnabled,
           DERegistry.builtin.indices.contains(deIndex) {
            let spec = MarchSpec.from(
                tuning: request.tuning, params: request.params,
                opCount: uniforms.meta.x)
            specialized = specializations.lookup(
                deFunctionName: DERegistry.builtin[deIndex].mslFunctionName,
                spec: spec)
        }
        if let s = specialized {
            chosenPipeline = s.pipeline
            chosenTable = s.deTable
        }

        let ringSlot = ringCursor
        let statsBuffer = statsRing[ringSlot]
        ringCursor = (ringCursor + 1) % statsRing.count
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.label = "view-compute stats zero"
        blit.fill(buffer: statsBuffer, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
        blit.endEncoding()

        // Intermediates (color + depth arrays sized to the march target).
        guard let color = ringTexture(
                  &colorRing, slot: ringSlot, pixelFormat: colorFormat,
                  width: w, height: h, slices: slices, label: "view-compute color"),
              let depth = ringTexture(
                  &depthRing, slot: ringSlot, pixelFormat: .r32Float,
                  width: w, height: h, slices: slices, label: "view-compute depth")
        else { return false }

        // Hierarchical cone prepass (same kernel + tile map as the raster
        // backend — march_cone_prepass_view).
        var coneTexture: MTLTexture? = nil
        if let s = specialized, let prepass = s.conePrepass,
           let prepassTable = s.conePrepassDETable {
            let plan = ConePrepassPlan.levels(
                levelCount: request.tuning.conePrepassLevels,
                fullWidth: w, fullHeight: h,
                stepBudget: request.tuning.conePrepassStepBudget,
                iterScale: request.tuning.conePrepassIterScale)
            let wantSizes = plan.map {
                ConePrepassPlan.textureSize(
                    tileSize: $0.tileSize, fullWidth: w, fullHeight: h)
            }
            let cacheOK = coneRing[ringSlot].count == wantSizes.count
                && zip(coneRing[ringSlot], wantSizes).allSatisfy {
                    $0.width == $1.width && $0.height == $1.height
                        && $0.arrayLength == slices
                }
            if !cacheOK {
                coneRing[ringSlot] = wantSizes.compactMap { size in
                    let desc = MTLTextureDescriptor()
                    desc.textureType = .type2DArray
                    desc.pixelFormat = .r32Float
                    desc.width = size.width
                    desc.height = size.height
                    desc.arrayLength = slices
                    desc.usage = [.shaderWrite, .shaderRead]
                    desc.storageMode = .private
                    return context.device.makeTexture(descriptor: desc)
                }
            }
            let textures = coneRing[ringSlot]
            if textures.count == plan.count {
                for (i, level) in plan.enumerated() {
                    let out = textures[i]
                    let prev = i == 0 ? out : textures[i - 1]
                    guard let pre = commandBuffer.makeComputeCommandEncoder() else { break }
                    pre.label = "view-compute cone prepass L\(i)"
                    pre.setComputePipelineState(prepass)
                    withUnsafeBytes(of: uniforms) { raw in
                        pre.setBytes(raw.baseAddress!, length: raw.count,
                                     index: Int(THRESH_BUFFER_UNIFORMS))
                    }
                    pre.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
                    pre.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
                    pre.setVisibleFunctionTable(
                        prepassTable, bufferIndex: GPUContext.deTableBufferIndex)
                    views.withUnsafeBytes { raw in
                        pre.setBytes(raw.baseAddress!, length: raw.count,
                                     index: Int(THRESH_BUFFER_VIEWS))
                    }
                    var cp = level.params
                    withUnsafeBytes(of: &cp) { raw in
                        pre.setBytes(raw.baseAddress!, length: raw.count, index: 8)
                    }
                    pre.setTexture(out, index: 3)
                    pre.setTexture(prev, index: 5)
                    pre.dispatchThreadgroups(
                        MTLSize(width: (out.width + 7) / 8,
                                height: (out.height + 7) / 8, depth: slices),
                        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                    pre.endEncoding()
                }
                coneTexture = textures.last
            }
        }
        // A cone-baked pipeline REQUIRES the cone texture — fall back to
        // generic this frame if the prepass couldn't run.
        if specialized?.conePrepass != nil, coneTexture == nil {
            chosenPipeline = pipeline
            chosenTable = deTable
        }

        // The march: one compute grid over every view.
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "view-compute march"
        encoder.setComputePipelineState(chosenPipeline)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_UNIFORMS))
        }
        encoder.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
        encoder.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
        encoder.setBuffer(statsBuffer, offset: 0, index: Int(THRESH_BUFFER_STATS))
        encoder.setVisibleFunctionTable(
            chosenTable, bufferIndex: GPUContext.deTableBufferIndex)
        let paletteBytes = PaletteWire.bytes(request.palette)
        paletteBytes.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_PALETTE))
        }
        views.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_VIEWS))
        }
        encoder.setTexture(color, index: Int(THRESH_TEXTURE_OUTPUT))
        encoder.setTexture(depth, index: 4)   // THRESH_TEXTURE_VIEW_DEPTH
        if let coneTexture {
            encoder.setTexture(coneTexture, index: 3)
        }
        encoder.dispatchThreadgroups(
            MTLSize(width: (w + 7) / 8, height: (h + 7) / 8, depth: slices),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()

        // Blit intermediates → drawable textures, one slice per view.
        guard let copy = commandBuffer.makeBlitCommandEncoder() else { return false }
        copy.label = "view-compute present copy"
        for (i, target) in colorTargets.enumerated() {
            copy.copy(
                from: color, sourceSlice: i, sourceLevel: 0,
                to: target.texture, destinationSlice: target.slice,
                destinationLevel: 0, sliceCount: 1, levelCount: 1)
            copy.copy(
                from: depth, sourceSlice: i, sourceLevel: 0,
                to: depthTargets[i].texture, destinationSlice: depthTargets[i].slice,
                destinationLevel: 0, sliceCount: 1, levelCount: 1)
        }
        copy.endEncoding()

        // AUDIT — nonisolated(unsafe): same contract as the other encoders —
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

    /// Get-or-rebuild one ring slot's private array texture.
    private func ringTexture(
        _ ring: inout [MTLTexture?], slot: Int, pixelFormat: MTLPixelFormat,
        width: Int, height: Int, slices: Int, label: String
    ) -> MTLTexture? {
        if let cached = ring[slot], cached.width == width,
           cached.height == height, cached.arrayLength == slices,
           cached.pixelFormat == pixelFormat {
            return cached
        }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = pixelFormat
        desc.width = width
        desc.height = height
        desc.arrayLength = slices
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        let texture = context.device.makeTexture(descriptor: desc)
        texture?.label = "\(label) [\(slot)]"
        ring[slot] = texture
        return texture
    }
}

// MARK: - ViewComputeSpecializationCache

/// Non-blocking cache of specialized view-compute variants — the compute-
/// backend sibling of RasterSpecializationCache (same shape; format-free).
final class ViewComputeSpecializationCache: Sendable {
    private struct State {
        var libraries: [String: MTLLibrary] = [:]
        var ready: [String: SpecializedViewCompute] = [:]
        var inFlight: Set<String> = []
    }

    private let context: GPUContext
    private let state = Mutex<State>(State())

    init(context: GPUContext) {
        self.context = context
    }

    func lookup(deFunctionName: String, spec: MarchSpec) -> SpecializedViewCompute? {
        let key = "\(deFunctionName)#\(spec.keyFragment)"
        if let hit = state.withLock({ $0.ready[key] }) { return hit }

        let shouldCompile: Bool = state.withLock { s in
            if s.ready[key] != nil { return false }
            return s.inFlight.insert(key).inserted
        }
        if shouldCompile {
            let context = context
            Task.detached(priority: .utility) { [self] in
                let library: MTLLibrary? = resolveLibrary(deFunctionName)
                let compiled = library.flatMap {
                    try? context.makeSpecializedViewCompute(
                        from: $0, deFunctionName: deFunctionName, spec: spec)
                }
                state.withLock { s in
                    s.inFlight.remove(key)
                    if let compiled { s.ready[key] = compiled }
                }
            }
        }
        return nil
    }

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
