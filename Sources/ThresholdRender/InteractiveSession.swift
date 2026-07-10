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
import os
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
        // BOUNDED waits, both of them: `stop()` typically runs on the main
        // thread, and an unbounded join on a wedged render thread turns a
        // render-side stall into a silent main-thread hang (beachball with no
        // trail). On timeout: say so loudly and abandon the join — the thread
        // closure retains `self`, so bailing leaks the thread, never crashes.
        if started.wait(timeout: .now() + 5) == .timedOut {
            // Also: without the semaphore's happens-before edge the run-loop
            // handles below are unsafe to read, so there is nothing more we
            // can legally do.
            ThresholdLog.session.fault(
                """
                stop(): render thread never signaled start after 5s — it is \
                wedged in setup; abandoning join (thread leaked)
                """)
            return
        }
        if let source = stopSource {
            // Signaling a version-0 source stays PENDING even if the loop is
            // between runs — closes the check-then-run race without timers.
            CFRunLoopSourceSignal(source)
        }
        if let runLoop = renderRunLoop {
            CFRunLoopWakeUp(runLoop)
            CFRunLoopStop(runLoop)
        }
        if finished.wait(timeout: .now() + 5) == .timedOut {  // join
            ThresholdLog.session.fault(
                """
                stop(): render thread did not exit after 5s — likely blocked \
                mid-frame (GPU stall?); abandoning join (thread leaked)
                """)
        } else {
            ThresholdLog.session.notice("render session stopped (joined cleanly)")
        }
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

        let gpu: SessionGPUEncoder
        do {
            gpu = try SessionGPUEncoder(context: context)
        } catch {
            // No queue/buffers — nothing to render. The session ends (the
            // surface stays black); stop() still joins cleanly via the defer.
            ThresholdLog.session.fault(
                """
                render session dead on arrival — GPU encoder init failed: \
                \(String(describing: error), privacy: .public)
                """)
            return
        }

        // Image export (captureImage command): renders the live frame's
        // request offscreen. Render-thread confined like everything else;
        // nil (allocation failure) just means exports never land.
        let exporter: OffscreenRenderer?
        do {
            exporter = try OffscreenRenderer(context: context)
        } catch {
            exporter = nil
            ThresholdLog.session.error(
                """
                export renderer init failed — image captures will never \
                land: \(String(describing: error), privacy: .public)
                """)
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
            renderFrame(
                core: core, gpu: gpu, exporter: exporter, update: update,
                profiler: profiler)
        }
        link.delegate = proxy
        link.add(to: .current, forMode: .default)

        ThresholdLog.session.notice(
            "render session up (device: \(self.context.device.name, privacy: .public))")

        while !stopRequested.load(ordering: .acquiring) {
            CFRunLoopRun()
        }

        ThresholdLog.session.notice("render session exiting (stop requested)")
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
        core: SessionCore, gpu: SessionGPUEncoder, exporter: OffscreenRenderer?,
        update: CAMetalDisplayLink.Update, profiler: FrameProfiler
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

        // Image export: the SAME request the drawable is about to present,
        // re-rendered offscreen at the export size (renderScale 1 — exports
        // never go through the live upscale path). Synchronous on the render
        // thread: one hitch frame per export, by design.
        if let capture = core.takePendingImageCapture() {
            if let exporter {
                var exportRequest = frame.request
                exportRequest.width = capture.width
                exportRequest.height = capture.height
                exportRequest.renderScale = 1
                do {
                    let result = try exporter.render(
                        exportRequest, program: frame.externalProgram)
                    capture.slot.publish(result)
                } catch {
                    let message = "image capture failed (\(capture.width)x\(capture.height)): \(String(describing: error))"
                    capture.slot.publish(failure: message)
                    ThresholdLog.render.error(
                        """
                        \(message, privacy: .public)
                        """)
                }
            } else {
                capture.slot.publish(
                    failure: "image capture failed: export renderer unavailable")
                ThresholdLog.render.error(
                    "image capture requested but the export renderer never initialized")
            }
        }

        let encodeStart = Mono.now()
        let encodeState = sp.beginInterval("encode")
        // An octave rebase rescales world coordinates between frames, which
        // invalidates the temporal upscaler's reprojection — reset history.
        let diagnostics = gpu.encode(
            frame.request, program: frame.externalProgram, to: drawable,
            resetHistory: gpu.noteOctave(frame.scaleOctave))
        sp.endInterval("encode", encodeState)
        let encodeMs = Mono.ms(encodeStart, Mono.now())

        snapshots.publish(frame.snapshot(
            gpuMilliseconds: stats.gpuMilliseconds,
            totalSteps: stats.totalSteps,
            diagnostics: diagnostics))

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
    /// GPU-fault check for every completed command buffer (observability
    /// phase 1) — a faulting GPU must never again freeze the image silently.
    private let health = CommandBufferHealth(shell: "session")
    /// The most recently committed command buffers, parallel to statsRing —
    /// held ONLY so a stall can report what each in-flight frame is doing.
    /// Written on the render thread; `status` reads are thread-safe.
    private var pending: [MTLCommandBuffer?] = [nil, nil, nil]
    /// Consecutive `inflight` timeouts (render-thread confined; resets on
    /// recovery). Rate-limits the stall logging.
    private var stalls: UInt64 = 0
    /// Dropped-frame count (render-thread confined). Every silent early exit
    /// in `encode()` routes through `drop(_:)` so a repeatedly-failing encode
    /// is visible in the log instead of reading as a frozen image.
    private var drops: UInt64 = 0

    /// Count + rate-limit-log one dropped frame (the first few, then every
    /// 60th), and return the value `encode()`'s early exits return.
    private func drop(_ reason: String) -> RenderDiagnostics {
        drops += 1
        if drops <= 5 || drops % 60 == 0 {
            ThresholdLog.render.error(
                "frame dropped (#\(self.drops)): \(reason, privacy: .public)")
        }
        return lastDiagnostics
    }
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
    /// The pipeline choice made last encode — returned on dropped frames so the
    /// diagnostics readout doesn't flicker to a default (render-thread only).
    private var lastDiagnostics = RenderDiagnostics()
    /// Cone-prepass depth textures, one per in-flight frame (ring parallel to
    /// statsRing): frame N+1's prepass must not overwrite the texture frame
    /// N's march is still reading. Rebuilt on size change.
    private var coneRing: [MTLTexture?] = [nil, nil, nil]

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
    @discardableResult
    func encode(_ request: RenderRequest, program: ExternalDEProgram? = nil,
                to drawable: CAMetalDrawable, resetHistory: Bool = false) -> RenderDiagnostics {
        let texture = drawable.texture
        guard texture.width > 0, texture.height > 0 else {
            return drop("zero-size drawable")
        }
        let uniforms: ThreshFrameUniforms
        switch EncodePreamble.validatedUniforms(
            request, deFunctionCount: program?.deFunctionCount ?? context.deFunctionCount) {
        case .success(let u): uniforms = u
        case .failure(let reason):
            return drop("uniform validation failed: \(String(describing: reason))")
        }

        guard let paramsBuffer = try? context.makeFloatBuffer(
                  request.params, label: "session param table"),
              let opsBuffer = try? context.makeOpsBuffer(request.ops)
        else { return drop("param/ops buffer allocation failed") }

        // Pace the loop to the GPU: block until a frame slot frees. BOUNDED —
        // an unbounded wait here is how a GPU fault used to freeze the app
        // with no diagnostics: completion handlers stop firing, the third
        // wait blocks the render thread forever, and Xcode's hang detector
        // (main-thread only) never notices. On timeout, report what each
        // in-flight buffer is doing and drop the frame; the loop stays alive
        // to recover if the GPU does.
        if inflight.wait(timeout: .now() + 1) == .timedOut {
            stalls += 1
            if stalls <= 5 || stalls % 30 == 0 {
                let states = pending.compactMap { $0 }
                    .map { CommandBufferHealth.describe($0.status) }
                    .joined(separator: ", ")
                ThresholdLog.render.fault(
                    """
                    render pipeline stalled (#\(self.stalls)): no command \
                    buffer completed in 1s — dropping frame; in-flight: \
                    [\(states, privacy: .public)]
                    """)
            }
            return lastDiagnostics
        }
        if stalls > 0 {
            ThresholdLog.render.notice(
                "render pipeline recovered after \(self.stalls) dropped frame(s)")
            stalls = 0
        }
        // Every path after this point either commits (the completed handler
        // signals) or drops the frame (the defer signals).
        var committed = false
        defer { if !committed { inflight.signal() } }

        guard let commandBuffer = CommandBufferHealth.makeCommandBuffer(on: queue)
        else { return drop("makeCommandBuffer returned nil") }
        commandBuffer.label = "session frame"

        let statsBuffer = statsRing[ringCursor]
        let pendingSlot = ringCursor
        ringCursor = (ringCursor + 1) % statsRing.count

        // Zero the step counter on the ring slot's reuse (blit fill: ordered
        // on the queue, no CPU/GPU race).
        guard let blit = commandBuffer.makeBlitCommandEncoder()
        else { return drop("stats-zero blit encoder allocation failed") }
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
        var effectiveScale = scale
        if program == nil, scale < 0.985, let upscaler {
            // MetalFX temporal scaling caps at `maxScaleFactor`× per dimension
            // (3×) with a 32px minimum input edge. A request below that floor
            // (Render Quality under ~33%) used to fail `prepare`'s ratio guard
            // and fall through to a FULL-RESOLUTION direct render — spiking GPU
            // cost precisely when the user asked for LESS, which can saturate
            // the GPU and stall the UI. Clamp the march input UP to the
            // smallest MetalFX-supported size instead, so low quality stays
            // cheap and the upscaler keeps engaging rather than disengaging.
            let floor = TemporalUpscaler.minimumInputSize(
                forOutputWidth: texture.width, height: texture.height)
            let inputW = max(Int((Float(texture.width) * scale).rounded()), floor.width)
            let inputH = max(Int((Float(texture.height) * scale).rounded()), floor.height)
            fx = upscaler.prepare(
                inputWidth: inputW,
                inputHeight: inputH,
                outputWidth: texture.width,
                outputHeight: texture.height)
            // Report the scale actually marched (clamped), not the request, so
            // the readout reflects reality instead of an unreachable target.
            if fx != nil { effectiveScale = Float(inputW) / Float(texture.width) }
        }
        let auxOutputs = fx != nil
        let marchTarget = fx?.color ?? texture

        // Built-in DE with no external program active: render through the
        // specialized (direct-call, inlined) variant once it has compiled —
        // the aux (temporal-input) twin when upscaling. Tuning (from the UI /
        // env) can disable specialization for an A/B, or toggle the iteration
        // bake. Every choice is recorded in `diagnostics` for the UI readout.
        var specialized: SpecializedMarch?
        // Effective scale: the governor's requested `scale` only takes effect
        // when MetalFX actually engaged (fx != nil). If temporal upscaling is
        // unsupported on this device, we render full-res regardless — report
        // that honestly (a 100% readout despite a governor request IS the
        // signal that the resolution lever is a no-op here).
        var diagnostics = RenderDiagnostics(
            renderScale: auxOutputs ? effectiveScale : 1, upscaling: auxOutputs)
        if program != nil {
            diagnostics.pipeline = .external
        } else {
            let deIndex = Int(uniforms.meta.y)
            // Bake the function-constant knobs the tuning enables. Every baked
            // value IS the value the shader would read at runtime, so the image
            // is unchanged (SpecializationTests).
            if let plan = EncodePreamble.specializationPlan(for: request, deIndex: deIndex) {
                specialized = specializations.lookup(
                    deFunctionName: plan.deFunctionName,
                    spec: plan.spec, auxOutputs: auxOutputs)
                if specialized != nil {
                    diagnostics.pipeline = auxOutputs ? .specializedAux : .specialized
                    diagnostics.bakedConstants = plan.spec.summary
                } else {
                    // Distinguish a live background compile from a terminal
                    // negative-cache entry. The generic pipeline renders in
                    // both cases; the UI must not say "Compiling…" forever.
                    diagnostics.specializationFailed = specializations.failureDescription(
                        deFunctionName: plan.deFunctionName,
                        spec: plan.spec, auxOutputs: auxOutputs) != nil
                    diagnostics.specializationPending = !diagnostics.specializationFailed
                    diagnostics.pipeline = auxOutputs ? .genericAux : .generic
                }
            } else {
                diagnostics.pipeline = auxOutputs ? .genericAux : .generic
            }
        }
        // Pipeline transitions are rare and load-bearing (specialized variant
        // landed, external DE engaged, MetalFX toggled) — one breadcrumb each.
        if diagnostics.pipeline != lastDiagnostics.pipeline {
            let baked = diagnostics.bakedConstants.isEmpty
                ? "" : " [\(diagnostics.bakedConstants)]"
            ThresholdLog.render.info(
                """
                pipeline: \(self.lastDiagnostics.pipeline.rawValue, privacy: .public) \
                → \(diagnostics.pipeline.rawValue, privacy: .public)\(baked, privacy: .public)
                """)
        }
        lastDiagnostics = diagnostics

        // Hierarchical cone prepass (perf block 9, ported from the offscreen
        // path): one thread per 8×8 tile of the MARCH TARGET (the reduced-
        // resolution texture when MetalFX is engaged) finds the tile's safe
        // start depth. Ring slot matches the stats ring so in-flight frames
        // never share a texture.
        var coneTexture: MTLTexture? = nil
        if program == nil, let prepass = specialized?.conePrepass {
            let tile = 8   // MUST match THRESH_CONE_TILE in RaymarchCore.metal
            let cw = (marchTarget.width + tile - 1) / tile
            let ch = (marchTarget.height + tile - 1) / tile
            let slot = (ringCursor + statsRing.count - 1) % statsRing.count
            var coneTex = coneRing[slot]
            if coneTex == nil || coneTex!.width != cw || coneTex!.height != ch {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r32Float, width: cw, height: ch, mipmapped: false)
                desc.usage = [.shaderWrite, .shaderRead]
                desc.storageMode = .private
                coneTex = context.device.makeTexture(descriptor: desc)
                coneRing[slot] = coneTex
            }
            if let coneTex,
               let pre = commandBuffer.makeComputeCommandEncoder() {
                pre.label = "session cone prepass"
                pre.setComputePipelineState(prepass)
                withUnsafeBytes(of: uniforms) { raw in
                    pre.setBytes(raw.baseAddress!, length: raw.count,
                                 index: Int(THRESH_BUFFER_UNIFORMS))
                }
                pre.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
                pre.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
                if let table = specialized?.deTable {
                    pre.setVisibleFunctionTable(
                        table, bufferIndex: GPUContext.deTableBufferIndex)
                }
                var dims = SIMD2<UInt32>(UInt32(marchTarget.width),
                                         UInt32(marchTarget.height))
                withUnsafeBytes(of: &dims) { raw in
                    pre.setBytes(raw.baseAddress!, length: raw.count, index: 8)
                }
                pre.setTexture(coneTex, index: 3)
                pre.dispatchThreadgroups(
                    MTLSize(width: (cw + 7) / 8, height: (ch + 7) / 8, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                pre.endEncoding()
                coneTexture = coneTex
            }
        }

        // A cone-baked pipeline REQUIRES texture 3 (THRESH_CONE gates the
        // argument in): if the prepass could not run (texture/encoder alloc
        // failure), render generic this frame instead of tripping validation.
        if program == nil, specialized?.conePrepass != nil, coneTexture == nil {
            specialized = nil
            diagnostics.pipeline = auxOutputs ? .genericAux : .generic
            lastDiagnostics = diagnostics
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return drop("march encoder allocation failed") }
        encoder.label = "session march"
        // SYNC-POINT: render binding contract — same buffer indices / palette
        // layout / pipeline precedence as OffscreenRenderer and ViewPassEncoder,
        // plus the aux (temporal-upscale input) pipeline twin unique to this
        // shell. Indices and precedence must match across all three.
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
        if let table = program?.marchDETable ?? specialized?.deTable
            ?? (auxOutputs ? context.marchAuxDETable : context.marchDETable) {
            encoder.setVisibleFunctionTable(
                table, bufferIndex: GPUContext.deTableBufferIndex)
        }
        let paletteBytes = PaletteWire.bytes(request.palette)
        paletteBytes.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count,
                             index: Int(THRESH_BUFFER_PALETTE))
        }
        encoder.setTexture(marchTarget, index: Int(THRESH_TEXTURE_OUTPUT))
        if let coneTexture {
            encoder.setTexture(coneTexture, index: 3)
        }

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
            guard let copy = commandBuffer.makeBlitCommandEncoder()
            else { return drop("MetalFX copy encoder allocation failed") }
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
        let health = health
        commandBuffer.addCompletedHandler { completed in
            health.check(completed)
            let steps = UInt64(completedStats.contents().load(as: UInt32.self))
            // Command-buffer GPU timestamps, not ambient time (Invariant 9).
            let ms = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000.0
            slot.store(gpuMilliseconds: ms, totalSteps: steps)
            inflight.signal()
        }
        commandBuffer.commit()
        committed = true
        pending[pendingSlot] = commandBuffer
        return lastDiagnostics
    }
}

#endif  // os(macOS)
