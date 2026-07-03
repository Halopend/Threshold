// Specialization.swift — the pipeline specialization cache (perf: shader
// caching keyed by structural state).
//
// The generic march pipeline dispatches every DE evaluation through a
// visible function table — an INDIRECT call per march step (millions per
// frame) that blocks inlining across the DE. Because the MSL compiles from
// source at runtime anyway (GPUContext), a variant with
// `#define THRESH_SPEC_DE de_<name>` calls the built-in DIRECTLY and the
// compiler inlines it through mapScene/march.
//
// On top of that direct call, the variant bakes compile-time function
// constants (currently the DE iteration count, function_constant(1)) so the
// fold loop UNROLLS. The expensive part is the front-end MSL compile of the
// specialized SOURCE (~100–400 ms); that library is cached PER DE and reused
// across baked-constant variants, so a new iteration count is only a cheap
// back-end pipeline specialization, not a source recompile.
//
// Contract:
// - The generic pipeline is the ALWAYS-CORRECT fallback; a specialization is
//   a pure performance overlay producing the identical image
//   (SpecializationTests assert equality on the GPU).
// - Compiles happen OFF the render thread; `lookup` never blocks. Until the
//   variant lands, frames render generic (same image, slower) — the swap is
//   invisible.
// - Built-ins only: an external DE's own pipeline already exists per program
//   and its function is not part of the core source.

import Foundation
import Metal
import Synchronization
import ThresholdShaderABI
import ThresholdShaderIR

/// A specialized march pipeline + its (pipeline-matched) DE table. The table
/// is still bound — Metal requires the argument — but never dispatched
/// through in the specialized variant.
public struct SpecializedMarch: @unchecked Sendable {
    // AUDIT — @unchecked: all properties are immutable Metal objects,
    // documented thread-safe (same precedent as GPUContext).
    public let pipeline: MTLComputePipelineState
    public let deTable: MTLVisibleFunctionTable
    /// Coarse tile prepass pipeline — present iff the variant baked
    /// `coneMarch: true`. The encoder dispatches it (one thread per 8×8
    /// tile) before the march and binds its output at texture 3.
    public let conePrepass: MTLComputePipelineState?
}

/// A specialized PER-VIEW COMPUTE march (march_view_compute) + its DE table,
/// plus the optional per-view cone prepass — the compute-backend counterpart
/// of SpecializedRaster (ADR-001 compute phase 2, perf block 13).
public struct SpecializedViewCompute: @unchecked Sendable {
    // AUDIT — @unchecked: immutable Metal objects, documented thread-safe.
    public let pipeline: MTLComputePipelineState
    public let deTable: MTLVisibleFunctionTable
    public let conePrepass: MTLComputePipelineState?
    public let conePrepassDETable: MTLVisibleFunctionTable?
}

/// A specialized RASTER (stereo fragment) march pipeline + its fragment-stage
/// DE table, plus the optional per-view cone prepass (a compute pipeline + its
/// own compute-stage DE table). The visionOS Compositor counterpart of
/// SpecializedMarch — same perf overlay, render-pipeline shaped.
public struct SpecializedRaster: @unchecked Sendable {
    // AUDIT — @unchecked: immutable Metal objects, documented thread-safe.
    public let pipeline: MTLRenderPipelineState
    public let deTable: MTLVisibleFunctionTable
    /// Present iff the variant baked `coneMarch: true`: the coarse per-view
    /// tile prepass dispatched before the render pass (writes a depth array
    /// the fragment reads at texture 3).
    public let conePrepass: MTLComputePipelineState?
    /// Compute-stage DE table matched to `conePrepass` (bound but unused — the
    /// specialized prepass inlines the DE; Metal still requires the argument).
    public let conePrepassDETable: MTLVisibleFunctionTable?
}

// MARK: - MarchSpec

/// The compile-time constants baked into a specialized march variant
/// (function_constant indices 1–5; see RaymarchCore.metal's registry). Each
/// `nil` field leaves that constant at its -1 sentinel — "use the runtime
/// value" — so the variant stays BIT-IDENTICAL to generic; a set field bakes
/// the value so the compiler can specialize (unroll the fold loop, DCE the
/// warp interpreter, drop the color-mode switch, skip AO). The cache keys
/// variants by this whole struct, so each distinct combination is one cheap
/// pipeline specialization off the shared per-DE library.
public struct MarchSpec: Sendable, Hashable {
    /// DE fold-loop bound (function_constant 1).
    public var iterations: Int?
    /// March step cap (function_constant 2).
    public var maxSteps: Int?
    /// Warp stack present (function_constant 3): false → DCE the interpreter.
    public var hasWarpOps: Bool?
    /// Color mapping mode (function_constant 4).
    public var colorMapMode: Int?
    /// AO enabled (function_constant 5): false → skip the 5-tap AO.
    public var aoEnabled: Bool?
    /// Distance ops (kind ≥ 64) present (function_constant 6): false → DCE
    /// the applyDistanceOps loop even when point ops keep the stack non-empty.
    public var hasDistanceOps: Bool?
    /// Step-count telemetry (function_constant 7): false → drop the per-pixel
    /// stats atomic (totalSteps reads back 0). Benchmark variants bake false.
    public var statsEnabled: Bool?
    /// Cone-prepass stop margin (function_constant 9): the prepass stops when
    /// tile clearance falls to `coneMargin × epsBase × t`. Higher = less
    /// silhouette shimmer, slightly slower. nil → the shader's 3× default.
    /// Only meaningful with `coneMarch` set. A small discrete set (each a
    /// cached variant) — the "Cone Stability" UI lever.
    public var coneMargin: Int?
    /// Tile cone-march prepass (function_constant 8): true → a separate
    /// coarse dispatch (march_cone_prepass, one thread per 8×8 tile) writes
    /// each tile's safe start depth to an r32float texture the march kernel
    /// reads at texture 3. ENCODER CONTRACT: whoever renders a cone-baked
    /// pipeline must dispatch `SpecializedMarch.conePrepass` first and bind
    /// the texture (OffscreenRenderer does; the live session never bakes
    /// this today). Changes marched output slightly, so the generic/golden
    /// library never declares it; the CLI --specialize perf path defaults it
    /// ON (fps-first policy — docs/perf-notes.md block 9).
    public var coneMarch: Bool?

    public init(iterations: Int? = nil, maxSteps: Int? = nil,
                hasWarpOps: Bool? = nil, colorMapMode: Int? = nil,
                aoEnabled: Bool? = nil, hasDistanceOps: Bool? = nil,
                statsEnabled: Bool? = nil, coneMarch: Bool? = nil,
                coneMargin: Int? = nil) {
        self.iterations = iterations
        self.maxSteps = maxSteps
        self.hasWarpOps = hasWarpOps
        self.colorMapMode = colorMapMode
        self.aoEnabled = aoEnabled
        self.hasDistanceOps = hasDistanceOps
        self.statsEnabled = statsEnabled
        self.coneMarch = coneMarch
        self.coneMargin = coneMargin
    }

    /// Translate live tuning + the resolved param table into the constants to
    /// bake. Each is nil unless the matching toggle is on, and every value IS
    /// what the shader would read at runtime — so the bakes render the identical
    /// image; only `coneMarch` (a start-depth prepass) shifts float start
    /// points. Shared by the Mac compute encoder and the visionOS raster
    /// encoder. Callers guarantee `params.count >= THRESH_SLOT_ENGINE_COUNT`.
    public static func from(
        tuning: RenderTuning, params: [Float], opCount: UInt32
    ) -> MarchSpec {
        MarchSpec(
            iterations: tuning.bakeIterations
                ? Int(params[Int(THRESH_SLOT_ITERATIONS)]) : nil,
            maxSteps: tuning.bakeMaxSteps
                ? Int(params[Int(THRESH_SLOT_MAX_STEPS)]) : nil,
            hasWarpOps: tuning.gateWarpOps ? (opCount > 0) : nil,
            colorMapMode: tuning.bakeColorMapMode
                ? Int(params[Int(THRESH_SLOT_MAP_MODE)]) : nil,
            aoEnabled: tuning.gateAO
                ? (params[Int(THRESH_SLOT_AO_STRENGTH)] > 0) : nil,
            coneMarch: tuning.conePrepass ? true : nil,
            coneMargin: tuning.conePrepass ? tuning.coneStability.margin : nil)
    }

    /// Nothing baked — the variant is just the direct-call inline.
    public var isEmpty: Bool {
        iterations == nil && maxSteps == nil && hasWarpOps == nil
            && colorMapMode == nil && aoEnabled == nil && hasDistanceOps == nil
            && statsEnabled == nil && coneMarch == nil && coneMargin == nil
    }

    /// Stable cache-key fragment.
    var keyFragment: String {
        func i(_ v: Int?) -> String { v.map(String.init) ?? "-" }
        func b(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "-" }
        return "i\(i(iterations))s\(i(maxSteps))o\(b(hasWarpOps))c\(i(colorMapMode))a\(b(aoEnabled))d\(b(hasDistanceOps))t\(b(statsEnabled))k\(b(coneMarch))m\(i(coneMargin))"
    }

    /// Human-readable summary of what's baked (for the diagnostics readout).
    public var summary: String {
        var parts: [String] = []
        if let iterations { parts.append("iters=\(iterations)") }
        if let maxSteps { parts.append("steps=\(maxSteps)") }
        if let hasWarpOps { parts.append(hasWarpOps ? "ops" : "no-ops") }
        if let colorMapMode { parts.append("map=\(colorMapMode)") }
        if let aoEnabled { parts.append(aoEnabled ? "ao" : "no-ao") }
        if let hasDistanceOps { parts.append(hasDistanceOps ? "dist-ops" : "no-dist-ops") }
        if let statsEnabled { parts.append(statsEnabled ? "stats" : "no-stats") }
        if let coneMarch { parts.append(coneMarch ? "cone" : "no-cone") }
        if let coneMargin { parts.append("cone-margin=\(coneMargin)") }
        return parts.joined(separator: ", ")
    }
}

extension GPUContext {
    /// Compile the specialized march SOURCE library for a built-in DE — the
    /// expensive front-end compile (~100–400 ms). Reused across every
    /// baked-constant variant of the same DE, so call it ONCE per DE and keep
    /// the result. The specialized source `#define`s THRESH_SPEC_DE so the DE
    /// is called directly and inlined (and, unlike the generic library,
    /// declares the iteration function constant).
    func compileSpecializedLibrary(
        deFunctionName: String, mathMode: MTLMathMode? = nil
    ) throws -> MTLLibrary {
        guard DERegistry.builtin.contains(where: { $0.mslFunctionName == deFunctionName })
        else { throw RenderError.missingFunction("not a built-in DE: \(deFunctionName)") }

        guard let coreURL = Bundle.module.url(
            forResource: "RaymarchCore", withExtension: "metal", subdirectory: "MSL")
        else { throw RenderError.missingResource("MSL/RaymarchCore.metal") }
        let core = try String(contentsOf: coreURL, encoding: .utf8)
        let source = "#define THRESH_SPEC_DE \(deFunctionName)\n"
            + abiHeaderSource + "\n" + core

        let options = MTLCompileOptions()
        // Specialized variants are the PERF pipeline: default to .fast
        // (adds -ffinite-math-only over .relaxed — the march's non-finite
        // sentinel guard is a bit-pattern test precisely so it survives
        // this). The generic pipeline stays .safe and remains the golden/
        // CPU-equivalence reference; THRESHOLD_MATH_MODE overrides both.
        options.mathMode = mathMode ?? GPUContext.mathModeOverride ?? .fast
        do {
            return try device.makeLibrary(source: source, options: options)
        } catch {
            throw RenderError.shaderCompileFailed(
                "specialized(\(deFunctionName)): \(String(describing: error))")
        }
    }

    /// Build a march variant pipeline from an ALREADY-COMPILED specialized
    /// library, baking the aux + iteration function constants. Cheaper than a
    /// source recompile — it reuses `library`, running only the back-end
    /// pipeline specialization (which is where the loop unrolling happens).
    ///
    /// An empty `spec` bakes every constant to the -1 sentinel (the shader
    /// reads its runtime values — identical image, no specialization); set
    /// fields bake their value so the compiler unrolls / DCEs / drops branches.
    /// The constants are ALWAYS provided so they are never referenced-but-
    /// undefined on the specialized library that declares them.
    func makeSpecializedMarch(
        from library: MTLLibrary, deFunctionName: String,
        spec: MarchSpec = MarchSpec(), auxOutputs: Bool = false
    ) throws -> SpecializedMarch {
        let pipeline = try Self.makeLinkedPipeline(
            device: device, library: library, kernelName: "march_offscreen",
            deFunctions: builtinDEFunctions, auxOutputs: auxOutputs, spec: spec)
        let table = try Self.makeDETable(
            pipeline, functions: builtinDEFunctions,
            label: "specialized(\(deFunctionName)) DE table")
        // Cone variants also carry the coarse tile-prepass pipeline (same
        // library, same baked constants — mapScene must fold identically).
        var prepass: MTLComputePipelineState? = nil
        if spec.coneMarch == true {
            prepass = try Self.makeLinkedPipeline(
                device: device, library: library,
                kernelName: "march_cone_prepass",
                deFunctions: builtinDEFunctions, spec: spec)
        }
        return SpecializedMarch(pipeline: pipeline, deTable: table,
                                conePrepass: prepass)
    }

    /// One-shot compile + build (the CLI batch tool and tests): compiles the
    /// specialized source library and builds a single variant pipeline.
    /// EXPENSIVE (a full library compile) — call off the render thread; the
    /// live session goes through SpecializationCache, which reuses the library.
    public func makeSpecializedMarch(
        deFunctionName: String, spec: MarchSpec = MarchSpec(),
        auxOutputs: Bool = false, mathMode: MTLMathMode? = nil
    ) throws -> SpecializedMarch {
        let library = try compileSpecializedLibrary(
            deFunctionName: deFunctionName, mathMode: mathMode)
        return try makeSpecializedMarch(
            from: library, deFunctionName: deFunctionName,
            spec: spec, auxOutputs: auxOutputs)
    }

    /// Build the specialized STEREO RASTER pipeline (thresh_march_fragment,
    /// direct-call inlined DE) for the given target formats, plus the per-view
    /// cone prepass when `spec.coneMarch` is set. `maxViewCount > 1` enables
    /// vertex amplification (2 on device, 1 for the Mac parity test).
    func makeSpecializedRaster(
        from library: MTLLibrary, deFunctionName: String, spec: MarchSpec,
        colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, maxViewCount: Int
    ) throws -> SpecializedRaster {
        let constants = Self.specConstantValues(auxOutputs: false, spec: spec)
        // The vertex shader references no function constants.
        guard let vertex = library.makeFunction(name: "thresh_fullscreen_vertex")
        else { throw RenderError.missingFunction("thresh_fullscreen_vertex") }
        let fragment: MTLFunction
        do {
            fragment = try library.makeFunction(
                name: "thresh_march_fragment", constantValues: constants)
        } catch {
            throw RenderError.missingFunction(
                "thresh_march_fragment (spec=\(spec.keyFragment)): \(String(describing: error))")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "thresh_march_raster specialized[\(spec.summary)]"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = colorFormat
        desc.depthAttachmentPixelFormat = depthFormat
        desc.inputPrimitiveTopology = .triangle
        if maxViewCount > 1 { desc.maxVertexAmplificationCount = maxViewCount }
        let linked = MTLLinkedFunctions()
        linked.functions = builtinDEFunctions
        desc.fragmentLinkedFunctions = linked

        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RenderError.pipelineCreationFailed(
                "specialized raster(\(deFunctionName)): \(String(describing: error))")
        }

        let table = try Self.makeFragmentDETable(
            pipeline, functions: builtinDEFunctions,
            label: "specialized raster(\(deFunctionName)) DE table")

        var prepass: MTLComputePipelineState? = nil
        var prepassTable: MTLVisibleFunctionTable? = nil
        if spec.coneMarch == true {
            let p = try Self.makeLinkedPipeline(
                device: device, library: library,
                kernelName: "march_cone_prepass_view",
                deFunctions: builtinDEFunctions, spec: spec)
            prepass = p
            prepassTable = try Self.makeDETable(
                p, functions: builtinDEFunctions,
                label: "specialized raster(\(deFunctionName)) prepass DE table")
        }
        return SpecializedRaster(
            pipeline: pipeline, deTable: table,
            conePrepass: prepass, conePrepassDETable: prepassTable)
    }

    /// Build the specialized PER-VIEW COMPUTE march (march_view_compute) for
    /// the compute backend, plus the per-view cone prepass when
    /// `spec.coneMarch` is set. Format-independent (the encoder owns the
    /// intermediate textures), unlike the raster builder.
    func makeSpecializedViewCompute(
        from library: MTLLibrary, deFunctionName: String, spec: MarchSpec
    ) throws -> SpecializedViewCompute {
        let pipeline = try Self.makeLinkedPipeline(
            device: device, library: library, kernelName: "march_view_compute",
            deFunctions: builtinDEFunctions, spec: spec)
        let table = try Self.makeDETable(
            pipeline, functions: builtinDEFunctions,
            label: "specialized view-compute(\(deFunctionName)) DE table")
        var prepass: MTLComputePipelineState? = nil
        var prepassTable: MTLVisibleFunctionTable? = nil
        if spec.coneMarch == true {
            let p = try Self.makeLinkedPipeline(
                device: device, library: library,
                kernelName: "march_cone_prepass_view",
                deFunctions: builtinDEFunctions, spec: spec)
            prepass = p
            prepassTable = try Self.makeDETable(
                p, functions: builtinDEFunctions,
                label: "specialized view-compute(\(deFunctionName)) prepass DE table")
        }
        return SpecializedViewCompute(
            pipeline: pipeline, deTable: table,
            conePrepass: prepass, conePrepassDETable: prepassTable)
    }

    /// Fragment-stage visible function table (tables are stage-specific — the
    /// compute-stage `makeDETable` can't serve a render pipeline).
    static func makeFragmentDETable(
        _ pipeline: MTLRenderPipelineState, functions: [MTLFunction], label: String
    ) throws -> MTLVisibleFunctionTable {
        let desc = MTLVisibleFunctionTableDescriptor()
        desc.functionCount = functions.count
        guard let table = pipeline.makeVisibleFunctionTable(
            descriptor: desc, stage: .fragment)
        else { throw RenderError.functionTableCreationFailed(label) }
        for (index, f) in functions.enumerated() {
            guard let handle = pipeline.functionHandle(function: f, stage: .fragment)
            else {
                throw RenderError.functionTableCreationFailed(
                    "\(label): no handle for \(f.name)")
            }
            table.setFunction(handle, index: index)
        }
        return table
    }
}

/// Non-blocking cache: the render thread calls `lookup` each frame; a miss
/// kicks off ONE background compile and keeps returning nil until it lands.
/// Compiler-checked Sendable (a Mutex over Sendable state).
///
/// Two-level cache: the specialized SOURCE library is compiled once per DE
/// (`libraries`), then variant pipelines keyed by (DE, iterations, aux) are
/// built from it (`ready`). So changing only the iteration count re-runs the
/// cheap back-end specialization, never the front-end source compile.
public final class SpecializationCache: Sendable {
    private struct State {
        var libraries: [String: MTLLibrary] = [:]  // per DE function name
        var ready: [String: SpecializedMarch] = [:]  // per (DE, iters, aux)
        var inFlight: Set<String> = []               // variant keys
    }

    private let context: GPUContext
    private let state = Mutex<State>(State())

    public init(context: GPUContext) {
        self.context = context
    }

    private static func variantKey(
        _ de: String, _ spec: MarchSpec, _ aux: Bool
    ) -> String {
        "\(de)#\(spec.keyFragment)#\(aux ? "aux" : "base")"
    }

    /// The specialized pipeline for a built-in DE, if compiled. A miss
    /// schedules the compile (once per variant) and returns nil — render
    /// generic. `spec` bakes the function-constant knobs (iterations, max
    /// steps, has-ops, color-map mode, AO) so the compiler specializes; an
    /// empty spec is the plain direct-call inline. `auxOutputs` selects the
    /// temporal-upscale input variant (cached separately — the live path needs
    /// both while the scale crosses 1).
    public func lookup(
        deFunctionName: String, spec: MarchSpec = MarchSpec(), auxOutputs: Bool = false
    ) -> SpecializedMarch? {
        let key = Self.variantKey(deFunctionName, spec, auxOutputs)
        if let hit = state.withLock({ $0.ready[key] }) { return hit }

        let shouldCompile: Bool = state.withLock { s in
            if s.ready[key] != nil { return false }
            return s.inFlight.insert(key).inserted
        }

        if shouldCompile {
            let context = context
            Task.detached(priority: .utility) { [self] in
                // Resolve the specialized SOURCE library (compile once per DE;
                // a rare concurrent double-compile across two variant lookups
                // is merely wasteful — the OS Metal cache dedups — and never
                // incorrect, so no separate in-flight tracking).
                let library: MTLLibrary? = resolveLibrary(deFunctionName)
                let compiled = library.flatMap {
                    try? context.makeSpecializedMarch(
                        from: $0, deFunctionName: deFunctionName,
                        spec: spec, auxOutputs: auxOutputs)
                }
                state.withLock { s in
                    s.inFlight.remove(key)
                    // A failed compile leaves no entry: the generic pipeline
                    // keeps rendering. inFlight was cleared, so the next lookup
                    // miss retries (fine for transient OOM; a structurally bad
                    // name simply never lands).
                    if let compiled { s.ready[key] = compiled }
                }
            }
        }
        return nil
    }

    /// Get-or-compile the per-DE specialized source library.
    private func resolveLibrary(_ deFunctionName: String) -> MTLLibrary? {
        if let lib = state.withLock({ $0.libraries[deFunctionName] }) { return lib }
        guard let lib = try? context.compileSpecializedLibrary(
            deFunctionName: deFunctionName) else { return nil }
        state.withLock { $0.libraries[deFunctionName] = lib }
        return lib
    }
}
