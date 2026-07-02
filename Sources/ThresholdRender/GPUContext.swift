// GPUContext.swift — device, runtime-compiled march library, cached pipelines.
//
// The MSL is compiled at RUNTIME from bundled plain-text resources: the
// byte-identical ABI header copy (Resources/ThresholdShaderABI.h) is prepended
// to Resources/RaymarchCore.metal and handed to makeLibrary(source:options:).
// This is deliberately the same path external DEs will use, so a shader that
// compiles for the built-ins compiles for external content too.

import Foundation
import Metal
import ThresholdShaderABI

/// Errors surfaced by the render stack. Compiler diagnostics from
/// `makeLibrary` are passed through verbatim (ARCHITECTURE §4).
public enum RenderError: Error, Sendable, CustomStringConvertible {
    case noMetalDevice
    case missingResource(String)
    case shaderCompileFailed(String)
    case missingFunction(String)
    case pipelineCreationFailed(String)
    case functionTableCreationFailed(String)
    case allocationFailed(String)
    case badRequest(String)
    case gpuExecutionFailed(String)

    public var description: String {
        switch self {
        case .noMetalDevice: return "no Metal device available"
        case .missingResource(let s): return "missing bundle resource: \(s)"
        case .shaderCompileFailed(let s): return "shader compile failed: \(s)"
        case .missingFunction(let s): return "missing MSL function: \(s)"
        case .pipelineCreationFailed(let s): return "pipeline creation failed: \(s)"
        case .functionTableCreationFailed(let s): return "function table creation failed: \(s)"
        case .allocationFailed(let s): return "Metal allocation failed: \(s)"
        case .badRequest(let s): return "bad render request: \(s)"
        case .gpuExecutionFailed(let s): return "GPU execution failed: \(s)"
        }
    }
}

/// Owns the Metal device, the runtime-compiled raymarch library, and the
/// cached compute pipelines + DE visible function tables.
///
/// AUDIT — `@unchecked Sendable`: every stored property is `let` and never
/// mutated after `init`. `MTLDevice`, `MTLLibrary`, `MTLFunction`, and
/// `MTLComputePipelineState` are documented thread-safe by Metal;
/// `MTLVisibleFunctionTable` objects are populated inside `init` and are
/// read-only afterwards (bound to encoders, never re-written). This is the
/// honest escape hatch ARCHITECTURE §1 permits: one type, audited here.
public final class GPUContext: @unchecked Sendable {

    /// Binding index of the DE visible function table on pipelines that
    /// dispatch DEs. Private contract with RaymarchCore.metal
    /// (`#define THRESH_BUFFER_DE_TABLE 4`) — NOT part of the ABI header.
    static let deTableBufferIndex = 4

    /// Buffer index of the visible function table on the `eval_de` debug
    /// kernel (its point/param buffers occupy 0...4).
    static let evalDETableBufferIndex = 5

    public let device: MTLDevice
    let library: MTLLibrary

    let marchPipeline: MTLComputePipelineState
    let evalOpsPipeline: MTLComputePipelineState
    let evalDistPipeline: MTLComputePipelineState
    let evalDEPipeline: MTLComputePipelineState

    /// DE table for `march_offscreen`: index 0 = mandelbox, 1 = mandelbulb.
    let marchDETable: MTLVisibleFunctionTable
    /// DE table for `eval_de`: index 0 = mandelbox, 1 = mandelbulb.
    let evalDETable: MTLVisibleFunctionTable

    /// Number of built-in DEs in the visible function tables
    /// (index 0 = mandelbox, index 1 = mandelbulb).
    public let deFunctionCount: Int

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.noMetalDevice
        }
        self.device = device

        // --- load resources: ABI header copy + march core source -----------
        guard let headerURL = Bundle.module.url(
            forResource: "ThresholdShaderABI", withExtension: "h",
            subdirectory: "Resources")
        else { throw RenderError.missingResource("Resources/ThresholdShaderABI.h") }
        guard let sourceURL = Bundle.module.url(
            forResource: "RaymarchCore", withExtension: "metal",
            subdirectory: "Resources")
        else { throw RenderError.missingResource("Resources/RaymarchCore.metal") }

        let header = try String(contentsOf: headerURL, encoding: .utf8)
        let core = try String(contentsOf: sourceURL, encoding: .utf8)
        let source = header + "\n" + core

        // --- compile --------------------------------------------------------
        // mathMode .safe: no fast-math re-association / FMA contraction
        // surprises — determinism and CPU-equivalence beat a few percent of
        // ALU throughput here.
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: options)
        } catch {
            throw RenderError.shaderCompileFailed(String(describing: error))
        }
        self.library = library

        // --- built-in DEs as linked visible functions ------------------------
        // Index order in every table: 0 = mandelbox, 1 = mandelbulb.
        let deNames = ["de_mandelbox", "de_mandelbulb"]
        var deFunctions: [MTLFunction] = []
        deFunctions.reserveCapacity(deNames.count)
        for name in deNames {
            guard let f = library.makeFunction(name: name) else {
                throw RenderError.missingFunction(name)
            }
            deFunctions.append(f)
        }
        self.deFunctionCount = deFunctions.count

        // --- pipelines --------------------------------------------------------
        func makePipeline(_ kernelName: String) throws -> MTLComputePipelineState {
            guard let kernel = library.makeFunction(name: kernelName) else {
                throw RenderError.missingFunction(kernelName)
            }
            let desc = MTLComputePipelineDescriptor()
            desc.label = kernelName
            desc.computeFunction = kernel
            let linked = MTLLinkedFunctions()
            linked.functions = deFunctions
            desc.linkedFunctions = linked
            do {
                return try device.makeComputePipelineState(
                    descriptor: desc, options: [], reflection: nil)
            } catch {
                throw RenderError.pipelineCreationFailed(
                    "\(kernelName): \(String(describing: error))")
            }
        }

        func makeDETable(_ pipeline: MTLComputePipelineState,
                         label: String) throws -> MTLVisibleFunctionTable {
            let desc = MTLVisibleFunctionTableDescriptor()
            desc.functionCount = deFunctions.count
            guard let table = pipeline.makeVisibleFunctionTable(descriptor: desc) else {
                throw RenderError.functionTableCreationFailed(label)
            }
            for (index, f) in deFunctions.enumerated() {
                guard let handle = pipeline.functionHandle(function: f) else {
                    throw RenderError.functionTableCreationFailed(
                        "\(label): no handle for \(f.name)")
                }
                table.setFunction(handle, index: index)
            }
            return table
        }

        self.marchPipeline = try makePipeline("march_offscreen")
        self.evalOpsPipeline = try makePipeline("eval_ops")
        self.evalDistPipeline = try makePipeline("eval_dist")
        self.evalDEPipeline = try makePipeline("eval_de")

        self.marchDETable = try makeDETable(marchPipeline, label: "march_offscreen DE table")
        self.evalDETable = try makeDETable(evalDEPipeline, label: "eval_de DE table")
    }
}

// MARK: - Shared encoding helpers (module-internal)

extension GPUContext {
    /// Ops buffer for a stack. An empty stack binds a 1-element zeroed dummy
    /// (kind = None); the op count crossing to the GPU is carried separately
    /// (uniforms.meta.x / the opCount constant) and stays 0.
    func makeOpsBuffer(_ ops: [ThreshWarpOp]) throws -> MTLBuffer {
        var storage = ops
        if storage.isEmpty { storage = [ThreshWarpOp()] }
        let length = storage.count * MemoryLayout<ThreshWarpOp>.stride
        let buffer = storage.withUnsafeBytes { raw -> MTLBuffer? in
            device.makeBuffer(bytes: raw.baseAddress!, length: length,
                              options: .storageModeShared)
        }
        guard let buffer else { throw RenderError.allocationFailed("ops buffer") }
        return buffer
    }

    func makeFloatBuffer(_ values: [Float], label: String) throws -> MTLBuffer {
        guard !values.isEmpty else { throw RenderError.badRequest("\(label) is empty") }
        let buffer = values.withUnsafeBytes { raw -> MTLBuffer? in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count,
                              options: .storageModeShared)
        }
        guard let buffer else { throw RenderError.allocationFailed(label) }
        return buffer
    }
}
