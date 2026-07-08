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
    public enum Mode: String, Sendable, CaseIterable { case hashed, dense }

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

    private let context: GPUContext
    /// march_offscreen with THRESH_SKIP baked true (generic DE dispatch).
    let marchPipeline: MTLComputePipelineState
    let marchDETable: MTLVisibleFunctionTable
    private let buildPipeline: MTLComputePipelineState
    private let buildDETable: MTLVisibleFunctionTable

    /// Rebuilt on grid-size change. `.private`: GPU-only, cleared each frame.
    private var hashtable: MTLBuffer?
    private var hashtableSlots: Int = 0   // tableSize (probe slots), +1 overflow word

    /// This frame's uniforms — computed by prepare(), consumed by the march.
    private(set) var uniforms = Uniforms(
        originExtent: .zero, gridDim: .zero, margin: 0, tableSize: 0, probeMax: 0)

    public init(context: GPUContext, gridResolution: Int = 64,
                mode: Mode = .hashed,
                margin: Float = 0.5, probeMax: Int = 32) throws {
        self.context = context
        self.gridResolution = max(8, gridResolution)
        self.mode = mode
        self.margin = max(0, margin)
        self.probeMax = max(1, probeMax)
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
                 params: [Float]) -> Bool {
        let maxDist = max(params.count > Int(THRESH_SLOT_MAX_DIST)
            ? params[Int(THRESH_SLOT_MAX_DIST)] : 1, 1e-3)
        // Camera-centred axis-aligned box of half-extent maxDist: every ray
        // travels at most maxDist, so the box contains all sample points.
        let g = gridResolution
        let brick = (2 * maxDist) / Float(g)
        let cam = frameUniforms.camPosFov
        let origin = SIMD3<Float>(cam.x, cam.y, cam.z) - maxDist

        let brickCount = g * g * g
        // Dense: exactly one occupancy word per brick (indexed by brick).
        // Hashed: 1.5× headroom (occupied is a strict subset — half the box
        // sits behind the camera and never inserts; verified 2026-07-06 that
        // overflow was NOT the cause of zero-skip scenes).
        let tableSize = mode == .dense ? brickCount : brickCount + brickCount / 2

        uniforms = Uniforms(
            originExtent: SIMD4(origin.x, origin.y, origin.z, brick),
            gridDim: SIMD4(UInt32(g), UInt32(g), UInt32(g), 0),
            margin: margin,
            tableSize: UInt32(tableSize),
            probeMax: UInt32(probeMax),
            mode: mode == .dense ? 1 : 0)

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
        if let blit = commandBuffer.makeBlitCommandEncoder() {
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
}
