// Evaluators.swift — Swift-array wrappers over the debug kernels.
//
// These exist for the CPU↔GPU contract check: the sampled-equivalence tests
// run the MSL interpreter / built-in DEs on arrays of points and compare
// against the CPU reference in ThresholdShaderIR.
//
// Debug-kernel buffer layout (private contract with RaymarchCore.metal):
//   eval_ops:  0 in float4*, 1 out float4*, 2 ops, 3 opCount, 4 pointCount
//   eval_dist: 0 in float4* (w = d), 1 out float*, 2 ops, 3 opCount, 4 pointCount
//   eval_de:   0 in float4*, 1 out float2*, 2 params, 3 uniforms,
//              4 pointCount, 5 DE visible function table

import Foundation
import Metal
import simd
import ThresholdShaderABI

/// AUDIT — `@unchecked Sendable`: all-`let` storage; GPUContext is audited
/// Sendable and MTLCommandQueue is documented thread-safe by Metal.
public final class OpsEvaluator: @unchecked Sendable {
    private let context: GPUContext
    private let queue: MTLCommandQueue

    public init(context: GPUContext) throws {
        guard let queue = context.device.makeCommandQueue() else {
            throw RenderError.allocationFailed("command queue")
        }
        self.context = context
        self.queue = queue
    }

    /// GPU `applyPointOps` over an array of points against one op stack.
    /// Returns the transformed point and the accumulated dScale per input.
    public func applyPointOps(points: [SIMD3<Float>],
                              ops: [ThreshWarpOp]) throws -> [(p: SIMD3<Float>, dScale: Float)] {
        guard !points.isEmpty else { return [] }
        let input = points.map { SIMD4<Float>($0, 0) }
        let output: [SIMD4<Float>] = try runOpsKernel(
            pipeline: context.evalOpsPipeline, input: input, ops: ops)
        return output.map { (SIMD3($0.x, $0.y, $0.z), $0.w) }
    }

    /// GPU `applyDistanceOps` over paired (world point, input distance) arrays
    /// against one op stack.
    public func applyDistanceOps(points: [SIMD3<Float>],
                                 distances: [Float],
                                 ops: [ThreshWarpOp]) throws -> [Float] {
        guard points.count == distances.count else {
            throw RenderError.badRequest("points/distances count mismatch")
        }
        guard !points.isEmpty else { return [] }
        let input = zip(points, distances).map { SIMD4<Float>($0, $1) }
        let output: [Float] = try runOpsKernel(
            pipeline: context.evalDistPipeline, input: input, ops: ops)
        return output
    }

    /// GPU in-stack Bounding fold (§66): captures in-stack bounds during the
    /// point walk (modelScale = 1, dScale seeded 1) and folds them into each
    /// base distance. Mirrors `ReferenceOps.mapBounds`.
    public func applyBounds(points: [SIMD3<Float>],
                            baseDistances: [Float],
                            ops: [ThreshWarpOp]) throws -> [Float] {
        guard points.count == baseDistances.count else {
            throw RenderError.badRequest("points/baseDistances count mismatch")
        }
        guard !points.isEmpty else { return [] }
        let input = zip(points, baseDistances).map { SIMD4<Float>($0, $1) }
        let output: [Float] = try runOpsKernel(
            pipeline: context.evalBoundsPipeline, input: input, ops: ops)
        return output
    }

    private func runOpsKernel<Out>(pipeline: MTLComputePipelineState,
                                   input: [SIMD4<Float>],
                                   ops: [ThreshWarpOp]) throws -> [Out] {
        let device = context.device
        let count = input.count
        let inBuffer = input.withUnsafeBytes { raw -> MTLBuffer? in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count,
                              options: .storageModeShared)
        }
        guard let inBuffer else { throw RenderError.allocationFailed("input points") }
        guard let outBuffer = device.makeBuffer(
            length: max(count * MemoryLayout<Out>.stride, 16),
            options: .storageModeShared) else {
            throw RenderError.allocationFailed("output buffer")
        }
        let opsBuffer = try context.makeOpsBuffer(ops)

        var opCount = UInt32(ops.count)
        var pointCount = UInt32(count)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.allocationFailed("command buffer/encoder")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inBuffer, offset: 0, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        encoder.setBuffer(opsBuffer, offset: 0, index: 2)
        encoder.setBytes(&opCount, length: MemoryLayout<UInt32>.size, index: 3)
        encoder.setBytes(&pointCount, length: MemoryLayout<UInt32>.size, index: 4)
        dispatch1D(encoder, count: count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RenderError.gpuExecutionFailed(String(describing: error))
        }

        return readArray(outBuffer, count: count)
    }
}

/// AUDIT — `@unchecked Sendable`: same audit as OpsEvaluator (all-`let`
/// storage over thread-safe Metal objects).
public final class DEEvaluator: @unchecked Sendable {
    private let context: GPUContext
    private let queue: MTLCommandQueue

    public init(context: GPUContext) throws {
        guard let queue = context.device.makeCommandQueue() else {
            throw RenderError.allocationFailed("command queue")
        }
        self.context = context
        self.queue = queue
    }

    /// Evaluates a built-in DE (0 = mandelbox, 1 = mandelbulb) at each point.
    /// `deParams` are the DE's DECLARED params; iterations is appended as the
    /// slice's last entry per the encoder convention.
    /// Returns (.x distance estimate, .y min |z| orbit trap) per point.
    /// Evaluates a DE (built-in table index, or an external program's index —
    /// pass `program` to bind its extended pipeline/table) at each point.
    public func evaluate(points: [SIMD3<Float>],
                         deIndex: Int,
                         deParams: [Float],
                         iterations: Int,
                         time: Float = 0,
                         lodScale: Float = 1,
                         program: ExternalDEProgram? = nil) throws -> [SIMD2<Float>] {
        guard !points.isEmpty else { return [] }
        let functionCount = program?.deFunctionCount ?? context.deFunctionCount
        guard deIndex >= 0, deIndex < functionCount else {
            throw RenderError.badRequest("deIndex \(deIndex) out of range")
        }
        var engine = EngineParams()
        engine.iterations = Float(iterations)
        let (table, offset) = ParamTableLayout.build(engine: engine, deParams: deParams)

        var uniforms = ThreshFrameUniforms()
        uniforms.scaleCtx = SIMD4(time, 0, 1, lodScale)
        uniforms.meta = SIMD4<UInt32>(0, UInt32(deIndex), UInt32(table.count),
                                      UInt32(offset))

        let device = context.device
        let count = points.count
        let input = points.map { SIMD4<Float>($0, 0) }
        let inBuffer = input.withUnsafeBytes { raw -> MTLBuffer? in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count,
                              options: .storageModeShared)
        }
        guard let inBuffer else { throw RenderError.allocationFailed("input points") }
        guard let outBuffer = device.makeBuffer(
            length: count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared) else {
            throw RenderError.allocationFailed("output buffer")
        }
        let paramsBuffer = try context.makeFloatBuffer(table, label: "param table")
        var pointCount = UInt32(count)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.allocationFailed("command buffer/encoder")
        }
        encoder.setComputePipelineState(program?.evalDEPipeline ?? context.evalDEPipeline)
        encoder.setBuffer(inBuffer, offset: 0, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 2)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 3)
        }
        encoder.setBytes(&pointCount, length: MemoryLayout<UInt32>.size, index: 4)
        encoder.setVisibleFunctionTable(program?.evalDETable ?? context.evalDETable,
                                        bufferIndex: GPUContext.evalDETableBufferIndex)
        dispatch1D(encoder, count: count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RenderError.gpuExecutionFailed(String(describing: error))
        }

        return readArray(outBuffer, count: count)
    }
}

// MARK: - Small shared helpers

private func dispatch1D(_ encoder: MTLComputeCommandEncoder, count: Int) {
    let width = 64
    let groups = MTLSize(width: (count + width - 1) / width, height: 1, depth: 1)
    encoder.dispatchThreadgroups(groups,
                                 threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
}

private func readArray<T>(_ buffer: MTLBuffer, count: Int) -> [T] {
    let pointer = buffer.contents().bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: pointer, count: count))
}
