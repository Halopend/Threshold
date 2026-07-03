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
import ThresholdShaderIR

/// A specialized march pipeline + its (pipeline-matched) DE table. The table
/// is still bound — Metal requires the argument — but never dispatched
/// through in the specialized variant.
public struct SpecializedMarch: @unchecked Sendable {
    // AUDIT — @unchecked: both properties are immutable Metal objects,
    // documented thread-safe (same precedent as GPUContext).
    public let pipeline: MTLComputePipelineState
    public let deTable: MTLVisibleFunctionTable
}

extension GPUContext {
    /// Compile the march variant that calls `deFunctionName` directly.
    /// `auxOutputs` additionally bakes THRESH_AUX true (the temporal-upscale
    /// input variant — the live path pairs specialization with upscaling).
    /// EXPENSIVE (a full library compile, ~100–400 ms) — call off the render
    /// thread; the OS Metal compiler cache makes warm relaunches fast.
    public func makeSpecializedMarch(
        deFunctionName: String, auxOutputs: Bool = false
    ) throws -> SpecializedMarch {
        guard DERegistry.builtin.contains(where: { $0.mslFunctionName == deFunctionName })
        else { throw RenderError.missingFunction("not a built-in DE: \(deFunctionName)") }

        guard let coreURL = Bundle.module.url(
            forResource: "RaymarchCore", withExtension: "metal", subdirectory: "MSL")
        else { throw RenderError.missingResource("MSL/RaymarchCore.metal") }
        let core = try String(contentsOf: coreURL, encoding: .utf8)
        let source = "#define THRESH_SPEC_DE \(deFunctionName)\n"
            + abiHeaderSource + "\n" + core

        let options = MTLCompileOptions()
        // Identical semantics to the generic compile (including the
        // measurement-seam override — a specialized variant must never differ
        // from the generic pipeline it replaces).
        options.mathMode = GPUContext.mathModeOverride ?? .safe
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: options)
        } catch {
            throw RenderError.shaderCompileFailed(
                "specialized(\(deFunctionName)): \(String(describing: error))")
        }

        let pipeline = try Self.makeLinkedPipeline(
            device: device, library: library, kernelName: "march_offscreen",
            deFunctions: builtinDEFunctions, auxOutputs: auxOutputs)
        let table = try Self.makeDETable(
            pipeline, functions: builtinDEFunctions,
            label: "specialized(\(deFunctionName)) DE table")
        return SpecializedMarch(pipeline: pipeline, deTable: table)
    }
}

/// Non-blocking cache: the render thread calls `lookup` each frame; a miss
/// kicks off ONE background compile and keeps returning nil until it lands.
/// Compiler-checked Sendable (a Mutex over Sendable state).
public final class SpecializationCache: Sendable {
    private struct State {
        var ready: [String: SpecializedMarch] = [:]
        var inFlight: Set<String> = []
    }

    private let context: GPUContext
    private let state = Mutex<State>(State())

    public init(context: GPUContext) {
        self.context = context
    }

    /// The specialized pipeline for a built-in DE function name, if compiled.
    /// A miss schedules the compile (once) and returns nil — render generic.
    /// `auxOutputs` selects the temporal-upscale input variant (cached
    /// separately — the live path needs both while the scale crosses 1).
    public func lookup(deFunctionName: String, auxOutputs: Bool = false) -> SpecializedMarch? {
        let key = auxOutputs ? "\(deFunctionName)#aux" : deFunctionName
        let shouldCompile: Bool = state.withLock { s in
            if s.ready[key] != nil { return false }
            return s.inFlight.insert(key).inserted
        }
        if let hit = state.withLock({ $0.ready[key] }) { return hit }

        if shouldCompile {
            let context = context
            Task.detached(priority: .utility) { [self] in
                let compiled = try? context.makeSpecializedMarch(
                    deFunctionName: deFunctionName, auxOutputs: auxOutputs)
                state.withLock { s in
                    s.inFlight.remove(key)
                    // A failed compile leaves no entry: the generic pipeline
                    // simply keeps rendering (and we do not retry-storm — the
                    // name goes back to compile-once on the next lookup miss
                    // only because inFlight was cleared; failures are
                    // permanent per session for a bad name, transient OOM
                    // retries are acceptable).
                    if let compiled { s.ready[key] = compiled }
                }
            }
        }
        return nil
    }
}
