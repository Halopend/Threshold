// FrequencyVolume.swift — view-invariant 3D distance-field convolution and
// adaptive supersampling experiment (function constant 13).

import Foundation
import Metal
import ThresholdShaderABI

public final class FrequencyVolume {
    /// Swift mirror of MSL ThreshFrequencyUniforms (48 bytes).
    struct Uniforms {
        var originExtent: SIMD4<Float>
        var gridDim: SIMD4<UInt32>
        var threshold: Float
        var strength: Float
        var _pad0: UInt32 = 0
        var _pad1: UInt32 = 0
    }

    public struct Metrics: Sendable, Equatable {
        public fileprivate(set) var hits = 0
        public fileprivate(set) var misses = 0
        public fileprivate(set) var builds = 0
        public fileprivate(set) var residentBytes = 0
        /// Pixels that took the two additional sub-pixel rays in the latest
        /// completed frame. This makes the AA cost attributable instead of
        /// inferring it from a whole-frame timing delta.
        public fileprivate(set) var lastTriggeredPixels: UInt32 = 0
        public fileprivate(set) var totalTriggeredPixels: UInt64 = 0
    }

    public struct DiagnosticImage: Sendable {
        public let rgba8: [UInt8]
        public let width: Int
        public let height: Int
    }

    let gridResolution: Int
    let worldHalfExtent: Float
    let threshold: Float
    let strength: Float

    private let context: GPUContext
    let marchPipeline: MTLComputePipelineState
    let marchDETable: MTLVisibleFunctionTable
    private let distancePipeline: MTLComputePipelineState
    private let distanceDETable: MTLVisibleFunctionTable
    private let convolutionPipeline: MTLComputePipelineState

    private var distanceBuffer: MTLBuffer?
    private var frequencyBuffer: MTLBuffer?
    private let triggerBuffer: MTLBuffer
    private var signature: UInt64?
    private var pendingSignature: UInt64?
    private(set) var needsBuild = true
    private(set) var uniforms = Uniforms(
        originExtent: .zero, gridDim: .zero, threshold: 0, strength: 1)
    public private(set) var metrics = Metrics()

    public init(
        context: GPUContext, gridResolution: Int = 64,
        worldHalfExtent: Float = 4, threshold: Float = 1.25,
        strength: Float = 1
    ) throws {
        self.context = context
        self.gridResolution = max(8, gridResolution)
        self.worldHalfExtent = max(worldHalfExtent, 1e-3)
        self.threshold = max(threshold, 0)
        self.strength = max(strength, 0)
        guard let triggerBuffer = context.device.makeBuffer(
            length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            throw RenderError.allocationFailed("frequency-AA trigger counter")
        }
        triggerBuffer.label = "frequency-AA triggered pixels"
        self.triggerBuffer = triggerBuffer
        self.marchPipeline = try GPUContext.makeLinkedPipeline(
            device: context.device, library: context.library,
            kernelName: "march_offscreen", deFunctions: context.builtinDEFunctions,
            frequencyVolume: true)
        self.marchDETable = try GPUContext.makeDETable(
            marchPipeline, functions: context.builtinDEFunctions,
            label: "frequency-AA march DE table")
        self.distancePipeline = try GPUContext.makeLinkedPipeline(
            device: context.device, library: context.library,
            kernelName: "build_distance_volume",
            deFunctions: context.builtinDEFunctions)
        self.distanceDETable = try GPUContext.makeDETable(
            distancePipeline, functions: context.builtinDEFunctions,
            label: "frequency distance-build DE table")
        guard let convolutionPipeline = context.library.makeFunction(
            name: "build_frequency_volume").flatMap({
                try? context.device.makeComputePipelineState(function: $0)
            }) else {
            throw RenderError.missingFunction("build_frequency_volume")
        }
        self.convolutionPipeline = convolutionPipeline
    }

    @discardableResult
    func prepare(
        uniforms frameUniforms: ThreshFrameUniforms,
        params: [Float], ops: [ThreshWarpOp]
    ) -> Bool {
        let g = gridResolution
        let cell = (2 * worldHalfExtent) / Float(g)
        uniforms = Uniforms(
            originExtent: SIMD4(
                -worldHalfExtent, -worldHalfExtent, -worldHalfExtent, cell),
            gridDim: SIMD4(UInt32(g), UInt32(g), UInt32(g), 0),
            threshold: threshold, strength: strength)
        let key = geometrySignature(
            uniforms: frameUniforms, params: params, ops: ops)
        if signature == key, distanceBuffer != nil, frequencyBuffer != nil {
            pendingSignature = nil
            needsBuild = false
            metrics.hits += 1
            return true
        }
        metrics.misses += 1
        let bytes = g * g * g * MemoryLayout<UInt32>.stride
        if distanceBuffer?.length != bytes {
            distanceBuffer = context.device.makeBuffer(
                length: bytes, options: .storageModeShared)
            frequencyBuffer = context.device.makeBuffer(
                length: bytes, options: .storageModeShared)
            distanceBuffer?.label = "frequency source distance (\(g)³)"
            frequencyBuffer?.label = "3D convolved frequency (\(g)³)"
        }
        pendingSignature = key
        needsBuild = distanceBuffer == nil || frequencyBuffer == nil ? false : true
        return distanceBuffer != nil && frequencyBuffer != nil
    }

    func encodeBuild(
        commandBuffer: MTLCommandBuffer, uniforms frameUniforms: ThreshFrameUniforms,
        paramsBuffer: MTLBuffer, opsBuffer: MTLBuffer
    ) {
        guard let distanceBuffer, let frequencyBuffer else { return }
        let tg = MTLSize(width: 4, height: 4, depth: 4)
        let g = gridResolution
        let groups = MTLSize(
            width: (g + 3) / 4, height: (g + 3) / 4, depth: (g + 3) / 4)

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "build_distance_volume"
            enc.setComputePipelineState(distancePipeline)
            withUnsafeBytes(of: frameUniforms) { raw in
                enc.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_UNIFORMS))
            }
            enc.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
            enc.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
            enc.setVisibleFunctionTable(
                distanceDETable, bufferIndex: GPUContext.deTableBufferIndex)
            withUnsafeBytes(of: uniforms) { raw in
                enc.setBytes(raw.baseAddress!, length: raw.count, index: 11)
            }
            enc.setBuffer(distanceBuffer, offset: 0, index: 12)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "build_frequency_volume"
            enc.setComputePipelineState(convolutionPipeline)
            withUnsafeBytes(of: uniforms) { raw in
                enc.setBytes(raw.baseAddress!, length: raw.count, index: 11)
            }
            enc.setBuffer(distanceBuffer, offset: 0, index: 12)
            enc.setBuffer(frequencyBuffer, offset: 0, index: 13)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        signature = pendingSignature
        pendingSignature = nil
        needsBuild = false
        metrics.builds += 1
        metrics.residentBytes = distanceBuffer.length + frequencyBuffer.length
    }

    func bindMarch(_ encoder: MTLComputeCommandEncoder) {
        guard let frequencyBuffer else { return }
        triggerBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 11)
        }
        encoder.setBuffer(frequencyBuffer, offset: 0, index: 13)
        encoder.setBuffer(triggerBuffer, offset: 0, index: 14)
    }

    /// Must be called after the command buffer that used `bindMarch` has
    /// completed, otherwise CPU-side shared-memory observation is undefined.
    func completeFrame() {
        let triggered = triggerBuffer.contents().load(as: UInt32.self)
        metrics.lastTriggeredPixels = triggered
        metrics.totalTriggeredPixels += UInt64(triggered)
    }

    public func diagnosticImage() -> DiagnosticImage? {
        guard let frequencyBuffer else { return nil }
        let g = gridResolution
        let z = g / 2
        let values = frequencyBuffer.contents().bindMemory(
            to: UInt32.self, capacity: g * g * g)
        var rgba = [UInt8](repeating: 255, count: g * g * 4)
        for y in 0..<g {
            for x in 0..<g {
                let f = Float(bitPattern: values[x + y * g + z * g * g])
                let n = f.isFinite ? min(max(f / max(threshold * 2, 1e-6), 0), 1) : 1
                let r = UInt8(min(255, n * 510))
                let green = UInt8(min(255, max(0, (n - 0.25) * 340)))
                let blue = UInt8(min(255, max(0, (n - 0.65) * 729)))
                let i = (x + (g - 1 - y) * g) * 4
                rgba[i] = r; rgba[i + 1] = green; rgba[i + 2] = blue
            }
        }
        return DiagnosticImage(rgba8: rgba, width: g, height: g)
    }

    private func geometrySignature(
        uniforms: ThreshFrameUniforms, params: [Float], ops: [ThreshWarpOp]
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt32) {
            var v = value
            for _ in 0..<4 {
                hash ^= UInt64(v & 0xff); hash &*= 0x100000001b3; v >>= 8
            }
        }
        mix(uniforms.meta.x); mix(uniforms.meta.y)
        mix(uniforms.meta.z); mix(uniforms.meta.w)
        mix(uniforms.scaleCtx.z.bitPattern); mix(uniforms.scaleCtx.w.bitPattern)
        mix(worldHalfExtent.bitPattern); mix(UInt32(gridResolution))
        let lo = min(Int(uniforms.meta.w), params.count)
        let hi = min(max(Int(uniforms.meta.z), lo), params.count)
        for value in params[lo..<hi] { mix(value.bitPattern) }
        for op in ops {
            withUnsafeBytes(of: op) { raw in
                for byte in raw {
                    hash ^= UInt64(byte); hash &*= 0x100000001b3
                }
            }
        }
        return hash
    }
}
