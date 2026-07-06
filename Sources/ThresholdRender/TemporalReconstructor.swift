// TemporalReconstructor.swift — host of the custom temporal reconstruction
// (the visionOS answer to MetalFX, which does not exist there).
//
// Phase 0 scope (this file grows by phase, plan: temporal reconstruction):
// the PRESENT pass — the compute backend marches into reduced-resolution
// intermediates (its previously-missing resolution lever) and this class
// upsamples+sharpens them into output-resolution intermediates the encoder
// blits to the drawable. Later phases add the jittered-march aux inputs,
// the temporal_resolve history accumulation (stabilize/TAAU modes), seeding,
// and per-tile ray budgets.
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
    /// Output-resolution present targets, one per in-flight slot (the same
    /// 3-deep contract as ViewComputeEncoder's rings; cross-frame reuse is
    /// ordered by tracked-resource hazards).
    private var presentColorRing: [MTLTexture?] = [nil, nil, nil]
    private var presentDepthRing: [MTLTexture?] = [nil, nil, nil]

    /// RCAS strength for the present pass. 0.25 is the plan's default; the
    /// identity fast path in the kernel only engages at exactly 0.
    var sharpen: Float = 0.25

    init(context: GPUContext, colorFormat: MTLPixelFormat) throws {
        self.context = context
        self.colorFormat = colorFormat
        let library = try context.resolveLibrary()
        guard let fn = library.makeFunction(name: "recon_present") else {
            throw RenderError.missingFunction("recon_present")
        }
        do {
            self.presentPipeline = try context.device
                .makeComputePipelineState(function: fn)
        } catch {
            throw RenderError.pipelineCreationFailed(
                "recon_present: \(String(describing: error))")
        }
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
