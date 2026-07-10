// SkipVolume.swift — host for the world-space empty-space skip-volume
// (function_constant 11), the DE-adapted port of BorgVR's hashed brick paging
// (see the MIT notice in RaymarchCore.metal). Opt-in and self-contained: it
// owns its own pipelines (built only when one is constructed — the same
// discipline as TemporalReconstructor), so GPUContext and every path that
// never asks for a skip-volume pay nothing.
//
// Per frame the host: (1) derives a camera-centred world brick grid from the
// far distance, (2) clears the GPU hash table (all probe slots empty, the
// overflow word cleared), (3) dispatches build_skip_volume — one thread per
// brick, DE-evaluated occupancy. The march then binds the same uniforms +
// table (buffers 9 / 10) and skips provably-empty bricks. Off unless a caller
// hands render() a SkipVolume, so goldens/benches are untouched by default.
//
// Render-thread confined by contract (one render() at a time), like the
// OffscreenRenderer caches it rides alongside.

import Foundation
import Metal
import ThresholdShaderABI

public final class SkipVolume {

    /// Storage for the occupancy the march consults each step. `hashed` is the
    /// BorgVR port (sparse, memory-frugal at extreme resolution, but a probe
    /// per step); `dense` is one direct indexed read per step (the cheapest
    /// lookup — the fair test of whether empty-space skipping helps at all).
    public enum Mode: String, Sendable, CaseIterable {
        case hashed
        case dense
        /// Dense final-DE samples keyed by the resolved geometry state. Unlike
        /// the occupancy experiments above, this grid is anchored at the
        /// model origin and survives camera/FOV changes.
        case distance
    }

    public struct CacheMetrics: Sendable, Equatable {
        public fileprivate(set) var hits = 0
        public fileprivate(set) var misses = 0
        public fileprivate(set) var builds = 0
        public fileprivate(set) var evictions = 0
        public fileprivate(set) var residentBytes = 0
    }

    public struct DiagnosticImage: Sendable {
        public let rgba8: [UInt8]
        public let width: Int
        public let height: Int
    }

    /// Swift mirror of MSL `ThreshSkipUniforms` (buffer 9). 48 bytes; layout
    /// pinned by SkipVolumeTests.
    struct Uniforms {
        var originExtent: SIMD4<Float>   // xyz world min corner, w = brick size
        var gridDim: SIMD4<UInt32>       // xyz brick counts, w unused
        var margin: Float                // empty iff DE(centre) > circumR·(1+margin)
        var tableSize: UInt32            // hashed: probe slots; dense: brick count
        var probeMax: UInt32
        var mode: UInt32 = 0             // 0 = hashed, 1 = dense
    }

    /// Bricks per axis of the camera-centred grid. Coarser = cheaper build,
    /// fewer skips; finer = more skips, bigger table. Tunable for the A/B.
    let gridResolution: Int
    /// Occupancy storage (hashed BorgVR port vs dense direct-index).
    public let mode: Mode
    /// DE over-estimation tolerance in the emptiness test (larger = safer,
    /// fewer skips). 0.5 tolerates a 1.5× over-estimate under warp ops.
    let margin: Float
    /// Linear-probe attempts before the build flags overflow (skip disabled
    /// that frame). 32 with the sub-0.5 load factor below ⇒ overflow never
    /// fires in practice.
    let probeMax: Int
    /// Half-extent of the model-origin-anchored distance field. Nil selects a
    /// practical 8-world-unit default, clamped by maxDist.
    let worldHalfExtent: Float?
    let cacheCapacity: Int

    private let context: GPUContext
    /// march_offscreen with THRESH_SKIP baked true (generic DE dispatch).
    let marchPipeline: MTLComputePipelineState
    let marchDETable: MTLVisibleFunctionTable
    private let buildPipeline: MTLComputePipelineState
    private let buildDETable: MTLVisibleFunctionTable

    /// Rebuilt on grid-size change. `.private`: GPU-only, cleared each frame.
    private var hashtable: MTLBuffer?
    private var hashtableSlots: Int = 0   // tableSize (probe slots), +1 overflow word

    private struct DistanceEntry {
        let buffer: MTLBuffer
        let uniforms: Uniforms
        var access: UInt64
    }
    private var distanceEntries: [UInt64: DistanceEntry] = [:]
    private var pendingKey: UInt64?
    private var accessClock: UInt64 = 0
    private(set) var needsBuild = true
    public private(set) var cacheMetrics = CacheMetrics()

    /// This frame's uniforms — computed by prepare(), consumed by the march.
    private(set) var uniforms = Uniforms(
        originExtent: .zero, gridDim: .zero, margin: 0, tableSize: 0, probeMax: 0)

    public init(context: GPUContext, gridResolution: Int = 64,
                mode: Mode = .hashed,
                margin: Float = 0.5, probeMax: Int = 32,
                worldHalfExtent: Float? = nil,
                cacheCapacity: Int = 4) throws {
        self.context = context
        self.gridResolution = max(8, gridResolution)
        self.mode = mode
        self.margin = max(0, margin)
        self.probeMax = max(1, probeMax)
        self.worldHalfExtent = worldHalfExtent.map { max($0, 1e-3) }
        self.cacheCapacity = max(1, cacheCapacity)
        self.marchPipeline = try GPUContext.makeLinkedPipeline(
            device: context.device, library: context.library,
            kernelName: "march_offscreen",
            deFunctions: context.builtinDEFunctions, skipVolume: true)
        self.marchDETable = try GPUContext.makeDETable(
            marchPipeline, functions: context.builtinDEFunctions,
            label: "skip march DE table")
        self.buildPipeline = try GPUContext.makeLinkedPipeline(
            device: context.device, library: context.library,
            kernelName: "build_skip_volume",
            deFunctions: context.builtinDEFunctions)
        self.buildDETable = try GPUContext.makeDETable(
            buildPipeline, functions: context.builtinDEFunctions,
            label: "skip build DE table")
    }

    /// The hash table the march binds at buffer 10 (valid after prepare()).
    var table: MTLBuffer? { hashtable }

    /// Derive this frame's grid + table sizing from the camera and far
    /// distance, allocating the table on first use / grid change. Returns
    /// false only on allocation failure (caller falls back to a plain march).
    @discardableResult
    func prepare(uniforms frameUniforms: ThreshFrameUniforms,
                 params: [Float], ops: [ThreshWarpOp] = []) -> Bool {
        let maxDist = max(params.count > Int(THRESH_SLOT_MAX_DIST)
            ? params[Int(THRESH_SLOT_MAX_DIST)] : 1, 1e-3)
        // The original occupancy experiments follow the camera. The distance
        // cache is fixed at model/world origin: camera translation, rotation,
        // FOV, output resolution, and stereo eye changes all reuse it.
        let g = gridResolution
        let halfExtent = mode == .distance
            ? min(worldHalfExtent ?? 8, maxDist)
            : maxDist
        let brick = (2 * halfExtent) / Float(g)
        let cam = frameUniforms.camPosFov
        let origin = mode == .distance
            ? SIMD3<Float>(repeating: -halfExtent)
            : SIMD3<Float>(cam.x, cam.y, cam.z) - maxDist

        let brickCount = g * g * g
        // Dense: exactly one occupancy word per brick (indexed by brick).
        // Hashed: 1.5× headroom (occupied is a strict subset — half the box
        // sits behind the camera and never inserts; verified 2026-07-06 that
        // overflow was NOT the cause of zero-skip scenes).
        let tableSize = mode == .hashed ? brickCount + brickCount / 2 : brickCount

        uniforms = Uniforms(
            originExtent: SIMD4(origin.x, origin.y, origin.z, brick),
            gridDim: SIMD4(UInt32(g), UInt32(g), UInt32(g), 0),
            margin: margin,
            tableSize: UInt32(tableSize),
            probeMax: UInt32(probeMax),
            mode: mode == .hashed ? 0 : (mode == .dense ? 1 : 2))

        if mode == .distance {
            let key = geometrySignature(
                uniforms: frameUniforms, params: params, ops: ops,
                originExtent: uniforms.originExtent)
            accessClock &+= 1
            if var entry = distanceEntries[key] {
                entry.access = accessClock
                distanceEntries[key] = entry
                hashtable = entry.buffer
                hashtableSlots = tableSize
                uniforms = entry.uniforms
                pendingKey = nil
                needsBuild = false
                cacheMetrics.hits += 1
                return true
            }

            cacheMetrics.misses += 1
            let length = (tableSize + 1) * MemoryLayout<UInt32>.stride
            guard let buffer = context.device.makeBuffer(
                length: length, options: .storageModeShared) else {
                hashtable = nil
                return false
            }
            buffer.label = "view-invariant distance cache (\(g)³)"
            hashtable = buffer
            hashtableSlots = tableSize
            pendingKey = key
            needsBuild = true
            return true
        }

        if hashtable == nil || hashtableSlots != tableSize {
            // +1 word: the overflow flag sits one past the probe slots.
            let length = (tableSize + 1) * MemoryLayout<UInt32>.stride
            guard let buffer = context.device.makeBuffer(
                length: length, options: .storageModePrivate) else {
                hashtable = nil
                return false
            }
            buffer.label = "skip-volume hashtable (\(g)³)"
            hashtable = buffer
            hashtableSlots = tableSize
        }
        needsBuild = true
        return hashtable != nil
    }

    /// Clear the table (all probe slots → empty 0xFFFFFFFF, overflow word → 0)
    /// then dispatch the DE-occupancy build. Call after prepare(), before the
    /// march, on the same command buffer.
    func encodeBuild(commandBuffer: MTLCommandBuffer,
                     uniforms frameUniforms: ThreshFrameUniforms,
                     paramsBuffer: MTLBuffer, opsBuffer: MTLBuffer) {
        guard let hashtable else { return }
        let slotBytes = hashtableSlots * MemoryLayout<UInt32>.stride

        // Clear. Hashed: probe slots → 0xFF (empty marker), overflow word → 0.
        // Dense: the whole buffer → 0 (empty); the build writes 1 for occupied.
        if mode != .distance, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "skip-volume clear"
            let fill: UInt8 = mode == .dense ? 0x00 : 0xFF
            blit.fill(buffer: hashtable, range: 0..<slotBytes, value: fill)
            blit.fill(buffer: hashtable,
                      range: slotBytes..<(slotBytes + MemoryLayout<UInt32>.stride),
                      value: 0x00)
            blit.endEncoding()
        }

        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "build_skip_volume"
        enc.setComputePipelineState(buildPipeline)
        withUnsafeBytes(of: frameUniforms) { raw in
            enc.setBytes(raw.baseAddress!, length: raw.count,
                         index: Int(THRESH_BUFFER_UNIFORMS))
        }
        enc.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
        enc.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
        enc.setVisibleFunctionTable(
            buildDETable, bufferIndex: GPUContext.deTableBufferIndex)
        withUnsafeBytes(of: uniforms) { raw in
            enc.setBytes(raw.baseAddress!, length: raw.count, index: 9)  // SKIP_UNIFORMS
        }
        enc.setBuffer(hashtable, offset: 0, index: 10)                   // SKIP_TABLE

        let g = gridResolution
        let tg = MTLSize(width: 4, height: 4, depth: 4)
        let groups = MTLSize(width: (g + 3) / 4, height: (g + 3) / 4, depth: (g + 3) / 4)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()

        if mode == .distance, let key = pendingKey {
            while distanceEntries.count >= cacheCapacity,
                  let victim = distanceEntries.min(by: { $0.value.access < $1.value.access })?.key {
                distanceEntries.removeValue(forKey: victim)
                cacheMetrics.evictions += 1
            }
            distanceEntries[key] = DistanceEntry(
                buffer: hashtable, uniforms: uniforms, access: accessClock)
            pendingKey = nil
            needsBuild = false
            cacheMetrics.builds += 1
            cacheMetrics.residentBytes = distanceEntries.values.reduce(0) {
                $0 + $1.buffer.length
            }
        }
    }

    /// Bind the skip uniforms (buffer 9) + table (buffer 10) into a march
    /// encoder already set up with the skip march pipeline.
    func bindMarch(_ enc: MTLComputeCommandEncoder) {
        guard let hashtable else { return }
        withUnsafeBytes(of: uniforms) { raw in
            enc.setBytes(raw.baseAddress!, length: raw.count, index: 9)
        }
        enc.setBuffer(hashtable, offset: 0, index: 10)
    }

    /// XY slice through the centre of the active distance field. Near-surface
    /// samples are white, positive/empty samples blue, and negative/interior
    /// samples orange. This is intentionally a data diagnostic, not a beauty
    /// render: voxel resolution and missed thin features are immediately
    /// visible.
    public func diagnosticImage() -> DiagnosticImage? {
        guard mode == .distance, let hashtable else { return nil }
        let g = gridResolution
        let z = g / 2
        let values = hashtable.contents().bindMemory(to: UInt32.self, capacity: g * g * g)
        let cell = uniforms.originExtent.w
        var rgba = [UInt8](repeating: 255, count: g * g * 4)
        for y in 0..<g {
            for x in 0..<g {
                let i3 = x + y * g + z * g * g
                let d = Float(bitPattern: values[i3])
                let magnitude = d.isFinite ? min(abs(d) / max(cell * 3, 1e-6), 1) : 1
                let near = UInt8((1 - magnitude) * 255)
                let i = (x + (g - 1 - y) * g) * 4
                if !d.isFinite {
                    rgba[i] = 255; rgba[i + 1] = 0; rgba[i + 2] = 255
                } else if d < 0 {
                    rgba[i] = 255; rgba[i + 1] = near; rgba[i + 2] = UInt8(Float(near) * 0.25)
                } else {
                    rgba[i] = near
                    rgba[i + 1] = UInt8(min(255, Int(near) + 32))
                    rgba[i + 2] = 255
                }
            }
        }
        return DiagnosticImage(rgba8: rgba, width: g, height: g)
    }

    private func geometrySignature(
        uniforms: ThreshFrameUniforms, params: [Float], ops: [ThreshWarpOp],
        originExtent: SIMD4<Float>
    ) -> UInt64 {
        // Stable FNV-1a over only mapScene inputs. Camera/FOV, time (unused by
        // built-ins), palette and post-processing are excluded. This avoids
        // needless rebuilds while keeping geometry changes exact.
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt32) {
            var v = value
            for _ in 0..<4 {
                hash ^= UInt64(v & 0xff)
                hash &*= 0x100000001b3
                v >>= 8
            }
        }
        mix(uniforms.meta.x); mix(uniforms.meta.y)
        mix(uniforms.meta.z); mix(uniforms.meta.w)
        mix(uniforms.scaleCtx.z.bitPattern)
        mix(uniforms.scaleCtx.w.bitPattern)
        mix(originExtent.w.bitPattern)
        let lo = min(Int(uniforms.meta.w), params.count)
        let hi = min(max(Int(uniforms.meta.z), lo), params.count)
        for value in params[lo..<hi] { mix(value.bitPattern) }
        for op in ops {
            withUnsafeBytes(of: op) { raw in
                for byte in raw {
                    hash ^= UInt64(byte)
                    hash &*= 0x100000001b3
                }
            }
        }
        return hash
    }
}
