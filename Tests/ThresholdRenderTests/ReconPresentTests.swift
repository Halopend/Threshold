// ReconPresentTests.swift — phase 0 of the temporal-reconstruction plan:
// march-size arithmetic (the multiple-of-8 lever), the ThreshReconUniforms
// layout pin, and the recon_present kernel (identity passthrough, bilinear
// upscale vs a CPU reference, and the no-ring/no-overshoot sharpen clamp).

import Foundation
import Metal
import Testing
import ThresholdShaderABI
@testable import ThresholdRender

@Suite("Recon present (phase 0)", .serialized)
struct ReconPresentTests {

    // MARK: March-size arithmetic (CPU)

    @Test func marchSizeRoundsPadsAndClamps() {
        typealias R = TemporalReconstructor
        // Scale 1 (and anything that lands at full size) = no lever: the
        // encoder must take the byte-identical pre-lever path.
        #expect(R.marchSize(outputWidth: 2048, outputHeight: 2048, scale: 1) == nil)
        #expect(R.marchSize(outputWidth: 2048, outputHeight: 2048, scale: 1.5) == nil)
        #expect(R.marchSize(outputWidth: 64, outputHeight: 64, scale: 0.99) == nil)
        // Clean halves stay clean.
        let half = R.marchSize(outputWidth: 2048, outputHeight: 2048, scale: 0.5)
        #expect(half?.width == 1024 && half?.height == 1024)
        // Non-multiple results round UP to the next multiple of 8.
        let odd = R.marchSize(outputWidth: 1000, outputHeight: 1000, scale: 0.5)
        #expect(odd?.width == 504 && odd?.height == 504)
        let g35 = R.marchSize(outputWidth: 2048, outputHeight: 2048, scale: 0.35)
        #expect(g35?.width == 720 && g35?.height == 720)  // ceil8(716.8)
        // Floor: 64 px per side (or the full size when the output is tinier —
        // which then reads as "at full size" and skips the lever).
        let tiny = R.marchSize(outputWidth: 2048, outputHeight: 2048, scale: 0.01)
        #expect(tiny?.width == 64 && tiny?.height == 64)
        #expect(R.marchSize(outputWidth: 48, outputHeight: 48, scale: 0.5) == nil)
        // Never above the output, whatever the rounding does.
        for scale in stride(from: Float(0.05), through: 1.0, by: 0.05) {
            for size in [64, 96, 250, 1000, 1888, 2048] {
                if let m = R.marchSize(
                    outputWidth: size, outputHeight: size, scale: scale) {
                    #expect(m.width <= size && m.height <= size)
                    #expect(m.width % 8 == 0 || m.width == size)
                    #expect(m.height % 8 == 0 || m.height == size)
                }
            }
        }
        // Degenerate inputs never engage the lever.
        #expect(R.marchSize(outputWidth: 0, outputHeight: 64, scale: 0.5) == nil)
        #expect(R.marchSize(outputWidth: 64, outputHeight: 64, scale: 0) == nil)
        #expect(R.marchSize(outputWidth: 64, outputHeight: 64, scale: .nan) == nil)
    }

    // MARK: Uniforms layout pin (the private-contract discipline)

    @Test func reconUniformsLayoutMatchesMSL() {
        typealias U = TemporalReconstructor.ReconUniforms
        // MSL ThreshReconUniforms: 2×float2 + float2 + 4×float + 2×uint = 48.
        #expect(MemoryLayout<U>.size == 48)
        #expect(MemoryLayout<U>.stride == 48)
        #expect(MemoryLayout<U>.offset(of: \U.dstSize) == 8)
        #expect(MemoryLayout<U>.offset(of: \U.jitter) == 16)
        #expect(MemoryLayout<U>.offset(of: \U.sharpen) == 24)
        #expect(MemoryLayout<U>.offset(of: \U.volatility) == 32)
        #expect(MemoryLayout<U>.offset(of: \U.frameIndex) == 40)
        #expect(MemoryLayout<U>.offset(of: \U.flags) == 44)
    }

    // MARK: GPU fixtures

    private func makeArray(
        _ device: MTLDevice, format: MTLPixelFormat,
        width: Int, height: Int, slices: Int, shared: Bool
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = format
        desc.width = width
        desc.height = height
        desc.arrayLength = slices
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = shared ? .shared : .private
        guard let t = device.makeTexture(descriptor: desc) else {
            throw RenderError.allocationFailed("test texture")
        }
        return t
    }

    /// Deterministic per-slice RGBA8 pattern (SplitMix64-seeded).
    private func fillRGBA8(_ texture: MTLTexture, seed: UInt64) -> [[UInt8]] {
        var slices: [[UInt8]] = []
        for slice in 0..<texture.arrayLength {
            var rng = SplitMix64(seed: seed &+ UInt64(slice) &* 0x9E37)
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: rng.next()) }
            bytes.withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                    mipmapLevel: 0, slice: slice,
                    withBytes: raw.baseAddress!, bytesPerRow: texture.width * 4,
                    bytesPerImage: texture.width * texture.height * 4)
            }
            slices.append(bytes)
        }
        return slices
    }

    private func fillDepth(_ texture: MTLTexture, seed: UInt64) -> [[Float]] {
        var slices: [[Float]] = []
        for slice in 0..<texture.arrayLength {
            var rng = SplitMix64(seed: seed &+ UInt64(slice))
            var values = [Float](repeating: 0, count: texture.width * texture.height)
            for i in values.indices { values[i] = rng.float(in: 0...1) }
            values.withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                    mipmapLevel: 0, slice: slice,
                    withBytes: raw.baseAddress!, bytesPerRow: texture.width * 4,
                    bytesPerImage: texture.width * texture.height * 4)
            }
            slices.append(values)
        }
        return slices
    }

    /// Blit a private array texture into a shared clone and read one slice.
    private func readback(
        _ texture: MTLTexture, slice: Int, queue: MTLCommandQueue
    ) throws -> [UInt8] {
        let device = queue.device
        let shared = try makeArray(
            device, format: texture.pixelFormat, width: texture.width,
            height: texture.height, slices: texture.arrayLength, shared: true)
        guard let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            throw RenderError.allocationFailed("readback blit")
        }
        blit.copy(from: texture, sourceSlice: slice, sourceLevel: 0,
                  to: shared, destinationSlice: slice, destinationLevel: 0,
                  sliceCount: 1, levelCount: 1)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let bpp = 4  // rgba8Unorm and r32Float are both 4 bytes/pixel
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * bpp)
        bytes.withUnsafeMutableBytes { raw in
            shared.getBytes(
                raw.baseAddress!, bytesPerRow: texture.width * bpp,
                bytesPerImage: texture.width * texture.height * bpp,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, slice: slice)
        }
        return bytes
    }

    private func present(
        _ ctx: GPUContext, recon: TemporalReconstructor,
        srcColor: MTLTexture, srcDepth: MTLTexture,
        outputWidth: Int, outputHeight: Int, slices: Int
    ) throws -> (color: MTLTexture, depth: MTLTexture, queue: MTLCommandQueue) {
        guard let queue = ctx.device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw RenderError.allocationFailed("test queue")
        }
        guard let out = recon.encodePresent(
            commandBuffer: cb, slot: 0, srcColor: srcColor, srcDepth: srcDepth,
            outputWidth: outputWidth, outputHeight: outputHeight, slices: slices)
        else { throw RenderError.allocationFailed("encodePresent") }
        cb.commit()
        cb.waitUntilCompleted()
        return (out.color, out.depth, queue)
    }

    // MARK: Kernel behavior

    /// Equal sizes + sharpen 0 = the identity fast path: bit-identical color
    /// AND depth, on both slices, at non-multiple-of-8 dimensions (edge
    /// threadgroups bounds-check instead of scribbling).
    @Test(.enabled(if: GPU.available))
    func identityPassthroughIsExact() throws {
        let ctx = try GPU.ctx()
        let recon = try TemporalReconstructor(context: ctx, colorFormat: .rgba8Unorm)
        recon.sharpen = 0
        let (w, h, slices) = (44, 36, 2)
        let srcColor = try makeArray(
            ctx.device, format: .rgba8Unorm, width: w, height: h,
            slices: slices, shared: true)
        let srcDepth = try makeArray(
            ctx.device, format: .r32Float, width: w, height: h,
            slices: slices, shared: true)
        let colorRef = fillRGBA8(srcColor, seed: 7)
        let depthRef = fillDepth(srcDepth, seed: 11)

        let out = try present(
            ctx, recon: recon, srcColor: srcColor, srcDepth: srcDepth,
            outputWidth: w, outputHeight: h, slices: slices)

        for slice in 0..<slices {
            let color = try readback(out.color, slice: slice, queue: out.queue)
            #expect(color == colorRef[slice], "color not bit-identical (slice \(slice))")
            let depthBytes = try readback(out.depth, slice: slice, queue: out.queue)
            let depth = depthBytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            #expect(depth == depthRef[slice], "depth not bit-identical (slice \(slice))")
        }
    }

    /// 2× upscale with sharpen 0 matches a CPU bilinear (clamp-to-edge)
    /// reference within filtering precision; depth matches a CPU NEAREST
    /// reference exactly.
    @Test(.enabled(if: GPU.available))
    func bilinearUpscaleMatchesCPUReference() throws {
        let ctx = try GPU.ctx()
        let recon = try TemporalReconstructor(context: ctx, colorFormat: .rgba8Unorm)
        recon.sharpen = 0
        let (sw, sh) = (32, 24)
        let (dw, dh) = (64, 48)
        let srcColor = try makeArray(
            ctx.device, format: .rgba8Unorm, width: sw, height: sh,
            slices: 1, shared: true)
        let srcDepth = try makeArray(
            ctx.device, format: .r32Float, width: sw, height: sh,
            slices: 1, shared: true)
        let colorRef = fillRGBA8(srcColor, seed: 21)[0]
        let depthRef = fillDepth(srcDepth, seed: 22)[0]

        let out = try present(
            ctx, recon: recon, srcColor: srcColor, srcDepth: srcDepth,
            outputWidth: dw, outputHeight: dh, slices: 1)
        let gpuColor = try readback(out.color, slice: 0, queue: out.queue)
        let gpuDepthBytes = try readback(out.depth, slice: 0, queue: out.queue)
        let gpuDepth = gpuDepthBytes.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }

        // CPU references with the kernel's exact uv math.
        func srcAt(_ x: Int, _ y: Int, _ c: Int) -> Float {
            let cx = min(max(x, 0), sw - 1)
            let cy = min(max(y, 0), sh - 1)
            return Float(colorRef[(cy * sw + cx) * 4 + c])
        }
        var maxDelta = 0
        for y in 0..<dh {
            for x in 0..<dw {
                let u = (Float(x) + 0.5) / Float(dw) * Float(sw) - 0.5
                let v = (Float(y) + 0.5) / Float(dh) * Float(sh) - 0.5
                let x0 = Int(floor(u)), y0 = Int(floor(v))
                let fx = u - Float(x0), fy = v - Float(y0)
                for c in 0..<4 {
                    let top = srcAt(x0, y0, c) * (1 - fx) + srcAt(x0 + 1, y0, c) * fx
                    let bot = srcAt(x0, y0 + 1, c) * (1 - fx) + srcAt(x0 + 1, y0 + 1, c) * fx
                    let ref = top * (1 - fy) + bot * fy
                    let got = Float(gpuColor[(y * dw + x) * 4 + c])
                    maxDelta = max(maxDelta, Int(abs(got - ref.rounded())))
                }
                // Depth: nearest, exact — same expression order as the
                // kernel (power-of-two ratio keeps CPU/GPU floors identical).
                let nx = min(Int(floor((Float(x) + 0.5) / Float(dw) * Float(sw))), sw - 1)
                let ny = min(Int(floor((Float(y) + 0.5) / Float(dh) * Float(sh))), sh - 1)
                let refD = depthRef[ny * sw + nx]
                #expect(gpuDepth[y * dw + x] == refD,
                        "depth not nearest-exact at (\(x),\(y))")
            }
        }
        // 8-bit storage + GPU subtexel weight precision: ±2 is honest.
        #expect(maxDelta <= 2, "bilinear drifted from CPU reference (maxΔ \(maxDelta))")
    }

    /// The sharpen clamp guarantee: on a hard edge the output never leaves
    /// the local [min, max] (no ringing/overshoot), and flat regions pass
    /// through unchanged.
    @Test(.enabled(if: GPU.available))
    func sharpenNeverOvershoots() throws {
        let ctx = try GPU.ctx()
        let recon = try TemporalReconstructor(context: ctx, colorFormat: .rgba8Unorm)
        recon.sharpen = 0.3
        let (sw, sh) = (32, 32)
        let (dw, dh) = (64, 64)
        let lo: UInt8 = 51   // 0.2
        let hi: UInt8 = 204  // 0.8
        let srcColor = try makeArray(
            ctx.device, format: .rgba8Unorm, width: sw, height: sh,
            slices: 1, shared: true)
        var bytes = [UInt8](repeating: 0, count: sw * sh * 4)
        for y in 0..<sh {
            for x in 0..<sw {
                let v = x < sw / 2 ? lo : hi
                let i = (y * sw + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
            }
        }
        bytes.withUnsafeBytes { raw in
            srcColor.replace(
                region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, slice: 0,
                withBytes: raw.baseAddress!, bytesPerRow: sw * 4,
                bytesPerImage: sw * sh * 4)
        }
        let srcDepth = try makeArray(
            ctx.device, format: .r32Float, width: sw, height: sh,
            slices: 1, shared: true)
        _ = fillDepth(srcDepth, seed: 3)

        let out = try present(
            ctx, recon: recon, srcColor: srcColor, srcDepth: srcDepth,
            outputWidth: dw, outputHeight: dh, slices: 1)
        let gpu = try readback(out.color, slice: 0, queue: out.queue)

        for y in 0..<dh {
            for x in 0..<dw {
                let i = (y * dw + x) * 4
                for c in 0..<3 {
                    let v = gpu[i + c]
                    #expect(v >= lo - 1 && v <= hi + 1,
                            "sharpen overshot local range at (\(x),\(y)): \(v)")
                }
                // Far from the edge (¼ and ¾ across) the image is flat —
                // sharpening must leave it alone.
                if x < dw / 4 {
                    #expect(abs(Int(gpu[i]) - Int(lo)) <= 1)
                } else if x > 3 * dw / 4 {
                    #expect(abs(Int(gpu[i]) - Int(hi)) <= 1)
                }
                #expect(gpu[i + 3] == 255, "alpha must pass through")
            }
        }
    }
}
