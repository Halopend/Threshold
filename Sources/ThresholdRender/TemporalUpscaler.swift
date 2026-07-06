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
// thread. Here builds run off-thread: until the requested size lands,
// `prepare` returns the nearest READY size, or nil (→ full-res direct
// render). A governor descent costs zero hitches.
//
// Thread shape: `prepare`/`encode` are called by the render thread; builds
// run on ONE private serial queue, coalesced latest-wins. All state lives
// under one Mutex.
//
// Builds must NOT run on the Swift cooperative pool (the original port's
// Task.detached did): `makeTemporalScaler` BLOCKS its thread for the whole
// 0.2–2 s compile, the key is per pixel size, and a Render Quality drag or
// live window resize produces a fresh size per event — enough concurrent
// blocked builds to occupy every cooperative thread (pool width == core
// count, and it never grows). Once that happens no Task.detached anywhere
// in the app runs again — DE compiles, pipeline specialization — and under
// Xcode's Metal diagnostics (GPU capture / HUD / API validation interpose
// this exact call and can wedge it in dispatch_group_wait FOREVER) the pool
// never recovers: live-verified 10/10 cooperative threads stuck in
// makeTemporalScaler while the app read as "controls frozen". A build storm
// now costs one queue: the newest requested size wins, stale requests are
// skipped, and a wedged build strands only this queue's thread — `stalled`
// logging makes that visible instead of silent.

#if os(macOS) || os(iOS)

import Dispatch
import Foundation
import Metal
import MetalFX
import Synchronization
import ThresholdCore

final class TemporalUpscaler: Sendable {
    /// MetalFX temporal scaling supports at most 3× per dimension.
    static let maxScaleFactor: Float = 3.0
    /// Inputs with a shorter edge than this are rejected by MetalFX.
    static let minimumInputEdge = 32

    /// The smallest input size MetalFX will accept for a given output — the
    /// combined 3×-ratio and 32px-edge floors. Marching at this size (or
    /// larger) keeps the temporal scaler engaged; a request BELOW it fails
    /// `prepare`'s guards and forces a full-resolution fallback (the Render
    /// Quality < ~33% footgun). Callers clamp their reduced-res input UP to
    /// this so low quality stays cheap. `.up` rounding guarantees
    /// `floor × maxScaleFactor ≥ output` exactly (no off-by-one back into the
    /// dead zone).
    static func minimumInputSize(
        forOutputWidth width: Int, height: Int
    ) -> (width: Int, height: Int) {
        (max(Int((Float(width) / maxScaleFactor).rounded(.up)), minimumInputEdge),
         max(Int((Float(height) / maxScaleFactor).rounded(.up)), minimumInputEdge))
    }

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
        var useCounter = 0
        /// The key `prepare` last returned — `encode` consumes its reset flag.
        var activeKey: Key?
        /// The most recent requested output size; a completed build for a
        /// stale output (mid-resize) is discarded on arrival.
        var currentOutput = SIMD2<Int>(0, 0)
        /// The newest missing key (latest-wins: a drag's intermediate sizes
        /// overwrite each other here; only what's still wanted gets built).
        var wanted: Key?
        /// Whether the builder loop is live on `buildQueue`.
        var draining = false
        /// The key the builder is compiling right now — `prepare` skips
        /// re-requesting it, and ages it to detect a wedged build.
        var inFlight: Key?
        /// Consecutive `prepare` calls (≈ frames) the SAME key has been in
        /// flight. Past `stalledBuildFrameLimit` it logs once — the signature
        /// of Xcode's Metal diagnostics wedging makeTemporalScaler.
        var inFlightAge = 0
        var reportedStall = false
    }

    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let state = Mutex<State>(State())
    private let maxPoolSize = 4
    /// The one thread scaler builds may occupy (see header).
    private let buildQueue = DispatchQueue(
        label: "com.polinate.threshold.mfx-build", qos: .userInitiated)
    /// ~5–10 s at 60–120 fps before an in-flight build is reported stalled.
    private static let stalledBuildFrameLimit = 600

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
        let (pass, startDrain, reportStall): (Pass?, Bool, Bool) = state.withLock { s in
            s.useCounter += 1
            // A changed output size (window resize) strands every pooled
            // entry's full-resolution textures — drop them all.
            let out = SIMD2(outputWidth, outputHeight)
            if s.currentOutput != out {
                s.currentOutput = out
                s.entries.removeAll()
            }

            // Age the in-flight build; report a wedge exactly once per build.
            var reportStall = false
            if s.inFlight != nil {
                s.inFlightAge += 1
                if s.inFlightAge == Self.stalledBuildFrameLimit, !s.reportedStall {
                    s.reportedStall = true
                    reportStall = true
                }
            }

            if var entry = s.entries[key] {
                entry.lastUsed = s.useCounter
                // Revisited after rendering another size: its history is
                // frames old (different pose/scale) — reset, don't ghost.
                entry.needsReset = entry.needsReset || s.activeKey != key
                s.entries[key] = entry
                s.activeKey = key
                return (entry.pass, false, reportStall)
            }

            // Miss: latest-wins — overwrite whatever stale size a fast drag
            // left here. Skip only when the builder is ALREADY on this key.
            var startDrain = false
            if s.inFlight != key {
                s.wanted = key
                if !s.draining {
                    s.draining = true
                    startDrain = true
                }
            }

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
                return (entry.pass, startDrain, reportStall)
            }
            s.activeKey = nil
            return (nil, startDrain, reportStall)
        }

        if reportStall {
            ThresholdLog.render.error(
                """
                temporal scaler build stalled (>\(Self.stalledBuildFrameLimit) \
                frames in makeTemporalScaler) — Xcode Metal diagnostics \
                (GPU capture / HUD / API validation) can wedge it; rendering \
                continues at nearest/full resolution
                """)
        }
        if startDrain {
            buildQueue.async { [self] in drainBuilds() }
        }
        return pass
    }

    /// The builder loop (buildQueue only): take the newest wanted key, build
    /// it, publish, repeat until nothing is wanted. Builds superseded
    /// mid-compile still publish — a valid size for this output is a useful
    /// nearest-fallback — but a key whose OUTPUT went stale (resize) is
    /// dropped without paying for the build.
    private func drainBuilds() {
        while true {
            let next: Key? = state.withLock { s in
                guard let key = s.wanted,
                      s.currentOutput == SIMD2(key.outW, key.outH) else {
                    s.wanted = nil
                    s.draining = false
                    s.inFlight = nil
                    s.inFlightAge = 0
                    return nil
                }
                s.wanted = nil
                s.inFlight = key
                s.inFlightAge = 0
                s.reportedStall = false
                return key
            }
            guard let key = next else { return }

            let started = ProcessInfo.processInfo.systemUptime
            let built = build(key: key)
            let seconds = ProcessInfo.processInfo.systemUptime - started
            if seconds > 5 {
                ThresholdLog.render.error(
                    """
                    temporal scaler build took \(Int(seconds))s \
                    (\(key.inW)x\(key.inH)→\(key.outW)x\(key.outH)) — \
                    expected 0.2–2s; Metal diagnostics slow this dramatically
                    """)
            }

            state.withLock { s in
                s.inFlight = nil
                s.inFlightAge = 0
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
