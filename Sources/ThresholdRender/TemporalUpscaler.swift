// TemporalUpscaler.swift — MetalFX temporal upscaling for the live Mac/iOS
// path (perf block 5). The march renders color + depth + motion at reduced
// resolution with a jittered projection (RaymarchCore's THRESH_AUX variant);
// the scaler reconstructs a full-resolution frame from accumulated history.
// This is the Mac counterpart of the visionOS compositor renderQuality lever
// — one governor renderScale signal, two platform mechanisms.
//
// Ported from the original app's MacTemporalUpscaler, keeping its two
// hard-won details — the size-keyed LRU pool and the reset-before-textures
// ordering (newer MetalFX SDKs clear tracked texture state on reset) — and
// fixing its one measured flaw: scaler construction is EXPENSIVE (measured
// 0.2–2 s first-build on this machine) and the old app paid it on the render
// thread. Here builds run off-thread (SpecializationCache's pattern): until
// the requested size lands, `prepare` returns the nearest READY size, or nil
// (→ full-res direct render). A governor descent costs zero hitches.
//
// Thread shape: `prepare`/`encode` are called by the render thread; builds
// complete on a detached task. All state lives under one Mutex.

#if os(macOS) || os(iOS)

import Metal
import MetalFX
import Synchronization

final class TemporalUpscaler: Sendable {
    /// MetalFX temporal scaling supports at most 3× per dimension.
    static let maxScaleFactor: Float = 3.0
    /// Inputs with a shorter edge than this are rejected by MetalFX.
    static let minimumInputEdge = 32

    static let depthFormat: MTLPixelFormat = .r32Float
    static let motionFormat: MTLPixelFormat = .rg16Float

    /// One ready configuration: the scaler plus every texture it owns.
    /// AUDIT — @unchecked: immutable references to Metal objects (documented
    /// thread-safe), same precedent as SpecializedMarch. The scaler's mutable
    /// per-encode properties are only touched by the render thread (encode).
    struct Pass: @unchecked Sendable {
        let color: MTLTexture    // march writes (input)
        let depth: MTLTexture    // march writes (input)
        let motion: MTLTexture   // march writes (input)
        let output: MTLTexture   // scaler writes; blit-copied to the drawable
        let scaler: MTLFXTemporalScaler
    }

    private struct Key: Hashable, Sendable {
        let inW: Int, inH: Int, outW: Int, outH: Int
    }

    private struct Entry {
        let pass: Pass
        var lastUsed: Int
        var needsReset: Bool
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var building: Set<Key> = []
        var useCounter = 0
        /// The key `prepare` last returned — `encode` consumes its reset flag.
        var activeKey: Key?
        /// The most recent requested output size; a completed build for a
        /// stale output (mid-resize) is discarded on arrival.
        var currentOutput = SIMD2<Int>(0, 0)
    }

    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let state = Mutex<State>(State())
    private let maxPoolSize = 4

    /// nil when this device can't do MetalFX temporal scaling — the caller
    /// renders at full resolution instead (the governor's scale is moot).
    init?(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard MTLFXTemporalScalerDescriptor.supportsDevice(device) else { return nil }
        self.device = device
        self.colorFormat = colorFormat
    }

    /// The best READY pass for this frame: the exact requested size when its
    /// build has landed, else the nearest ready size for the same output
    /// (kicking off the exact build in the background), else nil — render
    /// full-res direct this frame. Never blocks.
    func prepare(
        inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int
    ) -> Pass? {
        guard min(inputWidth, inputHeight) >= Self.minimumInputEdge,
              inputWidth <= outputWidth, inputHeight <= outputHeight,
              Float(outputWidth) <= Float(inputWidth) * Self.maxScaleFactor,
              Float(outputHeight) <= Float(inputHeight) * Self.maxScaleFactor
        else {
            state.withLock { $0.activeKey = nil }
            return nil
        }

        let key = Key(inW: inputWidth, inH: inputHeight,
                      outW: outputWidth, outH: outputHeight)
        let (pass, shouldBuild): (Pass?, Bool) = state.withLock { s in
            s.useCounter += 1
            // A changed output size (window resize) strands every pooled
            // entry's full-resolution textures — drop them all.
            let out = SIMD2(outputWidth, outputHeight)
            if s.currentOutput != out {
                s.currentOutput = out
                s.entries.removeAll()
            }

            if var entry = s.entries[key] {
                entry.lastUsed = s.useCounter
                // Revisited after rendering another size: its history is
                // frames old (different pose/scale) — reset, don't ghost.
                entry.needsReset = entry.needsReset || s.activeKey != key
                s.entries[key] = entry
                s.activeKey = key
                return (entry.pass, false)
            }

            let shouldBuild = s.building.insert(key).inserted
            // Nearest ready fallback: the entry whose input area is closest
            // to the request (same output — everything pooled matches).
            let target = inputWidth * inputHeight
            let nearest = s.entries.min {
                abs($0.key.inW * $0.key.inH - target)
                    < abs($1.key.inW * $1.key.inH - target)
            }
            if let nearest {
                var entry = nearest.value
                entry.lastUsed = s.useCounter
                entry.needsReset = entry.needsReset || s.activeKey != nearest.key
                s.entries[nearest.key] = entry
                s.activeKey = nearest.key
                return (entry.pass, shouldBuild)
            }
            s.activeKey = nil
            return (nil, shouldBuild)
        }

        if shouldBuild {
            Task.detached(priority: .userInitiated) { [self] in
                let built = build(key: key)
                state.withLock { s in
                    s.building.remove(key)
                    // Discard a build that raced a resize (stale output).
                    guard let built,
                          s.currentOutput == SIMD2(key.outW, key.outH)
                    else { return }
                    s.entries[key] = Entry(
                        pass: built, lastUsed: s.useCounter, needsReset: true)
                    if s.entries.count > maxPoolSize,
                       let evict = s.entries.filter({ $0.key != s.activeKey })
                           .min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                        s.entries.removeValue(forKey: evict.key)
                    }
                }
            }
        }
        return pass
    }

    /// Encode the upscale for the pass `prepare` just returned (render
    /// thread, same frame). `jitterPixels` is the sub-pixel offset the march
    /// applied; `forceReset` discards history (octave rebase, camera cut).
    func encode(
        commandBuffer: MTLCommandBuffer,
        jitterPixels: SIMD2<Float>,
        forceReset: Bool
    ) {
        let ready: (Pass, Bool)? = state.withLock { s in
            guard let key = s.activeKey, var entry = s.entries[key] else {
                return nil
            }
            let reset = entry.needsReset || forceReset
            entry.needsReset = false
            s.entries[key] = entry
            return (entry.pass, reset)
        }
        guard let (pass, reset) = ready else { return }

        // Reset BEFORE texture assignment (MetalFX clears tracked texture
        // state when reset is set).
        pass.scaler.reset = reset
        pass.scaler.colorTexture = pass.color
        pass.scaler.depthTexture = pass.depth
        pass.scaler.motionTexture = pass.motion
        pass.scaler.outputTexture = pass.output
        pass.scaler.inputContentWidth = pass.color.width
        pass.scaler.inputContentHeight = pass.color.height
        pass.scaler.jitterOffsetX = jitterPixels.x
        pass.scaler.jitterOffsetY = jitterPixels.y
        // The march writes motion directly in input pixels.
        pass.scaler.motionVectorScaleX = 1
        pass.scaler.motionVectorScaleY = 1
        pass.scaler.encode(commandBuffer: commandBuffer)
    }

    private func build(key: Key) -> Pass? {
        func texture(
            _ w: Int, _ h: Int, _ format: MTLPixelFormat,
            _ usage: MTLTextureUsage, _ label: String
        ) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: w, height: h, mipmapped: false)
            desc.usage = usage
            desc.storageMode = .private
            let t = device.makeTexture(descriptor: desc)
            t?.label = label
            return t
        }

        // The march writes inputs via compute (shaderWrite); MetalFX reads
        // them (shaderRead) and writes the output (write + read for its own
        // history feedback; renderTarget for the raster passes MetalFX uses
        // internally on some configurations).
        guard
            let color = texture(key.inW, key.inH, colorFormat,
                                [.shaderWrite, .shaderRead], "fx color in"),
            let depth = texture(key.inW, key.inH, Self.depthFormat,
                                [.shaderWrite, .shaderRead], "fx depth in"),
            let motion = texture(key.inW, key.inH, Self.motionFormat,
                                 [.shaderWrite, .shaderRead], "fx motion in"),
            let output = texture(key.outW, key.outH, colorFormat,
                                 [.shaderRead, .shaderWrite, .renderTarget],
                                 "fx output")
        else { return nil }

        let desc = MTLFXTemporalScalerDescriptor()
        desc.inputWidth = key.inW
        desc.inputHeight = key.inH
        desc.outputWidth = key.outW
        desc.outputHeight = key.outH
        desc.colorTextureFormat = colorFormat
        desc.depthTextureFormat = Self.depthFormat
        desc.motionTextureFormat = Self.motionFormat
        desc.outputTextureFormat = colorFormat
        guard let scaler = desc.makeTemporalScaler(device: device) else {
            return nil
        }
        // The march writes linear depth 0 (near) … 1 (far) — not reversed.
        scaler.isDepthReversed = false
        return Pass(color: color, depth: depth, motion: motion,
                    output: output, scaler: scaler)
    }
}

#endif  // os(macOS) || os(iOS)
