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

/// Submission can fail after an external DE has compiled if the render
/// consumer is wedged and its bounded command mailbox is saturated.
public enum SessionSubmissionError: Error, Sendable, CustomStringConvertible {
    case commandMailboxFull

    public var description: String {
        switch self {
        case .commandMailboxFull:
            return "render command mailbox is full; change was not submitted"
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
    /// nil under static dispatch — the external compiles into one translation
    /// unit with the core and the generated switch calls it directly.
    let marchDETable: MTLVisibleFunctionTable?
    let evalDEPipeline: MTLComputePipelineState
    let evalDETable: MTLVisibleFunctionTable?
    /// The external's own `de_main` function, retained from the source
    /// library — the platform-variant builders (raster fragment, per-view
    /// compute) link it into their pipelines. `[[visible]]`-attributed, same
    /// as the built-ins it sits after in the table order (Invariant 5).
    let externalFunction: MTLFunction
    /// builtin count + 1 — bounds check for meta.y.
    public let deFunctionCount: Int

    init(descriptor: DEDescriptor, sourceHash: String,
         marchPipeline: MTLComputePipelineState, marchDETable: MTLVisibleFunctionTable?,
         evalDEPipeline: MTLComputePipelineState, evalDETable: MTLVisibleFunctionTable?,
         externalFunction: MTLFunction, deFunctionCount: Int) {
        self.descriptor = descriptor
        self.sourceHash = sourceHash
        self.marchPipeline = marchPipeline
        self.marchDETable = marchDETable
        self.evalDEPipeline = evalDEPipeline
        self.evalDETable = evalDETable
        self.externalFunction = externalFunction
        self.deFunctionCount = deFunctionCount
    }

    // Platform-variant caches (the extension below builds; these own storage —
    // Swift extensions cannot hold stored properties).
    private enum RasterCell {
        case ready(ExternalRasterVariant)
        case failed(String)
    }
    private enum ViewComputeCell {
        case ready(ExternalViewComputeVariant)
        case failed(String)
    }
    /// Per-key build lifecycle: `cells[key]` nil = never scheduled;
    /// `inFlight` = a build is running (frames drop until it lands);
    /// terminal cells replace the miss.
    private struct RasterCache: Sendable {
        var cells: [String: RasterCell] = [:]
        var inFlight: Set<String> = []
        /// True = this caller must run the build (exactly one).
        mutating func schedule(key: String) -> Bool {
            inFlight.insert(key).inserted
        }
        mutating func clearFlight(key: String) {
            inFlight.remove(key)
        }
    }
    private struct ViewComputeCache: Sendable {
        var cells: [String: ViewComputeCell] = [:]
        var inFlight: Set<String> = []
        mutating func schedule(key: String) -> Bool {
            inFlight.insert(key).inserted
        }
        mutating func clearFlight(key: String) {
            inFlight.remove(key)
        }
    }
    private let rasterVariants = Mutex<RasterCache>(RasterCache())
    private let viewComputeVariants = Mutex<ViewComputeCache>(ViewComputeCache())
    /// Shared off-thread builder for both variant kinds (utility QoS — never
    /// contends with the render/UI threads for anything hot).
    private let variantBuildQueue = DispatchQueue(
        label: "com.polinate.threshold.external-variant-build", qos: .utility)
}

// MARK: - Platform-variant pipelines (raster / view-compute)

/// The fragment (raster) dispatch variant of an external DE — what
/// `ViewPassEncoder` consumes: a render pipeline whose fragment links the
/// built-in set + the external, plus the matching fragment-stage visible
/// function table (index builtin.count = the external).
/// AUDIT — @unchecked: immutable Metal objects, the SpecializedRaster precedent.
struct ExternalRasterVariant: @unchecked Sendable {
    let pipeline: MTLRenderPipelineState
    let deTable: MTLVisibleFunctionTable
}

/// The per-view compute dispatch variant of an external DE — what
/// `ViewComputeEncoder` consumes (plain / aux / aux+seed, per temporal state).
/// AUDIT — @unchecked: immutable Metal objects, same precedent.
struct ExternalViewComputeVariant: @unchecked Sendable {
    let pipeline: MTLComputePipelineState
    let deTable: MTLVisibleFunctionTable?
}

extension ExternalDEProgram {
    /// The raster (fragment) variant for the given target formats. Built
    /// OFF-THREAD on first use and memoized — a fragment PSO with linked
    /// functions can run tens of ms, so it must never land on the render
    /// thread; the frames before it lands DROP (2–3 at the compositor's rate,
    /// invisible during the scene transition that led here). A construction
    /// failure is memoized as a negative cache so a broken DE cannot cause a
    /// compile storm; the caller then keeps its standing drop-frame behavior.
    ///
    /// Static dispatch (the Simulator) has no visible-function machinery —
    /// this returns nil there (terminal), as on the compute paths today.
    func rasterVariant(
        context: GPUContext, colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat, maxViewCount: Int
    ) -> ExternalRasterVariant? {
        let key = "\(colorFormat.rawValue)/\(depthFormat.rawValue)/\(maxViewCount)"
        switch rasterVariants.withLock({ $0.cells[key] }) {
        case .ready(let variant): return variant
        case .failed: return nil
        case nil: break
        }
        // Case `nil` is the only fallthrough: schedule ONE off-thread build.
        guard rasterVariants.withLock({ $0.schedule(key: key) }) else { return nil }
        let program = self
        let args = (context, colorFormat, depthFormat, maxViewCount)
        variantBuildQueue.async {
            do {
                let variant = try program.buildRasterVariant(
                    context: args.0, colorFormat: args.1,
                    depthFormat: args.2, maxViewCount: args.3)
                program.rasterVariants.withLock {
                    $0.cells[key] = .ready(variant); $0.clearFlight(key: key)
                }
            } catch {
                let message = String(describing: error)
                program.rasterVariants.withLock {
                    $0.cells[key] = .failed(message); $0.clearFlight(key: key)
                }
                ThresholdLog.render.error(
                    """
                    external DE \(program.descriptor.key, privacy: .public) has no \
                    raster variant: \(message, privacy: .public); \
                    it will not render on fragment shells
                    """)
            }
        }
        return nil
    }

    /// The per-view compute variant for `march_view_compute`. `aux`/`seed`
    /// select the temporal twins, mirroring ViewComputeEncoder's own
    /// init-built plain/aux/aux+seed trio (built lazily here — the loader is
    /// shell-agnostic and the temporal path only exists on the compute
    /// backend). Same off-thread + negative-cache contract as
    /// `rasterVariant`; nil under static dispatch.
    func viewComputeVariant(
        context: GPUContext, aux: Bool, seed: Bool
    ) -> ExternalViewComputeVariant? {
        let key = aux ? (seed ? "auxSeed" : "aux") : "plain"
        switch viewComputeVariants.withLock({ $0.cells[key] }) {
        case .ready(let variant): return variant
        case .failed: return nil
        case nil: break
        }
        guard viewComputeVariants.withLock({ $0.schedule(key: key) }) else { return nil }
        let program = self
        variantBuildQueue.async {
            do {
                let variant = try program.buildViewComputeVariant(
                    context: context, aux: aux, seed: seed)
                program.viewComputeVariants.withLock {
                    $0.cells[key] = .ready(variant); $0.clearFlight(key: key)
                }
            } catch {
                let message = String(describing: error)
                program.viewComputeVariants.withLock {
                    $0.cells[key] = .failed(message); $0.clearFlight(key: key)
                }
                ThresholdLog.render.error(
                    """
                    external DE \(program.descriptor.key, privacy: .public) has no \
                    view-compute variant [aux=\(aux) seed=\(seed)]: \
                    \(message, privacy: .public); \
                    it will not render on compute shells
                    """)
            }
        }
        return nil
    }

    private func buildRasterVariant(
        context: GPUContext, colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat, maxViewCount: Int
    ) throws -> ExternalRasterVariant {
        guard !context.staticDEDispatch else {
            throw RenderError.functionTableCreationFailed(
                "external raster variant: static dispatch cannot link external DEs")
        }
        let device = context.device
        // Same construction contract as ViewPassEncoder's generic pipeline:
        // fullscreen vertex from the core library, fragment through the
        // constant-values path (empty values eliminate the THRESH_CONE
        // argument), linked fragment functions = built-ins + the external so
        // the table indexes line up with meta.y.
        guard let vertex = context.library.makeFunction(name: "thresh_fullscreen_vertex")
        else { throw RenderError.missingFunction("thresh_fullscreen_vertex") }
        let fragment: MTLFunction
        do {
            fragment = try context.library.makeFunction(
                name: "thresh_march_fragment",
                constantValues: MTLFunctionConstantValues())
        } catch {
            throw RenderError.missingFunction(
                "thresh_march_fragment: \(String(describing: error))")
        }
        let functions = context.builtinDEFunctions + [externalFunction]
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "thresh_march_raster external \(descriptor.key)"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = colorFormat
        desc.depthAttachmentPixelFormat = depthFormat
        desc.inputPrimitiveTopology = .triangle
        if maxViewCount > 1, device.supportsVertexAmplificationCount(maxViewCount) {
            desc.maxVertexAmplificationCount = maxViewCount
        }
        let linked = MTLLinkedFunctions()
        linked.functions = functions
        desc.fragmentLinkedFunctions = linked
        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RenderError.pipelineCreationFailed(
                "external raster: \(String(describing: error))")
        }
        let tableDesc = MTLVisibleFunctionTableDescriptor()
        tableDesc.functionCount = functions.count
        guard let table = pipeline.makeVisibleFunctionTable(
            descriptor: tableDesc, stage: .fragment)
        else {
            throw RenderError.functionTableCreationFailed(
                "external raster DE table \(descriptor.key)")
        }
        for (index, function) in functions.enumerated() {
            guard let handle = pipeline.functionHandle(function: function, stage: .fragment)
            else {
                throw RenderError.functionTableCreationFailed(
                    "external raster DE table \(descriptor.key): no handle for \(function.name)")
            }
            table.setFunction(handle, index: index)
        }
        return ExternalRasterVariant(pipeline: pipeline, deTable: table)
    }

    private func buildViewComputeVariant(
        context: GPUContext, aux: Bool, seed: Bool
    ) throws -> ExternalViewComputeVariant {
        guard !context.staticDEDispatch else {
            throw RenderError.functionTableCreationFailed(
                "external view-compute variant: static dispatch cannot link external DEs")
        }
        let functions = context.builtinDEFunctions + [externalFunction]
        // Cross-library linking — the kernel lives in the core library, the
        // external in its own; the same shape the interactive compute path
        // builds for `march_offscreen`.
        let pipeline = try GPUContext.makeLinkedPipeline(
            device: context.device, library: context.library,
            kernelName: "march_view_compute", deFunctions: functions,
            auxOutputs: aux, seed: seed)
        let table = try GPUContext.makeDETable(
            pipeline, functions: functions,
            label: "external view-compute DE table \(descriptor.key) aux=\(aux) seed=\(seed)")
        return ExternalViewComputeVariant(pipeline: pipeline, deTable: table)
    }
}

// MARK: - Scene apply with embedded DE

#if os(macOS) || os(iOS)
extension InteractiveSession {
    /// Apply a scene whose embedded DE (if any) is compiled + probed HERE —
    /// off the render thread — before one transactional command is published.
    /// Throws (scene not applied at all) when the embedded DE is rejected,
    /// or when the bounded mailbox rejects the command, so a scene can never
    /// half-apply.
    public func applyScene(
        _ envelope: SceneEnvelope, loader: ExternalDELoader,
        transition: SceneTransition? = .default
    ) throws {
        let program = try envelope.embeddedDE.map { try loader.load($0) }
        guard commands.publish(.applyPreparedScene(
            envelope, externalProgram: program, transition: transition))
        else {
            throw SessionSubmissionError.commandMailboxFull
        }
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
        // Empty = no declared hash (migrated legacy formulas): the hash still
        // keys the cache, there is just nothing to tamper-check against.
        guard embedded.hash.isEmpty || hash == embedded.hash.lowercased() else {
            throw ExternalDEError.hashMismatch(declared: embedded.hash, computed: hash)
        }
        // Cache key includes the declared params: the same source loaded with
        // different param declarations (defaults/ranges) needs a distinct
        // descriptor, and descriptors are immutable on the program.
        let cacheKey = hash + "|" + embedded.params
            .map { "\($0.name):\($0.defaultValue):\($0.min):\($0.max)" }
            .joined(separator: ",")
        if let cached = cache.withLock({ $0[cacheKey] }) {
            return cached
        }

        let program = try compileAndProbe(embedded, hash: hash)
        cache.withLock { $0[cacheKey] = program }
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
        // Static dispatch (the Simulator — no visible-function machinery):
        // cross-library linking doesn't exist there, so the external source
        // compiles INTO one translation unit with the core. The generated
        // switch gains `case builtin.count: return de_main(p, ctx);` and the
        // march calls it directly; `[[visible]]` is stripped from the copy
        // (nothing links it — the switch needs a plain callable function).
        let index = context.deFunctionCount
        let marchPipeline: MTLComputePipelineState
        let marchTable: MTLVisibleFunctionTable?
        let evalPipeline: MTLComputePipelineState
        let evalTable: MTLVisibleFunctionTable?
        do {
            if context.staticDEDispatch {
                let sanitized = embedded.source
                    .replacingOccurrences(of: "[[visible]]", with: "")
                let combined = "#include <metal_stdlib>\nusing namespace metal;\n"
                    + GPUContext.staticDispatchPrelude(externalFunctionName: "de_main")
                    + context.abiHeaderSource + "\n"
                    + sanitized + "\n"
                    + context.marchCoreSource
                let combinedOptions = MTLCompileOptions()
                combinedOptions.mathMode = .safe
                let combinedLibrary: MTLLibrary
                do {
                    combinedLibrary = try context.device.makeLibrary(
                        source: combined, options: combinedOptions)
                } catch {
                    throw ExternalDEError.compileFailed(String(describing: error))
                }
                marchPipeline = try GPUContext.makeLinkedPipeline(
                    device: context.device, library: combinedLibrary,
                    kernelName: "march_offscreen", deFunctions: [])
                marchTable = nil
                evalPipeline = try GPUContext.makeLinkedPipeline(
                    device: context.device, library: combinedLibrary,
                    kernelName: "eval_de", deFunctions: [])
                evalTable = nil
            } else {
                let functions = context.builtinDEFunctions + [external]
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
            }
        } catch let error as ExternalDEError {
            throw error
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
            externalFunction: external, deFunctionCount: index + 1)

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
