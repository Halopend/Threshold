// GPUContext.swift — device, runtime-compiled march library, cached pipelines.
//
// The MSL is compiled at RUNTIME from bundled plain-text resources: the
// byte-identical ABI header copy (MSL/ThresholdShaderABI.h) is prepended
// to MSL/RaymarchCore.metal and handed to makeLibrary(source:options:).
// This is deliberately the same path external DEs will use, so a shader that
// compiles for the built-ins compiles for external content too.

import Foundation
import Metal
import ThresholdShaderABI
import ThresholdShaderIR

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
    /// The bundled ABI header source — prepended to the core at compile, and
    /// the published header external DEs compile against (plan §5.1/§7.2).
    let abiHeaderSource: String
    /// Built-in DE `[[visible]]` functions in table order — the base set every
    /// pipeline links; external programs link these + their own function.
    let builtinDEFunctions: [MTLFunction]

    let marchPipeline: MTLComputePipelineState
    /// `march_offscreen` with THRESH_AUX baked true: writes depth + motion
    /// aux textures and jitters ray-gen — the input pass for MetalFX
    /// temporal upscaling (live Mac/iOS path only; the offscreen/golden
    /// path never touches it).
    let marchAuxPipeline: MTLComputePipelineState
    let evalOpsPipeline: MTLComputePipelineState
    let evalDistPipeline: MTLComputePipelineState
    let evalDEPipeline: MTLComputePipelineState

    /// DE table for `march_offscreen`: index 0 = mandelbox, 1 = mandelbulb.
    let marchDETable: MTLVisibleFunctionTable
    /// DE table matched to the aux pipeline (tables are per-pipeline).
    let marchAuxDETable: MTLVisibleFunctionTable
    /// DE table for `eval_de`: index 0 = mandelbox, 1 = mandelbulb.
    let evalDETable: MTLVisibleFunctionTable

    /// Number of built-in DEs in the visible function tables
    /// (index 0 = mandelbox, index 1 = mandelbulb).
    public let deFunctionCount: Int

    /// Perf-experiment override for the shader math mode (see compile section
    /// below). nil = the deliberate default (.safe).
    static var mathModeOverride: MTLMathMode? {
        switch ProcessInfo.processInfo.environment["THRESHOLD_MATH_MODE"] {
        case "fast": return .fast
        case "relaxed": return .relaxed
        case "safe": return .safe
        default: return nil
        }
    }

    /// Perf toggle (env `THRESHOLD_SPEC_ITERATIONS`): bake the resolved DE
    /// iteration count as function_constant(1) on the specialized march variant
    /// so the fold loop unrolls and per-iteration invariants hoist.
    ///
    /// Default OFF, evidence-based: on Apple-Silicon Mac GPUs the isolated
    /// increment over the direct-call specialization measured at ZERO (the
    /// DEs' data-dependent escape `break`s and small trip counts (~8–16) leave
    /// little for the unroller, and these GPUs are not register-starved for the
    /// built-ins). The seam is kept because (a) it is byte-identical and
    /// costless when off, (b) it may still pay on the register-constrained
    /// visionOS/Vision-Pro GPU — measure THERE before promoting — and (c) it is
    /// the mechanism the over-relaxation per-DE omega caps and `maxSteps` bake
    /// reuse. Set to "1" to enable and A/B (image is identical either way).
    public static var bakeIterations: Bool {
        ProcessInfo.processInfo.environment["THRESHOLD_SPEC_ITERATIONS"] == "1"
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.noMetalDevice
        }
        self.device = device

        // --- load resources: ABI header copy + march core source -----------
        guard let headerURL = Bundle.module.url(
            forResource: "ThresholdShaderABI", withExtension: "h",
            subdirectory: "MSL")
        else { throw RenderError.missingResource("MSL/ThresholdShaderABI.h") }
        guard let sourceURL = Bundle.module.url(
            forResource: "RaymarchCore", withExtension: "metal",
            subdirectory: "MSL")
        else { throw RenderError.missingResource("MSL/RaymarchCore.metal") }

        let header = try String(contentsOf: headerURL, encoding: .utf8)
        let core = try String(contentsOf: sourceURL, encoding: .utf8)
        let source = header + "\n" + core
        self.abiHeaderSource = header

        // --- compile --------------------------------------------------------
        // mathMode .safe: no fast-math re-association / FMA contraction
        // surprises — determinism and CPU-equivalence beat a few percent of
        // ALU throughput here. THRESHOLD_MATH_MODE=fast|relaxed is a
        // MEASUREMENT seam only (perf A/B): it changes images, so goldens are
        // only valid under the default.
        let options = MTLCompileOptions()
        options.mathMode = Self.mathModeOverride ?? .safe
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: options)
        } catch {
            throw RenderError.shaderCompileFailed(String(describing: error))
        }
        self.library = library

        // --- built-in DEs as linked visible functions ------------------------
        // Table order IS DERegistry.builtin order (each descriptor's `index`);
        // one declaration site — adding a DE touches the registry + MSL,
        // never this file.
        let deNames = DERegistry.builtin.map(\.mslFunctionName)
        var deFunctions: [MTLFunction] = []
        deFunctions.reserveCapacity(deNames.count)
        for name in deNames {
            guard let f = library.makeFunction(name: name) else {
                throw RenderError.missingFunction(name)
            }
            deFunctions.append(f)
        }
        self.deFunctionCount = deFunctions.count
        self.builtinDEFunctions = deFunctions

        // --- pipelines --------------------------------------------------------
        self.marchPipeline = try Self.makeLinkedPipeline(
            device: device, library: library, kernelName: "march_offscreen",
            deFunctions: deFunctions)
        self.evalOpsPipeline = try Self.makeLinkedPipeline(
            device: device, library: library, kernelName: "eval_ops",
            deFunctions: deFunctions)
        self.evalDistPipeline = try Self.makeLinkedPipeline(
            device: device, library: library, kernelName: "eval_dist",
            deFunctions: deFunctions)
        self.evalDEPipeline = try Self.makeLinkedPipeline(
            device: device, library: library, kernelName: "eval_de",
            deFunctions: deFunctions)
        self.marchAuxPipeline = try Self.makeLinkedPipeline(
            device: device, library: library, kernelName: "march_offscreen",
            deFunctions: deFunctions, auxOutputs: true)

        self.marchDETable = try Self.makeDETable(
            marchPipeline, functions: deFunctions, label: "march_offscreen DE table")
        self.marchAuxDETable = try Self.makeDETable(
            marchAuxPipeline, functions: deFunctions, label: "march aux DE table")
        self.evalDETable = try Self.makeDETable(
            evalDEPipeline, functions: deFunctions, label: "eval_de DE table")
    }

    // MARK: - Pipeline/table construction (shared with ExternalDELoader)

    /// A compute pipeline for `kernelName` with `deFunctions` linked as
    /// visible functions (built-ins, plus an external DE when loading one).
    /// `auxOutputs` bakes the THRESH_AUX function constant true — the
    /// temporal-upscale input variant (depth/motion writes + jittered
    /// ray-gen). False compiles exactly the pre-aux kernel (constant
    /// defaults false; the aux arguments are eliminated).
    /// The function-constant values a specialized march/prepass/fragment
    /// function needs: aux (index 0) + the bakes (1–7) when compiled from a
    /// THRESH_SPEC_DE library, and the cone gate (index 8, aux-style bool) only
    /// when requested. Shared by the compute (makeLinkedPipeline) and raster
    /// (makeSpecializedRaster) paths so the two never drift.
    static func specConstantValues(
        auxOutputs: Bool, spec: MarchSpec?
    ) -> MTLFunctionConstantValues {
        let constants = MTLFunctionConstantValues()
        var aux = auxOutputs
        constants.setConstantValue(&aux, type: .bool, index: 0)
        if let spec {
            func setInt(_ value: Int, _ index: Int) {
                var v = Int32(value)
                constants.setConstantValue(&v, type: .int, index: index)
            }
            setInt(spec.iterations ?? -1, 1)
            setInt(spec.maxSteps ?? -1, 2)
            setInt(spec.hasWarpOps.map { $0 ? 1 : 0 } ?? -1, 3)
            setInt(spec.colorMapMode ?? -1, 4)
            setInt(spec.aoEnabled.map { $0 ? 1 : 0 } ?? -1, 5)
            setInt(spec.hasDistanceOps.map { $0 ? 1 : 0 } ?? -1, 6)
            setInt(spec.statsEnabled.map { $0 ? 1 : 0 } ?? -1, 7)
        }
        if let cone = spec?.coneMarch {
            var v = cone
            constants.setConstantValue(&v, type: .bool, index: 8)
        }
        return constants
    }

    static func makeLinkedPipeline(
        device: MTLDevice, library: MTLLibrary, kernelName: String,
        deFunctions: [MTLFunction], auxOutputs: Bool = false,
        spec: MarchSpec? = nil
    ) throws -> MTLComputePipelineState {
        // The march + cone-prepass kernels reference function constants (THRESH_AUX
        // always; the bakes/cone gate in the specialized library), so they take
        // the specialized-function creation path even for the default variant.
        let constantKernels: Set<String> = [
            "march_offscreen", "march_cone_prepass", "march_cone_prepass_view",
        ]
        let kernel: MTLFunction
        if constantKernels.contains(kernelName) {
            let constants = specConstantValues(auxOutputs: auxOutputs, spec: spec)
            do {
                kernel = try library.makeFunction(
                    name: kernelName, constantValues: constants)
            } catch {
                throw RenderError.missingFunction(
                    "\(kernelName) (aux=\(auxOutputs), spec=\(spec?.keyFragment ?? "-")): \(String(describing: error))")
            }
        } else if let plain = library.makeFunction(name: kernelName) {
            kernel = plain
        } else {
            throw RenderError.missingFunction(kernelName)
        }
        let desc = MTLComputePipelineDescriptor()
        desc.label = auxOutputs ? "\(kernelName) aux" : kernelName
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

    /// A visible function table over `functions` in index order.
    static func makeDETable(
        _ pipeline: MTLComputePipelineState, functions: [MTLFunction], label: String
    ) throws -> MTLVisibleFunctionTable {
        let desc = MTLVisibleFunctionTableDescriptor()
        desc.functionCount = functions.count
        guard let table = pipeline.makeVisibleFunctionTable(descriptor: desc) else {
            throw RenderError.functionTableCreationFailed(label)
        }
        for (index, f) in functions.enumerated() {
            guard let handle = pipeline.functionHandle(function: f) else {
                throw RenderError.functionTableCreationFailed(
                    "\(label): no handle for \(f.name)")
            }
            table.setFunction(handle, index: index)
        }
        return table
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
