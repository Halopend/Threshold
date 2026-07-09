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
    /// nil under static dispatch (the kernel has no table argument there).
    private let deTable: MTLVisibleFunctionTable?
    /// The THRESH_AUX generic twin (jittered ray-gen + world-t/motion
    /// writes), built EAGERLY at init so the temporal path can engage on
    /// frame 1 with no mid-loop compile — the same loop-start contract as
    /// the reconstructor's own pipelines.
    private let auxPipeline: MTLComputePipelineState
    /// nil under static dispatch, like `deTable`.
    private let auxDETable: MTLVisibleFunctionTable?
    /// The aux+seed generic twin (phase A2: history warm-start, fc 12) —
    /// eager for the same reason; seeding arms per frame (host gate) and
    /// must never wait on a compile.
    private let auxSeedPipeline: MTLComputePipelineState
    /// nil under static dispatch, like `deTable`.
    private let auxSeedDETable: MTLVisibleFunctionTable?
    private let colorFormat: MTLPixelFormat
    /// Ring of 3 — the same in-flight contract as ViewPassEncoder's rings.
    private let statsRing: [MTLBuffer]
    private var ringCursor = 0
    private let statsSlot = FrameStatsSlot()
    /// GPU-fault check for completed command buffers (observability phase 1).
    private let health = CommandBufferHealth(shell: "compositor.compute")
    private let specializations: ViewComputeSpecializationCache
    /// Intermediate (color, depth) array pairs + cone textures, one per
    /// in-flight slot; rebuilt on size/slice change. Cross-frame slot reuse
    /// is ordered by GPU hazard tracking (tracked .private resources) — a
    /// collision costs pipelining, never a torn read.
    private var colorRing: [MTLTexture?] = [nil, nil, nil]
    private var depthRing: [MTLTexture?] = [nil, nil, nil]
    private var coneRing: [MTLTexture?] = [nil, nil, nil]
    /// Temporal-path march outputs (world-t + motion), ring-parallel to the
    /// color/depth intermediates.
    private var tRing: [MTLTexture?] = [nil, nil, nil]
    private var motionRing: [MTLTexture?] = [nil, nil, nil]

    /// Swift mirror of RaymarchCore.metal's ThreshAuxUniforms (the SAME
    /// private buffer-7 contract the Mac path binds; on the view-compute
    /// path only `jitter` is read — prevViews supersede the pinhole fields).
    private struct AuxUniforms {
        var prevCamPosFov: SIMD4<Float> = .zero
        var prevCamQuat: SIMD4<Float> = SIMD4(0, 0, 0, 1)
        var jitter: SIMD4<Float>
    }

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
        self.deTable = context.staticDEDispatch ? nil : try GPUContext.makeDETable(
            pipeline, functions: context.builtinDEFunctions,
            label: "view-compute DE table")
        self.auxPipeline = try GPUContext.makeLinkedPipeline(
            device: context.device, library: context.library,
            kernelName: "march_view_compute",
            deFunctions: context.builtinDEFunctions, auxOutputs: true)
        self.auxDETable = context.staticDEDispatch ? nil : try GPUContext.makeDETable(
            auxPipeline, functions: context.builtinDEFunctions,
            label: "view-compute aux DE table")
        self.auxSeedPipeline = try GPUContext.makeLinkedPipeline(
            device: context.device, library: context.library,
            kernelName: "march_view_compute",
            deFunctions: context.builtinDEFunctions, auxOutputs: true,
            seed: true)
        self.auxSeedDETable = context.staticDEDispatch ? nil : try GPUContext.makeDETable(
            auxSeedPipeline, functions: context.builtinDEFunctions,
            label: "view-compute aux+seed DE table")

        var ring: [MTLBuffer] = []
        for i in 0..<3 {
            // Two counters: [0] march steps, [1] seed restarts (phase A2).
            guard let buffer = context.device.makeBuffer(
                length: 2 * MemoryLayout<UInt32>.stride,
                options: .storageModeShared)
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
        overrideSpecialized: SpecializedViewCompute? = nil,
        recon: TemporalReconstructor? = nil,
        prevViews: [ThreshViewUniforms]? = nil
    ) -> Bool {
        guard !views.isEmpty, views.count == colorTargets.count,
              depthTargets.count == colorTargets.count,
              let first = colorTargets.first,
              request.params.count >= Int(THRESH_SLOT_ENGINE_COUNT),
              Int(request.uniforms.meta.z) <= request.params.count,
              request.uniforms.meta.w < request.uniforms.meta.z,
              Int(request.uniforms.meta.y) < context.deFunctionCount
        else { return false }
        let outW = first.texture.width
        let outH = first.texture.height
        // The resolution lever (feature march.renderScale): with a
        // reconstructor, march into reduced multiple-of-8 intermediates and
        // present-upscale into the drawable-sized blit source. Without one
        // (parity tests, recon disabled) — or at scale 1, where marchSize
        // returns nil — every byte of this path is the pre-lever encode.
        // Ray-gen is resolution-independent (NDC from texture dims), so the
        // reduced march sees the same field of view.
        let marchSize: (width: Int, height: Int)? = recon == nil ? nil
            : TemporalReconstructor.marchSize(
                outputWidth: outW, outputHeight: outH,
                scale: request.renderScale)
        let w = marchSize?.width ?? outW
        let h = marchSize?.height ?? outH
        let slices = views.count

        // Temporal reconstruction (feature march.temporalRecon) arms only
        // when everything it needs exists: a mode, a reduced march, and the
        // previous frame's views (frame 1 has none — that frame runs the
        // phase-0 present and history starts on frame 2). Everything else
        // stays the phase-0 path so `off` is structurally identical.
        let temporal = recon != nil && (recon!.mode != .off)
            && marchSize != nil && prevViews?.count == views.count

        // Temporal seeding (phase A2): the reconstructor hands out its
        // history-aux read side when every gate passes (armed, valid history,
        // no reset pending, calm world, size match) — nil rides the plain
        // phase-A path, bit-identically.
        var seedTexture: MTLTexture? = nil
        if temporal, let recon {
            seedTexture = recon.seedTexture(
                volatility: request.worldVolatility,
                accWidth: recon.mode == .taau ? outW : w,
                accHeight: recon.mode == .taau ? outH : h,
                slices: slices)
        }
        let seeding = seedTexture != nil

        var uniforms = request.uniforms
        uniforms.meta.x = UInt32(request.ops.count)

        guard let paramsBuffer = try? context.makeFloatBuffer(
                  request.params, label: "view-compute param table"),
              let opsBuffer = try? context.makeOpsBuffer(request.ops)
        else { return false }

        // Pipeline choice: specialized once compiled + tuning allows, else
        // generic (renders while the variant builds off-thread). The
        // temporal path selects the aux twins — with-seed or without per the
        // gate above (both init-built, so neither ever waits on a compile).
        var chosenPipeline = temporal ? (seeding ? auxSeedPipeline : auxPipeline)
                                      : pipeline
        var chosenTable = temporal ? (seeding ? auxSeedDETable : auxDETable)
                                   : deTable
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
                spec: spec, aux: temporal, seed: seeding)
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
        blit.fill(buffer: statsBuffer,
                  range: 0..<(2 * MemoryLayout<UInt32>.stride), value: 0)
        blit.endEncoding()

        // Intermediates (color + depth arrays sized to the march target).
        // Temporal marches accumulate in LINEAR float (an 8-bit sRGB history
        // would feedback-quantize); the present pass lands back in the
        // drawable's format for the blit.
        guard let color = ringTexture(
                  &colorRing, slot: ringSlot,
                  pixelFormat: temporal ? .rgba16Float : colorFormat,
                  width: w, height: h, slices: slices, label: "view-compute color"),
              let depth = ringTexture(
                  &depthRing, slot: ringSlot, pixelFormat: .r32Float,
                  width: w, height: h, slices: slices, label: "view-compute depth")
        else { return false }

        // Temporal march outputs + this frame's jitter (shared by both eyes;
        // the resolve removes the same offset it knows the march applied).
        var marchT: MTLTexture? = nil
        var marchMotion: MTLTexture? = nil
        var jitter = SIMD2<Float>(0, 0)
        if temporal, let recon {
            let accW = recon.mode == .taau ? outW : w
            guard let t = ringTexture(
                      &tRing, slot: ringSlot, pixelFormat: .r32Float,
                      width: w, height: h, slices: slices,
                      label: "view-compute world-t"),
                  let motion = ringTexture(
                      &motionRing, slot: ringSlot, pixelFormat: .rg16Float,
                      width: w, height: h, slices: slices,
                      label: "view-compute motion")
            else { return false }
            marchT = t
            marchMotion = motion
            jitter = recon.beginFrame(marchWidth: w, accWidth: accW)
        }

        // Hierarchical cone prepass (same kernel + tile map as the raster
        // backend — march_cone_prepass_view).
        var coneTexture: MTLTexture? = nil
        if let s = specialized, let prepass = s.conePrepass {
            let tile = 8   // MUST match THRESH_CONE_TILE in RaymarchCore.metal
            let cw = (w + tile - 1) / tile
            let ch = (h + tile - 1) / tile
            if let coneTex = ringTexture(
                   &coneRing, slot: ringSlot, pixelFormat: .r32Float,
                   width: cw, height: ch, slices: slices,
                   label: "view-compute cone"),
               let pre = commandBuffer.makeComputeCommandEncoder() {
                pre.label = "view-compute cone prepass"
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
                    pre.setBytes(raw.baseAddress!, length: raw.count,
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
        // A cone-baked pipeline REQUIRES the cone texture — fall back to
        // generic (the temporal path's aux/aux+seed twin) this frame if the
        // prepass couldn't run.
        if specialized?.conePrepass != nil, coneTexture == nil {
            chosenPipeline = temporal ? (seeding ? auxSeedPipeline : auxPipeline)
                                      : pipeline
            chosenTable = temporal ? (seeding ? auxSeedDETable : auxDETable)
                                   : deTable
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
        if let chosenTable {
            encoder.setVisibleFunctionTable(
                chosenTable, bufferIndex: GPUContext.deTableBufferIndex)
        }
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
        if temporal, let marchT, let marchMotion, let prevViews {
            // The aux contract: buffer 7 jitter, buffer 9 previous views,
            // textures 1/2 world-t + motion (RaymarchCore aux block).
            let aux = AuxUniforms(jitter: SIMD4(jitter.x, jitter.y, 0, 0))
            withUnsafeBytes(of: aux) { raw in
                encoder.setBytes(raw.baseAddress!, length: raw.count, index: 7)
            }
            prevViews.withUnsafeBytes { raw in
                encoder.setBytes(raw.baseAddress!, length: raw.count, index: 9)
            }
            encoder.setTexture(marchT, index: 1)
            encoder.setTexture(marchMotion, index: 2)
            // Seeding (phase A2): texture 5 = the history-aux read side —
            // the SAME texture this frame's resolve reads (two readers, no
            // hazard; the resolve writes the other ping-pong side).
            if let seedTexture {
                encoder.setTexture(seedTexture, index: 5)
            }
        }
        encoder.dispatchThreadgroups(
            MTLSize(width: (w + 7) / 8, height: (h + 7) / 8, depth: slices),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()

        // Present: at reduced march size, upsample+sharpen into
        // drawable-sized intermediates; at full size the march textures ARE
        // the blit source (no extra pass, byte-identical to the pre-lever
        // path). The temporal path inserts the resolve between march and
        // present, and presents from the RESOLVED history instead. A failed
        // allocation anywhere drops the frame — the standing contract.
        var blitColor = color
        var blitDepth = depth
        if temporal, let recon, let marchT, let marchMotion, let prevViews {
            guard let resolved = recon.encodeResolve(
                commandBuffer: commandBuffer,
                marchColor: color, marchT: marchT, marchMotion: marchMotion,
                views: views, prevViews: prevViews,
                outputWidth: outW, outputHeight: outH,
                volatility: request.worldVolatility, slices: slices),
                  let presented = recon.encodePresentResolved(
                commandBuffer: commandBuffer, slot: ringSlot,
                resolvedColor: resolved.color, resolvedAux: resolved.aux,
                views: views, outputWidth: outW, outputHeight: outH,
                slices: slices,
                farDistance: request.params[Int(THRESH_SLOT_MAX_DIST)])
            else { return false }
            blitColor = presented.color
            blitDepth = presented.depth
        } else if marchSize != nil, let recon {
            guard let presented = recon.encodePresent(
                commandBuffer: commandBuffer, slot: ringSlot,
                srcColor: color, srcDepth: depth,
                outputWidth: outW, outputHeight: outH, slices: slices)
            else { return false }
            blitColor = presented.color
            blitDepth = presented.depth
        }

        // Blit intermediates → drawable textures, one slice per view.
        guard let copy = commandBuffer.makeBlitCommandEncoder() else { return false }
        copy.label = "view-compute present copy"
        for (i, target) in colorTargets.enumerated() {
            copy.copy(
                from: blitColor, sourceSlice: i, sourceLevel: 0,
                to: target.texture, destinationSlice: target.slice,
                destinationLevel: 0, sliceCount: 1, levelCount: 1)
            copy.copy(
                from: blitDepth, sourceSlice: i, sourceLevel: 0,
                to: depthTargets[i].texture, destinationSlice: depthTargets[i].slice,
                destinationLevel: 0, sliceCount: 1, levelCount: 1)
        }
        copy.endEncoding()

        // AUDIT — nonisolated(unsafe): same contract as the other encoders —
        // the handler reads the buffer only after the writing command buffer
        // completed, on Metal's completion thread; FrameStatsSlot is Sendable.
        nonisolated(unsafe) let completedStats = statsBuffer
        let slot = statsSlot
        let health = health
        commandBuffer.addCompletedHandler { completed in
            health.check(completed)
            let steps = UInt64(completedStats.contents().load(as: UInt32.self))
            let restarts = UInt64(completedStats.contents().load(
                fromByteOffset: MemoryLayout<UInt32>.stride, as: UInt32.self))
            let ms = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000.0
            slot.store(gpuMilliseconds: ms, totalSteps: steps,
                       seedRestarts: restarts)
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
        var hits: [String: Int] = [:]
    }

    private let context: GPUContext
    private let state = Mutex<State>(State())
    private let buildQueue = DispatchQueue(
        label: "com.polinate.threshold.view-compute-specialization-build",
        qos: .utility)
    private let compileAfterHits = 8
    private let maxReadyVariants = 32

    init(context: GPUContext) {
        self.context = context
    }

    /// `aux` selects the THRESH_AUX (temporal-input) twin — cached under its
    /// own key (the SpecializationCache `#aux` suffix pattern); the live path
    /// needs both while reconstruction toggles. `seed` (phase A2, implies
    /// aux) adds the history warm-start bake under a further `#seed` suffix —
    /// seeding arms and disarms per frame (volatility gate), so both variants
    /// stay warm.
    func lookup(
        deFunctionName: String, spec: MarchSpec, aux: Bool = false,
        seed: Bool = false
    ) -> SpecializedViewCompute? {
        let key = "\(deFunctionName)#\(spec.keyFragment)"
            + (aux ? "#aux" : "") + (seed ? "#seed" : "")
        if let hit = state.withLock({ $0.ready[key] }) { return hit }

        let shouldCompile: Bool = state.withLock { s in
            if s.ready[key] != nil { return false }
            let hits = (s.hits[key] ?? 0) + 1
            s.hits[key] = hits
            guard hits >= compileAfterHits else { return false }
            return s.inFlight.insert(key).inserted
        }
        if shouldCompile {
            let context = context
            buildQueue.async { [self] in
                let library: MTLLibrary? = resolveLibrary(deFunctionName)
                let compiled = library.flatMap {
                    try? context.makeSpecializedViewCompute(
                        from: $0, deFunctionName: deFunctionName, spec: spec,
                        auxOutputs: aux, seed: seed)
                }
                state.withLock { s in
                    s.inFlight.remove(key)
                    if let compiled {
                        s.ready[key] = compiled
                        if s.ready.count > maxReadyVariants,
                           let evict = s.ready.keys.first(where: { $0 != key }) {
                            s.ready.removeValue(forKey: evict)
                        }
                    }
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
