// InteractiveSession.swift — the live counterpart of the offscreen harness
// (ARCHITECTURE.md §2, ADR-004): a DEDICATED render thread (not an actor)
// driven by CAMetalDisplayLink, reached only through the lane mailbox and the
// command mailbox, with egress only via the SnapshotSlot (Invariant 13 — no
// third channel).
//
// The display-link callback is a thin shell over SessionCore.step(now:) —
// the same per-frame body tests drive manually against OffscreenRenderer.
//
// macOS + iOS/iPadOS: both drive the SAME CAMetalDisplayLink loop (ADR-001:
// one compute shell; presentation differences live in the layer host, not
// here). visionOS renders through the Compositor Services frame loop instead
// (CompositorSession.swift) — same SessionCore frame body, raster encode.

#if os(macOS) || os(iOS)

import Foundation
import Metal
import QuartzCore
import Synchronization
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR

// MARK: - InteractiveSession

/// AUDIT — `@unchecked Sendable` (the honest escape hatch ARCHITECTURE §1
/// permits, same precedent as GPUContext/OffscreenRenderer in this target):
/// - `laneMailbox`, `commands`, `snapshots` are compiler-checked Sendable.
/// - `context` (audited Sendable), `layout`, `signals`, `initialScene` are
///   Sendable and `let`.
/// - `layer` is a non-Sendable `let` set at init; after `start()` it is
///   touched ONLY by the render thread (the creating thread configures it
///   before start — documented contract of `configure(layer:)`).
/// - `phase` is a Mutex; `stopRequested` is an Atomic; `started`/`finished`
///   are semaphores.
/// - `renderRunLoop`/`stopSource` are written ONCE by the render thread
///   before it signals `started`, and read by `stop()` only after
///   `started.wait()` — the semaphore provides the happens-before edge.
public final class InteractiveSession: @unchecked Sendable {

    // MARK: Public channels (Invariant 13: these are the ONLY ways in/out)

    /// Cross-thread ingress for continuous lane writes (sliders, inputs).
    /// Valid immediately — before `start()`, before the engine exists.
    public let laneMailbox: LaneMailbox
    /// Cross-thread ingress for structural changes, drained at frame start.
    public let commands: CommandMailbox<SessionCommand>
    /// The only egress: latest-frame snapshot, readable from any thread.
    public let snapshots: SnapshotSlot

    // MARK: Configuration (immutable after init)

    private let context: GPUContext
    private let layout: CatalogLayout
    private let layer: CAMetalLayer
    private let signals: SignalTable
    private let initialScene: SceneEnvelope?

    // MARK: Lifecycle state

    private enum Phase {
        case idle, running, stopped
    }

    private let phase = Mutex<Phase>(.idle)
    private let stopRequested = Atomic<Bool>(false)
    private let started = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    /// Written once by the render thread before `started.signal()`; read by
    /// `stop()` after `started.wait()`. See the class audit comment.
    private nonisolated(unsafe) var renderRunLoop: CFRunLoop?
    private nonisolated(unsafe) var stopSource: CFRunLoopSource?

    // MARK: Init

    /// Creatable on any thread. The engine, clock, and binding engine are
    /// deliberately NOT created here — they are render-thread confined and
    /// come to life inside `start()`'s thread (ADR-004).
    public init(
        context: GPUContext,
        layout: CatalogLayout,
        layer: CAMetalLayer,
        signals: SignalTable,
        initialScene: SceneEnvelope?
    ) {
        self.context = context
        self.layout = layout
        self.layer = layer
        self.signals = signals
        self.initialScene = initialScene
        self.laneMailbox = LaneMailbox()
        self.commands = CommandMailbox<SessionCommand>()
        self.snapshots = SnapshotSlot()
        if layer.device == nil {
            layer.device = context.device
        }
    }

    /// The layer contract the session's compute-into-drawable path needs:
    /// `framebufferOnly = false` (the march kernel WRITES the drawable
    /// texture; ADR-001 compute-only) and `.bgra8Unorm`. Call from the thread
    /// that owns the layer, before `start()`.
    public static func configure(layer: CAMetalLayer) {
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
    }

    // MARK: Start / stop

    /// Spawn the dedicated render thread ("threshold.render"). Idempotent:
    /// only the idle→running transition spawns; a stopped session does not
    /// restart (create a new session).
    public func start() {
        let shouldStart = phase.withLock { p -> Bool in
            guard p == .idle else { return false }
            p = .running
            return true
        }
        guard shouldStart else { return }

        let thread = Thread { [self] in
            renderThreadMain()
        }
        thread.name = "threshold.render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Idempotent and joinable: the first call after `start()` blocks until
    /// the render thread has exited; subsequent calls return immediately.
    public func stop() {
        let shouldJoin = phase.withLock { p -> Bool in
            switch p {
            case .idle:
                p = .stopped  // never started; nothing to join
                return false
            case .running:
                p = .stopped
                return true
            case .stopped:
                return false
            }
        }
        guard shouldJoin else { return }

        stopRequested.store(true, ordering: .releasing)
        started.wait()  // render thread has published its run loop
        if let source = stopSource {
            // Signaling a version-0 source stays PENDING even if the loop is
            // between runs — closes the check-then-run race without timers.
            CFRunLoopSourceSignal(source)
        }
        if let runLoop = renderRunLoop {
            CFRunLoopWakeUp(runLoop)
            CFRunLoopStop(runLoop)
        }
        finished.wait()  // join
    }

    // MARK: Render thread

    private func renderThreadMain() {
        // Publish the run-loop handle FIRST so stop() can always reach us,
        // even if GPU setup below fails.
        let runLoop = CFRunLoopGetCurrent()
        renderRunLoop = runLoop

        var sourceContext = CFRunLoopSourceContext()
        sourceContext.perform = { _ in
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        let source = CFRunLoopSourceCreate(nil, 0, &sourceContext)
        if let source {
            CFRunLoopAddSource(runLoop, source, .defaultMode)
        }
        stopSource = source
        started.signal()
        defer { finished.signal() }

        // Render-thread-confined state comes to life HERE (ADR-004): clock,
        // engine (adopting the pre-published lane mailbox), bindings, scene.
        let core = SessionCore(
            layout: layout,
            signals: signals,
            laneMailbox: laneMailbox,
            commands: commands,
            initialScene: initialScene)

        guard let gpu = try? SessionGPUEncoder(context: context) else {
            // No queue/buffers — nothing to render. The session ends; stop()
            // still joins cleanly via the defer.
            return
        }

        // Profiling instrumentation (render-thread confined). Signposts are
        // always on (free when no Instruments tool is attached); the periodic
        // os_log summary is opt-in via THRESHOLD_PROFILE so normal runs stay
        // quiet. See RenderTelemetry.swift.
        let env = ProcessInfo.processInfo.environment
        let profiler = FrameProfiler(
            telemetry: RenderTelemetry(),
            logSummaries: env["THRESHOLD_PROFILE"] != nil,
            filePath: env["THRESHOLD_PROFILE_FILE"])

        let link = CAMetalDisplayLink(metalLayer: layer)
        let proxy = DisplayLinkProxy { [self] update in
            if stopRequested.load(ordering: .acquiring) {
                CFRunLoopStop(CFRunLoopGetCurrent())
                return
            }
            renderFrame(core: core, gpu: gpu, update: update, profiler: profiler)
        }
        link.delegate = proxy
        link.add(to: .current, forMode: .default)

        while !stopRequested.load(ordering: .acquiring) {
            CFRunLoopRun()
        }

        link.invalidate()
        if let source {
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
        }
        withExtendedLifetime(proxy) {}
    }

    /// The thin shell: SessionCore does the frame; this presents it.
    /// Instrumented per phase so Instruments (and the periodic log summary) can
    /// attribute the frame cost: drawable acquisition (where CAMetalDisplayLink
    /// backpressure surfaces), the CPU step, and the encode.
    private func renderFrame(
        core: SessionCore, gpu: SessionGPUEncoder, update: CAMetalDisplayLink.Update,
        profiler: FrameProfiler
    ) {
        let sp = profiler.signposter
        let entry = Mono.now()
        let frameState = sp.beginInterval("frame")

        // Drawable acquisition — a blocking point when the drawable pool is
        // drained (GPU behind), so it is measured separately from encode.
        let drawableStart = Mono.now()
        let drawableState = sp.beginInterval("drawable")
        let drawable = update.drawable
        let texture = drawable.texture
        sp.endInterval("drawable", drawableState)
        let drawableMs = Mono.ms(drawableStart, Mono.now())

        // Previous completed frame's stats — the frame path never waits.
        // Fetched BEFORE the step so the quality governor sees them.
        let stats = gpu.lastCompleted()

        // targetTimestamp is the ONE permitted time source (Invariant 9);
        // the dispatch grid follows the drawable's ACTUAL size each frame.
        let stepStart = Mono.now()
        let stepState = sp.beginInterval("core.step")
        let frame = core.step(
            now: update.targetTimestamp,
            width: texture.width,
            height: texture.height,
            gpuMilliseconds: stats.gpuMilliseconds)
        sp.endInterval("core.step", stepState)
        let stepMs = Mono.ms(stepStart, Mono.now())

        let encodeStart = Mono.now()
        let encodeState = sp.beginInterval("encode")
        // An octave rebase rescales world coordinates between frames, which
        // invalidates the temporal upscaler's reprojection — reset history.
        gpu.encode(frame.request, program: frame.externalProgram, to: drawable,
                   resetHistory: gpu.noteOctave(frame.scaleOctave))
        sp.endInterval("encode", encodeState)
        let encodeMs = Mono.ms(encodeStart, Mono.now())

        snapshots.publish(frame.snapshot(
            gpuMilliseconds: stats.gpuMilliseconds,
            totalSteps: stats.totalSteps))

        sp.endInterval("frame", frameState)
        profiler.record(
            entry: entry, stepMs: stepMs, drawableMs: drawableMs, encodeMs: encodeMs,
            gpuMs: stats.gpuMilliseconds, frameIndex: frame.frameIndex,
            pixels: texture.width * texture.height)
    }
}

// MARK: - DisplayLinkProxy

/// Delegate trampoline so InteractiveSession itself stays NSObject-free.
/// Lives on the render thread for the thread's lifetime.
private final class DisplayLinkProxy: NSObject, CAMetalDisplayLinkDelegate {
    private let onUpdate: (CAMetalDisplayLink.Update) -> Void

    init(onUpdate: @escaping (CAMetalDisplayLink.Update) -> Void) {
        self.onUpdate = onUpdate
    }

    func metalDisplayLink(
        _ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update
    ) {
        onUpdate(update)
    }
}

// MARK: - SessionGPUEncoder

/// Render-thread-confined Metal encoding for the live path. Mirrors
/// OffscreenRenderer's encoding contract but writes the DRAWABLE's texture,
/// presents, and never calls waitUntilCompleted: stats come back through a
/// ring of 3 buffers + completion handlers.
final class SessionGPUEncoder {
    private let context: GPUContext
    private let queue: MTLCommandQueue
    /// Ring of 3: deep enough that the slot being encoded is never the slot
    /// the GPU is executing (drawable backpressure caps frames in flight at
    /// the layer's maximumDrawableCount, default 3). Zeroed by a blit fill at
    /// the head of each command buffer — GPU-queue-ordered, so reuse can
    /// never race the previous frame's atomic adds.
    private let statsRing: [MTLBuffer]
    private var ringCursor = 0
    private let statsSlot = FrameStatsSlot()
    /// Frames-in-flight cap, measured necessary: CAMetalDisplayLink keeps
    /// delivering drawables even when the GPU is frames behind, so without
    /// this the queue grows until makeCommandBuffer blocks at its own limit
    /// (~64) — seconds of present latency and judder on heavy scenes. Depth 3
    /// matches the stats ring and the layer's drawable pool; the wait is the
    /// deliberate pacing point (it shows up as `encode` in the profiler).
    private let inflight = DispatchSemaphore(value: 3)
    /// Direct-call DE pipeline variants (Specialization.swift). `lookup` is
    /// non-blocking: frames render generic until a variant compiles.
    private let specializations: SpecializationCache
    /// MetalFX temporal upscaling — the platform mechanism behind the
    /// governor's renderScale on Mac/iOS (visionOS uses the compositor's
    /// renderQuality instead). nil on devices without MetalFX temporal
    /// support: those render at full resolution and the scale is ignored.
    private let upscaler: TemporalUpscaler?
    /// Halton(2,3) sequence position for the temporal jitter.
    private var jitterIndex: UInt32 = 0
    /// Previous frame's camera — the motion-vector reprojection input.
    private var prevUniforms: ThreshFrameUniforms?
    /// Previous frame's zoom-rebase octave (see noteOctave).
    private var lastOctave: Int32?

    /// Swift mirror of RaymarchCore.metal's ThreshAuxUniforms (private
    /// live-path contract, buffer 7 / textures 1–2 — not ABI).
    private struct AuxUniforms {
        var prevCamPosFov: SIMD4<Float>
        var prevCamQuat: SIMD4<Float>
        var jitter: SIMD4<Float>
    }

    init(context: GPUContext) throws {
        guard let queue = context.device.makeCommandQueue() else {
            throw RenderError.allocationFailed("session command queue")
        }
        queue.label = "threshold.render.queue"
        var ring: [MTLBuffer] = []
        for i in 0..<3 {
            guard let buffer = context.device.makeBuffer(
                length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else {
                throw RenderError.allocationFailed("session stats buffer \(i)")
            }
            buffer.label = "session stats \(i)"
            ring.append(buffer)
        }
        self.context = context
        self.queue = queue
        self.statsRing = ring
        self.specializations = SpecializationCache(context: context)
        // Layer contract is .bgra8Unorm (configure(layer:)) — the scaler's
        // formats are fixed to match. nil = MetalFX temporal unsupported.
        self.upscaler = TemporalUpscaler(
            device: context.device, colorFormat: .bgra8Unorm)
    }

    /// Stats of the most recently COMPLETED frame (zeros until one finishes).
    func lastCompleted() -> FrameStatsSlot.Stats {
        statsSlot.load()
    }

    /// Record this frame's zoom-rebase octave; returns true when it changed
    /// (world coordinates rescaled → temporal history must reset).
    func noteOctave(_ octave: Int32) -> Bool {
        defer { lastOctave = octave }
        return lastOctave != nil && lastOctave != octave
    }

    /// Halton low-discrepancy sequence — the standard temporal-AA jitter
    /// pattern (bases 2 and 3 for x/y).
    private static func halton(_ index: UInt32, base: UInt32) -> Float {
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

    /// Encode one frame into the drawable's texture and present it. A failed
    /// allocation drops the frame (the drawable returns to the pool) — the
    /// live loop must never crash or block. `resetHistory` discards the
    /// temporal upscaler's accumulated frames (octave rebase, camera cut —
    /// anything that invalidates last frame's world coordinates).
    func encode(_ request: RenderRequest, program: ExternalDEProgram? = nil,
                to drawable: CAMetalDrawable, resetHistory: Bool = false) {
        let texture = drawable.texture
        guard texture.width > 0, texture.height > 0,
              request.params.count >= Int(THRESH_SLOT_ENGINE_COUNT),
              Int(request.uniforms.meta.z) <= request.params.count,
              request.uniforms.meta.w < request.uniforms.meta.z,
              Int(request.uniforms.meta.y) < (program?.deFunctionCount ?? context.deFunctionCount)
        else { return }

        var uniforms = request.uniforms
        uniforms.meta.x = UInt32(request.ops.count)  // can never disagree

        guard let paramsBuffer = try? context.makeFloatBuffer(
                  request.params, label: "session param table"),
              let opsBuffer = try? context.makeOpsBuffer(request.ops)
        else { return }

        // Pace the loop to the GPU: block until a frame slot frees. Every
        // path after this point either commits (the completed handler
        // signals) or drops the frame (the defer signals).
        inflight.wait()
        var committed = false
        defer { if !committed { inflight.signal() } }

        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        commandBuffer.label = "session frame"

        let statsBuffer = statsRing[ringCursor]
        ringCursor = (ringCursor + 1) % statsRing.count

        // Zero the step counter on the ring slot's reuse (blit fill: ordered
        // on the queue, no CPU/GPU race).
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "session stats zero"
        blit.fill(buffer: statsBuffer, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
        blit.endEncoding()

        // Render scale (the governor's ONLY lever): march at reduced
        // resolution into the MetalFX pass's inputs, temporal-upscale, copy
        // to the drawable. Any reason it can't engage — external DE (no aux
        // pipeline variant yet), unsupported device, scale out of MetalFX
        // range — falls back to a full-resolution direct render; never a
        // dropped frame.
        let scale = min(max(request.renderScale, 0), 1)
        var fx: TemporalUpscaler.Pass?
        if program == nil, scale < 0.985, let upscaler {
            fx = upscaler.prepare(
                inputWidth: max(Int((Float(texture.width) * scale).rounded()), 1),
                inputHeight: max(Int((Float(texture.height) * scale).rounded()), 1),
                outputWidth: texture.width,
                outputHeight: texture.height)
        }
        let auxOutputs = fx != nil
        let marchTarget = fx?.color ?? texture

        // Built-in DE with no external program active: render through the
        // specialized (direct-call, inlined) variant once it has compiled —
        // the aux (temporal-input) twin when upscaling.
        var specialized: SpecializedMarch?
        if program == nil {
            let deIndex = Int(uniforms.meta.y)
            if DERegistry.builtin.indices.contains(deIndex) {
                specialized = specializations.lookup(
                    deFunctionName: DERegistry.builtin[deIndex].mslFunctionName,
                    auxOutputs: auxOutputs)
            }
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "session march"
        encoder.setComputePipelineState(
            program?.marchPipeline ?? specialized?.pipeline
                ?? (auxOutputs ? context.marchAuxPipeline : context.marchPipeline))
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(
                raw.baseAddress!, length: raw.count, index: Int(THRESH_BUFFER_UNIFORMS))
        }
        encoder.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
        encoder.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
        encoder.setBuffer(statsBuffer, offset: 0, index: Int(THRESH_BUFFER_STATS))
        encoder.setVisibleFunctionTable(
            program?.marchDETable ?? specialized?.deTable
                ?? (auxOutputs ? context.marchAuxDETable : context.marchDETable),
            bufferIndex: GPUContext.deTableBufferIndex)
        let paletteBytes = PaletteWire.bytes(request.palette)
        paletteBytes.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_PALETTE))
        }
        encoder.setTexture(marchTarget, index: Int(THRESH_TEXTURE_OUTPUT))

        // Temporal-input bindings (aux pipeline only): previous camera for
        // motion vectors, this frame's Halton(2,3) sub-pixel jitter, and the
        // depth/motion targets. Private contract with RaymarchCore's
        // THRESH_AUX variant (buffer 7, textures 1–2).
        var jitter = SIMD2<Float>(0, 0)
        if let fx {
            jitterIndex &+= 1
            jitter = SIMD2(Self.halton(jitterIndex, base: 2) - 0.5,
                           Self.halton(jitterIndex, base: 3) - 0.5)
            let prev = prevUniforms ?? uniforms  // first frame: zero motion
            var aux = AuxUniforms(
                prevCamPosFov: prev.camPosFov,
                prevCamQuat: prev.camQuat,
                jitter: SIMD4(jitter.x, jitter.y, 0, 0))
            withUnsafeBytes(of: &aux) { raw in
                encoder.setBytes(raw.baseAddress!, length: raw.count, index: 7)
            }
            encoder.setTexture(fx.depth, index: 1)
            encoder.setTexture(fx.motion, index: 2)
        }

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(
            width: (marchTarget.width + 7) / 8,
            height: (marchTarget.height + 7) / 8,
            depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let fx {
            upscaler?.encode(
                commandBuffer: commandBuffer,
                jitterPixels: jitter,
                forceReset: resetHistory)
            // Same size and format — a plain copy into the drawable.
            guard let copy = commandBuffer.makeBlitCommandEncoder() else { return }
            copy.label = "session fx copy"
            copy.copy(from: fx.output, to: texture)
            copy.endEncoding()
        }
        prevUniforms = request.uniforms

        commandBuffer.present(drawable)

        // AUDIT — nonisolated(unsafe): the completion handler reads the stats
        // buffer only AFTER the command buffer that wrote it completed;
        // MTLBuffer.contents() is a stable pointer and Metal invokes handlers
        // on its own (single) completion thread. The Sendable FrameStatsSlot
        // carries the value out.
        nonisolated(unsafe) let completedStats = statsBuffer
        let slot = statsSlot
        let inflight = inflight
        commandBuffer.addCompletedHandler { completed in
            let steps = UInt64(completedStats.contents().load(as: UInt32.self))
            // Command-buffer GPU timestamps, not ambient time (Invariant 9).
            let ms = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000.0
            slot.store(gpuMilliseconds: ms, totalSteps: steps)
            inflight.signal()
        }
        commandBuffer.commit()
        committed = true
    }
}

#endif  // os(macOS)
