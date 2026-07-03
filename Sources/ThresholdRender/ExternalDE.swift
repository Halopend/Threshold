// ExternalDE.swift — runtime-compiled, externally-authored distance
// estimators (plan §5.1, §7.2; build order phase 9).
//
// An external DE is MSL embedded in a .threshscene (EmbeddedDE): it defines
//
//   [[visible]] float2 de_main(float3 p, thread const ThreshDEContext& ctx)
//
// compiled at load against the published ABI header, then linked through the
// SAME visible function table mechanism as built-ins — its table index is
// simply builtin.count, and past the table it is indistinguishable
// (Invariant 5). Validation is compile → link → PROBE → accept/reject with
// the compiler diagnostics surfaced; never trust-and-crash (plan §7.2).
//
// Cache: MTLBinaryArchive cannot serialize runtime-compiled libraries (API
// limit, plan §5.6) — programs cache in memory keyed by the source hash, and
// first-load compile cost is accepted.

import Foundation
import CryptoKit
import Metal
import Synchronization
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR

// MARK: - Errors

public enum ExternalDEError: Error, CustomStringConvertible {
    /// `EmbeddedDE.abiVersion` does not match this build's ABI header.
    case abiVersionMismatch(declared: Int, current: Int)
    /// `EmbeddedDE.hash` does not match the source content (tamper check).
    case hashMismatch(declared: String, computed: String)
    /// MSL compilation failed; payload is the compiler diagnostics, surfaced
    /// to the user verbatim (plan §7.2).
    case compileFailed(String)
    /// Compiled, but no `de_main` function was found.
    case missingEntryPoint
    /// Pipeline/link/table construction failed.
    case linkFailed(String)
    /// The probe evaluated the DE and found non-finite or degenerate output.
    case probeFailed(String)

    public var description: String {
        switch self {
        case .abiVersionMismatch(let d, let c):
            return "DE ABI version \(d) does not match this build's ABI \(c)"
        case .hashMismatch(let d, let c):
            return "embedded DE hash \(d) does not match source content (\(c))"
        case .compileFailed(let diag): return "external DE failed to compile:\n\(diag)"
        case .missingEntryPoint:
            return "external DE source defines no visible function named de_main"
        case .linkFailed(let s): return "external DE failed to link: \(s)"
        case .probeFailed(let s): return "external DE failed the probe render: \(s)"
        }
    }
}

// MARK: - ExternalDEProgram

/// A validated, ready-to-dispatch external DE: its descriptor (table index =
/// builtin.count) plus the pipelines/tables that include it. Renderers bind
/// these instead of the context's built-in-only ones.
///
/// AUDIT — `@unchecked Sendable`: all stored properties are `let`; Metal
/// pipeline/table objects are populated before init returns and read-only
/// afterwards (same audit as GPUContext).
public final class ExternalDEProgram: @unchecked Sendable {
    public let descriptor: DEDescriptor
    public let sourceHash: String
    let marchPipeline: MTLComputePipelineState
    let marchDETable: MTLVisibleFunctionTable
    let evalDEPipeline: MTLComputePipelineState
    let evalDETable: MTLVisibleFunctionTable
    /// builtin count + 1 — bounds check for meta.y.
    public let deFunctionCount: Int

    init(descriptor: DEDescriptor, sourceHash: String,
         marchPipeline: MTLComputePipelineState, marchDETable: MTLVisibleFunctionTable,
         evalDEPipeline: MTLComputePipelineState, evalDETable: MTLVisibleFunctionTable,
         deFunctionCount: Int) {
        self.descriptor = descriptor
        self.sourceHash = sourceHash
        self.marchPipeline = marchPipeline
        self.marchDETable = marchDETable
        self.evalDEPipeline = evalDEPipeline
        self.evalDETable = evalDETable
        self.deFunctionCount = deFunctionCount
    }
}

// MARK: - Scene apply with embedded DE

#if os(macOS) || os(iOS)
extension InteractiveSession {
    /// Apply a scene whose embedded DE (if any) is compiled + probed HERE —
    /// off the render thread — before both commands are published together.
    /// Throws (scene not applied at all) when the embedded DE is rejected,
    /// so a bad file can never half-apply.
    public func applyScene(_ envelope: SceneEnvelope, loader: ExternalDELoader) throws {
        let program = try envelope.embeddedDE.map { try loader.load($0) }
        commands.publish(.applyScene(envelope))
        commands.publish(.setExternalDE(program))
    }
}
#endif

// MARK: - ExternalDELoader

/// Compile + validate + cache external DEs. Thread-safe; loads are
/// synchronous and expensive (a Metal source compile) — call off the render
/// thread and hand the resulting program over via a session command.
public final class ExternalDELoader: @unchecked Sendable {
    private let context: GPUContext
    private let cache = Mutex<[String: ExternalDEProgram]>([:])
    /// The evaluator used for probes (its queue is private to the loader).
    private let probeEvaluator: DEEvaluator

    /// Probe sample layout: deterministic shells around the origin — where
    /// scene content lives (unit-ish scale by convention).
    static let probeRadii: [Float] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

    public init(context: GPUContext) throws {
        self.context = context
        self.probeEvaluator = try DEEvaluator(context: context)
    }

    /// The canonical content hash for embedded DE source (hex SHA-256).
    /// Scenes saved by this app write this; foreign scenes must match it.
    public static func sourceHash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Load (or return the cached program for) an embedded DE.
    public func load(_ embedded: EmbeddedDE) throws -> ExternalDEProgram {
        guard embedded.abiVersion == Int(THRESHOLD_ABI_VERSION) else {
            throw ExternalDEError.abiVersionMismatch(
                declared: embedded.abiVersion, current: Int(THRESHOLD_ABI_VERSION))
        }
        let hash = Self.sourceHash(embedded.source)
        guard hash == embedded.hash.lowercased() else {
            throw ExternalDEError.hashMismatch(declared: embedded.hash, computed: hash)
        }
        if let cached = cache.withLock({ $0[hash] }) {
            return cached
        }

        let program = try compileAndProbe(embedded, hash: hash)
        cache.withLock { $0[hash] = program }
        return program
    }

    private func compileAndProbe(
        _ embedded: EmbeddedDE, hash: String
    ) throws -> ExternalDEProgram {
        // --- compile against the published ABI header -----------------------
        // The prelude (stdlib + namespace + header) is part of the published
        // authoring contract: external sources write bare `length`/`float3`
        // like the core does. Same .safe math mode as the core: external
        // content must be as deterministic as built-ins.
        let source = "#include <metal_stdlib>\nusing namespace metal;\n"
            + context.abiHeaderSource + "\n" + embedded.source
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library: MTLLibrary
        do {
            library = try context.device.makeLibrary(source: source, options: options)
        } catch {
            throw ExternalDEError.compileFailed(String(describing: error))
        }
        guard let external = library.makeFunction(name: "de_main") else {
            throw ExternalDEError.missingEntryPoint
        }

        // --- link: built-ins + the external, external LAST ------------------
        let functions = context.builtinDEFunctions + [external]
        let index = context.builtinDEFunctions.count
        let marchPipeline: MTLComputePipelineState
        let marchTable: MTLVisibleFunctionTable
        let evalPipeline: MTLComputePipelineState
        let evalTable: MTLVisibleFunctionTable
        do {
            marchPipeline = try GPUContext.makeLinkedPipeline(
                device: context.device, library: context.library,
                kernelName: "march_offscreen", deFunctions: functions)
            marchTable = try GPUContext.makeDETable(
                marchPipeline, functions: functions,
                label: "external DE march table \(hash.prefix(8))")
            evalPipeline = try GPUContext.makeLinkedPipeline(
                device: context.device, library: context.library,
                kernelName: "eval_de", deFunctions: functions)
            evalTable = try GPUContext.makeDETable(
                evalPipeline, functions: functions,
                label: "external DE eval table \(hash.prefix(8))")
        } catch {
            throw ExternalDEError.linkFailed(String(describing: error))
        }

        let descriptor = DEDescriptor(
            index: UInt32(index),
            key: "external:\(hash.prefix(8))",
            displayName: "Custom",
            mslFunctionName: "de_main",
            equation: "external",
            paramLayout: embedded.params.map {
                DEDescriptor.Param(name: $0.name, default: $0.defaultValue,
                                   range: Swift.min($0.min, $0.max)...Swift.max($0.min, $0.max))
            },
            defaultIterations: 12)

        let program = ExternalDEProgram(
            descriptor: descriptor, sourceHash: hash,
            marchPipeline: marchPipeline, marchDETable: marchTable,
            evalDEPipeline: evalPipeline, evalDETable: evalTable,
            deFunctionCount: functions.count)

        // --- probe (plan §7.2: never trust-and-crash) ------------------------
        try probe(program)
        return program
    }

    /// Evaluate the DE on deterministic shells at declared defaults; reject
    /// non-finite output anywhere, or a DE with no positive distance at all
    /// (a "solid universe" would trap every march ray at the step cap).
    private func probe(_ program: ExternalDEProgram) throws {
        var points: [SIMD3<Float>] = []
        // 26 lattice directions × radii — deterministic, axis- and
        // diagonal-covering (axis-aligned NaNs like atan2(0,0) show up here).
        for x: Float in [-1, 0, 1] {
            for y: Float in [-1, 0, 1] {
                for z: Float in [-1, 0, 1] where !(x == 0 && y == 0 && z == 0) {
                    let dir = simd_normalize(SIMD3(x, y, z))
                    for r in Self.probeRadii {
                        points.append(dir * r)
                    }
                }
            }
        }

        let results = try probeEvaluator.evaluate(
            points: points,
            deIndex: Int(program.descriptor.index),
            deParams: program.descriptor.paramLayout.map(\.default),
            iterations: program.descriptor.defaultIterations,
            program: program)

        var anyPositive = false
        for (i, r) in results.enumerated() {
            guard r.x.isFinite, r.y.isFinite else {
                throw ExternalDEError.probeFailed(
                    "non-finite output \(r) at probe point \(points[i])")
            }
            if r.x > 0 { anyPositive = true }
        }
        guard anyPositive else {
            throw ExternalDEError.probeFailed(
                "no positive distance anywhere on the probe shells — every march ray would hit the step cap")
        }
    }
}
