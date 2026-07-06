// TemporalReconstructor.swift — host of the custom temporal reconstruction
// (the visionOS answer to MetalFX, which does not exist there).
//
// Phase 0 gave the compute backend its resolution lever: march into
// reduced-resolution intermediates, present (upsample+sharpen) into
// output-resolution intermediates the encoder blits to the drawable.
// Phase A adds the temporal loop: Halton-jittered march (aux variant) →
// temporal_resolve accumulating a persistent history ping-pong (stabilize @
// march res / TAAU @ drawable res — one kernel, fc 20) → present from the
// RESOLVED color/t (fc 21; depth is derived from converged t so the
// compositor reprojects converged geometry). Remaining phases: seeding
// (A2), per-tile ray budgets (B).
//
// Deliberately NOT #if os(visionOS) — the ViewCompute.swift reasoning: the
// pass renders into any texture pair, so the Mac suite validates it before it
// reaches the device, and Mac is the tuning rig for every threshold in it.
//
// Kernels/bindings/ThreshReconUniforms live in MSL/TemporalResolve.metal, a
// SECOND lazily-compiled library (GPUContext.resolveLibrary()) — private
// contract, not published ABI; the layout is pinned by ReconPresentTests.

import Foundation
import Metal
import ThresholdShaderABI

// MARK: - TemporalReconstructor

/// Render-thread-confined (same contract as the encoders that own it).
final class TemporalReconstructor {

    /// The accumulation mode — the plan's user-locked bench toggle.
    /// `.off` = no temporal history (phase 0: present-only). `.stabilize` =
    /// history at march resolution, upsample after. `.taau` = history at
    /// output resolution, jittered samples accumulate real subpixel detail.
    public enum Mode: String, CaseIterable, Sendable {
        case off, stabilize, taau
    }

    /// Swift mirror of the MSL `ThreshReconUniforms` (private contract).
    /// 48 bytes; layout pinned by ReconPresentTests.reconUniformsLayout.
    struct ReconUniforms {
        var srcSize: SIMD2<Float>
        var dstSize: SIMD2<Float>
        var jitter: SIMD2<Float> = .zero
        var sharpen: Float = 0
        var tScale: Float = 1
        var volatility: Float = 0
        var alphaBase: Float = 0
        var frameIndex: UInt32 = 0
        var flags: UInt32 = 0
    }

    private let context: GPUContext
    private let colorFormat: MTLPixelFormat
    private let presentPipeline: MTLComputePipelineState
    /// Phase-A present: color from the resolved history, depth DERIVED from
    /// the resolved t (function constant 21).
    private let presentFromTPipeline: MTLComputePipelineState
    /// Phase-A resolve, one per accumulation mode (function constant 20:
    /// false = stabilize 1:1 fetch, true = TAAU Catmull-Rom + confidence).
    private let resolveStabilizePipeline: MTLComputePipelineState
    private let resolveTAAUPipeline: MTLComputePipelineState
    /// Output-resolution present targets, one per in-flight slot (the same
    /// 3-deep contract as ViewComputeEncoder's rings; cross-frame reuse is
    /// ordered by tracked-resource hazards).
    private var presentColorRing: [MTLTexture?] = [nil, nil, nil]
    private var presentDepthRing: [MTLTexture?] = [nil, nil, nil]

    /// The accumulation mode. `.off` keeps the phase-0 present-only path.
    /// Render-thread-confined like everything else here; the shells set it at
    /// loop start (visionOS: UserDefaults/env), tests set it directly.
    var mode: Mode = .off

    /// RCAS strength for the present pass. 0.25 is the plan's default; the
    /// identity fast path in the kernel only engages at exactly 0. The
    /// temporal present overrides per mode (0.30 stabilize / 0.25 TAAU) —
    /// clamp-before-sharpen makes stronger sharpening safe there.
    var sharpen: Float = 0.25

    // MARK: Temporal history (persistent ping-pong — serial across frames,
    // deliberately NOT ring-slotted: frame N's resolve reads frame N−1's
    // write; the single-queue ordering is the hazard fence.)

    private var historyColor: [MTLTexture?] = [nil, nil]
    private var historyAux: [MTLTexture?] = [nil, nil]
    /// Which history pair the NEXT resolve reads (its write side is 1−this).
    private var historyRead = 0
    /// False until a resolve has written history at the current size — the
    /// first resolve after (re)allocation always runs with the reset flag.
    private var historyValid = false
    /// Sequence position for the jitter pattern; reset with history so
    /// convergence tests are deterministic.
    private var frameIndex: UInt32 = 0
    /// The jitter `beginFrame` handed out for the in-flight frame.
    private var currentJitter = SIMD2<Float>(0, 0)
    /// Host-side reset requests (octave rebase, scene epoch) — consumed by
    /// the next resolve.
    private var pendingReset = false

    init(context: GPUContext, colorFormat: MTLPixelFormat) throws {
        self.context = context
        self.colorFormat = colorFormat
        let library = try context.resolveLibrary()

        func pipeline(
            _ name: String, constant: (index: Int, value: Bool)? = nil
        ) throws -> MTLComputePipelineState {
            // Both kernels reference function constants now, so creation must
            // go through the specialized-function path even for the default
            // variant (empty values — the constants are optional-with-default,
            // the makeLinkedPipeline "constantKernels" rule).
            let values = MTLFunctionConstantValues()
            if let constant {
                var v = constant.value
                values.setConstantValue(&v, type: .bool, index: constant.index)
            }
            let fn: MTLFunction
            do {
                fn = try library.makeFunction(name: name, constantValues: values)
            } catch {
                throw RenderError.missingFunction(
                    "\(name) fc\(String(describing: constant)): \(String(describing: error))")
            }
            do {
                return try context.device.makeComputePipelineState(function: fn)
            } catch {
                throw RenderError.pipelineCreationFailed(
                    "\(name): \(String(describing: error))")
            }
        }

        // All four variants build at construction — loop-start by contract
        // (CompositorSession constructs before the render loop), so no
        // compile ever lands mid-frame and no build ever leaves this thread.
        self.presentPipeline = try pipeline("recon_present")
        self.presentFromTPipeline = try pipeline(
            "recon_present", constant: (21, true))
        self.resolveStabilizePipeline = try pipeline(
            "temporal_resolve", constant: (20, false))
        self.resolveTAAUPipeline = try pipeline(
            "temporal_resolve", constant: (20, true))
    }

    // MARK: Reset funnel

    /// Invalidate history before the next resolve (octave rebase, DE switch,
    /// hard scene apply). Allocation rebuilds funnel in implicitly.
    func requestHistoryReset() {
        pendingReset = true
    }

    // MARK: Jitter

    /// Halton radical inverse — the SAME low-discrepancy sequence the Mac
    /// MetalFX path jitters with (InteractiveSession); one copy per language
    /// side, pinned against each other by TemporalResolveTests.
    static func halton(_ index: Int, base: Int) -> Float {
        var result: Float = 0
        var f: Float = 1
        var i = index
        while i > 0 {
            f /= Float(base)
            result += f * Float(i % base)
            i /= base
        }
        return result
    }

    /// The jitter cycle length for a march→accumulation ratio: enough
    /// samples to fill the upsample factor's subpixel lattice (8 minimum,
    /// 64 cap — beyond that the tail contributes nothing visible).
    static func jitterCycle(marchWidth: Int, accWidth: Int) -> Int {
        guard marchWidth > 0 else { return 8 }
        let ratio = Float(accWidth) / Float(marchWidth)
        return min(max(Int((8 * ratio * ratio).rounded(.up)), 8), 64)
    }

    /// Advance the sequence and return this frame's sub-pixel jitter in
    /// MARCH pixels, centered on zero. Both eyes share it (stereo-divergence
    /// defense). Call once per frame BEFORE the march; `encodeResolve`
    /// removes the same offset when accumulating.
    func beginFrame(marchWidth: Int, accWidth: Int) -> SIMD2<Float> {
        let cycle = Self.jitterCycle(marchWidth: marchWidth, accWidth: accWidth)
        let step = Int(frameIndex % UInt32(cycle)) + 1   // 1-based: skip (0,0)
        currentJitter = SIMD2(
            Self.halton(step, base: 2) - 0.5,
            Self.halton(step, base: 3) - 0.5)
        frameIndex &+= 1
        return currentJitter
    }

    // MARK: Temporal resolve

    /// Accumulate this frame's jittered march into history and return the
    /// resolved (color, aux) pair at accumulation resolution — the present
    /// pass's source. nil on allocation failure (caller drops the frame).
    /// `volatility` is the lane engine's world-morph scalar (RenderRequest).
    func encodeResolve(
        commandBuffer: MTLCommandBuffer,
        marchColor: MTLTexture, marchT: MTLTexture, marchMotion: MTLTexture,
        views: [ThreshViewUniforms], prevViews: [ThreshViewUniforms],
        outputWidth: Int, outputHeight: Int,
        volatility: Float, slices: Int
    ) -> (color: MTLTexture, aux: MTLTexture)? {
        guard mode != .off, views.count == slices,
              prevViews.count == slices else { return nil }
        let accW = mode == .taau ? outputWidth : marchColor.width
        let accH = mode == .taau ? outputHeight : marchColor.height

        // (Re)allocate the ping-pong on size/slice change — a full reset.
        // (Stabilize-mode scale changes land here; preserving contents across
        // a resize is a soft-reset refinement the bench can motivate later.)
        if historyColor[0]?.width != accW || historyColor[0]?.height != accH
            || historyColor[0]?.arrayLength != slices {
            for i in 0...1 {
                historyColor[i] = makeHistoryTexture(
                    pixelFormat: .rgba16Float, width: accW, height: accH,
                    slices: slices, label: "recon history color [\(i)]")
                historyAux[i] = makeHistoryTexture(
                    pixelFormat: .rg16Float, width: accW, height: accH,
                    slices: slices, label: "recon history aux [\(i)]")
            }
            historyRead = 0
            historyValid = false
            // frameIndex deliberately NOT reset: beginFrame already advanced
            // it for THIS frame, and a mid-frame rewind would hand the next
            // frame a duplicate jitter (one wasted accumulation step). The
            // sequence is deterministic from construction either way.
        }
        guard let readColor = historyColor[historyRead],
              let readAux = historyAux[historyRead],
              let writeColor = historyColor[1 - historyRead],
              let writeAux = historyAux[1 - historyRead],
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        let reset = pendingReset || !historyValid
        pendingReset = false

        let uniforms = ReconUniforms(
            srcSize: SIMD2(Float(marchColor.width), Float(marchColor.height)),
            dstSize: SIMD2(Float(accW), Float(accH)),
            jitter: currentJitter,
            sharpen: 0,
            tScale: 1,
            volatility: min(max(volatility, 0), 1),
            alphaBase: mode == .taau ? 0.10 : 0.08,
            frameIndex: frameIndex,
            flags: reset ? 1 : 0)

        encoder.label = "temporal resolve (\(mode.rawValue))"
        encoder.setComputePipelineState(
            mode == .taau ? resolveTAAUPipeline : resolveStabilizePipeline)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        views.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        prevViews.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 2)
        }
        encoder.setTexture(marchColor, index: 0)
        encoder.setTexture(marchT, index: 1)
        encoder.setTexture(marchMotion, index: 2)
        encoder.setTexture(readColor, index: 3)
        encoder.setTexture(readAux, index: 4)
        encoder.setTexture(writeColor, index: 5)
        encoder.setTexture(writeAux, index: 6)
        encoder.dispatchThreadgroups(
            MTLSize(width: (accW + 7) / 8, height: (accH + 7) / 8, depth: slices),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()

        historyRead = 1 - historyRead
        historyValid = true
        return (writeColor, writeAux)
    }

    /// Present the RESOLVED history: color (Catmull-Rom upsample in stabilize
    /// mode, direct in TAAU) + RCAS, and clip depth derived per output pixel
    /// from the resolved t through this view's projection. `farDistance`
    /// stands in for the miss sentinel (the march's max-dist param).
    func encodePresentResolved(
        commandBuffer: MTLCommandBuffer, slot: Int,
        resolvedColor: MTLTexture, resolvedAux: MTLTexture,
        views: [ThreshViewUniforms],
        outputWidth: Int, outputHeight: Int, slices: Int,
        farDistance: Float
    ) -> (color: MTLTexture, depth: MTLTexture)? {
        guard let outColor = ringTexture(
                  &presentColorRing, slot: slot, pixelFormat: colorFormat,
                  width: outputWidth, height: outputHeight, slices: slices,
                  label: "recon present color"),
              let outDepth = ringTexture(
                  &presentDepthRing, slot: slot, pixelFormat: .r32Float,
                  width: outputWidth, height: outputHeight, slices: slices,
                  label: "recon present depth"),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        let uniforms = ReconUniforms(
            srcSize: SIMD2(Float(resolvedColor.width), Float(resolvedColor.height)),
            dstSize: SIMD2(Float(outputWidth), Float(outputHeight)),
            jitter: .zero,
            sharpen: mode == .taau ? 0.25 : 0.30,
            tScale: max(farDistance, 1e-4),
            volatility: 0,
            alphaBase: 0,
            frameIndex: frameIndex,
            flags: 0)

        encoder.label = "recon present (resolved)"
        encoder.setComputePipelineState(presentFromTPipeline)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        views.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.setTexture(resolvedColor, index: 0)
        encoder.setTexture(resolvedAux, index: 1)
        encoder.setTexture(outColor, index: 2)
        encoder.setTexture(outDepth, index: 3)
        encoder.dispatchThreadgroups(
            MTLSize(width: (outputWidth + 7) / 8,
                    height: (outputHeight + 7) / 8,
                    depth: slices),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        return (outColor, outDepth)
    }

    private func makeHistoryTexture(
        pixelFormat: MTLPixelFormat, width: Int, height: Int, slices: Int,
        label: String
    ) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = pixelFormat
        desc.width = width
        desc.height = height
        desc.arrayLength = slices
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        let texture = context.device.makeTexture(descriptor: desc)
        texture?.label = label
        return texture
    }

    // MARK: March sizing

    /// The march resolution for `scale` against an output size: rounded UP to
    /// multiples of 8 (every march kernel dispatches 8×8 threadgroups and the
    /// cone tile map assumes full tiles), floored at 64 px per side, never
    /// above the output. Returns nil when the result IS the output size —
    /// the caller marches at full size and skips the present pass entirely
    /// (byte-identical to the pre-lever path).
    static func marchSize(
        outputWidth: Int, outputHeight: Int, scale: Float
    ) -> (width: Int, height: Int)? {
        guard outputWidth > 0, outputHeight > 0, scale > 0, scale.isFinite
        else { return nil }
        let s = min(scale, 1)
        func side(_ full: Int) -> Int {
            let raw = Int((Float(full) * s).rounded(.up))
            let padded = (raw + 7) / 8 * 8
            return min(max(padded, min(64, full)), full)
        }
        let w = side(outputWidth)
        let h = side(outputHeight)
        if w >= outputWidth, h >= outputHeight { return nil }
        return (w, h)
    }

    // MARK: Present

    /// Upsample+sharpen march-resolution intermediates into output-resolution
    /// intermediates (2D arrays, one slice per view). Returns the textures to
    /// blit to the drawable, or nil on allocation failure (the caller drops
    /// the frame — the encoders' standing contract).
    func encodePresent(
        commandBuffer: MTLCommandBuffer, slot: Int,
        srcColor: MTLTexture, srcDepth: MTLTexture,
        outputWidth: Int, outputHeight: Int, slices: Int
    ) -> (color: MTLTexture, depth: MTLTexture)? {
        guard let outColor = ringTexture(
                  &presentColorRing, slot: slot, pixelFormat: colorFormat,
                  width: outputWidth, height: outputHeight, slices: slices,
                  label: "recon present color"),
              let outDepth = ringTexture(
                  &presentDepthRing, slot: slot, pixelFormat: .r32Float,
                  width: outputWidth, height: outputHeight, slices: slices,
                  label: "recon present depth"),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        let uniforms = ReconUniforms(
            srcSize: SIMD2(Float(srcColor.width), Float(srcColor.height)),
            dstSize: SIMD2(Float(outputWidth), Float(outputHeight)),
            sharpen: sharpen)
        encoder.label = "recon present"
        encoder.setComputePipelineState(presentPipeline)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        encoder.setTexture(srcColor, index: 0)
        encoder.setTexture(srcDepth, index: 1)
        encoder.setTexture(outColor, index: 2)
        encoder.setTexture(outDepth, index: 3)
        encoder.dispatchThreadgroups(
            MTLSize(width: (outputWidth + 7) / 8,
                    height: (outputHeight + 7) / 8,
                    depth: slices),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        return (outColor, outDepth)
    }

    /// Get-or-rebuild one ring slot's private array texture (the
    /// ViewComputeEncoder shape — duplicated here rather than shared because
    /// the two classes' rings have different lifecycles by design).
    private func ringTexture(
        _ ring: inout [MTLTexture?], slot: Int, pixelFormat: MTLPixelFormat,
        width: Int, height: Int, slices: Int, label: String
    ) -> MTLTexture? {
        if let cached = ring[slot], cached.width == width,
           cached.height == height, cached.arrayLength == slices,
           cached.pixelFormat == pixelFormat {
            return cached
        }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = pixelFormat
        desc.width = width
        desc.height = height
        desc.arrayLength = slices
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        let texture = context.device.makeTexture(descriptor: desc)
        texture?.label = "\(label) [\(slot)]"
        ring[slot] = texture
        return texture
    }
}
