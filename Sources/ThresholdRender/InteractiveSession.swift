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
            gpuMilliseconds: stats.governorMilliseconds)
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
        let diagnostics = gpu.encode(
            frame.request, program: frame.externalProgram, to: drawable)
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
    /// One-shot ownership of an in-flight semaphore release. Metal normally
    /// settles it from the completion callback; the render thread may settle
    /// it first when `status` is already terminal but callback delivery is
    /// delayed. The CAS prevents a later callback from double-signalling or
    /// reading a stats ring slot after the render thread has reclaimed it.
    private final class CompletionPermit: Sendable {
        private let claimed = Atomic<Bool>(false)
        private let semaphore: DispatchSemaphore

        init(semaphore: DispatchSemaphore) { self.semaphore = semaphore }

        func claim() -> Bool {
            claimed.compareExchange(
                expected: false, desired: true,
                successOrdering: .acquiringAndReleasing,
                failureOrdering: .relaxed).exchanged
        }

        func signal() { semaphore.signal() }
    }

    private struct PendingFrame {
        let commandBuffer: MTLCommandBuffer
        let permit: CompletionPermit
        let queueGeneration: UInt64
    }

    private final class QueueFaultState: Sendable {
        let faulted = Atomic<Bool>(false)
        let activeGeneration = Atomic<UInt64>(0)
    }

    private let context: GPUContext
    private var queue: MTLCommandQueue
    /// A GPU timeout poisons its command queue: subsequent submissions finish
    /// immediately with `.submissionsIgnored`. Completion handlers publish the
    /// fault; the render thread replaces the queue before encoding again.
    private let queueFaultState = QueueFaultState()
    private var queueGeneration: UInt64 = 0
    /// Quantize the continuous quality governor so reduced-resolution texture
    /// allocations change at bounded intervals rather than every frame.
    private static let spatialScaleBuckets: Float = 16
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
    /// matches the stats ring and the layer's drawable pool; a full set drops
    /// the presentation immediately so pacing never blocks the display link.
    private let inflight = DispatchSemaphore(value: 3)
    /// GPU-fault check for every completed command buffer (observability
    /// phase 1) — a faulting GPU must never again freeze the image silently.
    private let health = CommandBufferHealth(shell: "session")
    /// The most recently committed command buffers, parallel to statsRing —
    /// held ONLY so a stall can report what each in-flight frame is doing.
    /// Written on the render thread; `status` reads are thread-safe.
    private var pending: [PendingFrame?] = [nil, nil, nil]

    private func reclaimCompletedPermits() -> Int {
        var recovered = 0
        for (index, pendingFrame) in pending.enumerated() {
            guard let frame = pendingFrame else { continue }
            let status = frame.commandBuffer.status
            guard status == .completed || status == .error else { continue }
            guard frame.permit.claim() else { continue }

            // The winning claimant must publish the measurement too; otherwise
            // delayed callbacks leave the governor blind while permits recover.
            if status == .completed {
                let steps = UInt64(statsRing[index].contents().load(as: UInt32.self))
                let ms = max(0, frame.commandBuffer.gpuEndTime - frame.commandBuffer.gpuStartTime) * 1000
                statsSlot.store(gpuMilliseconds: ms, totalSteps: steps)
            }
            frame.permit.signal()
            health.check(frame.commandBuffer)
            if status == .error,
               queueFaultState.activeGeneration.load(ordering: .acquiring)
                    == frame.queueGeneration {
                queueFaultState.faulted.store(true, ordering: .releasing)
            }
            recovered += 1
        }
        return recovered
    }

    /// Replace a command queue after Metal reports a terminal GPU error.
    /// Returns false only if the device cannot create a recovery queue.
    private func recoverFaultedQueueIfNeeded() -> Bool {
        let claimed = queueFaultState.faulted.compareExchange(
            expected: true, desired: false,
            successOrdering: .acquiringAndReleasing,
            failureOrdering: .relaxed).exchanged
        guard claimed else { return true }
        guard let replacement = context.device.makeCommandQueue() else {
            queueFaultState.faulted.store(true, ordering: .releasing)
            return false
        }

        queueGeneration &+= 1
        queueFaultState.activeGeneration.store(
            queueGeneration, ordering: .releasing)
        // No old-generation completion can re-arm the latch after this store.
        queueFaultState.faulted.store(false, ordering: .releasing)
        replacement.label = "threshold.render.queue.recovery.\(queueGeneration)"
        queue = replacement
        ThresholdLog.render.fault(
            "GPU queue recovered after command-buffer failure")
        return true
    }

    /// Consecutive frames dropped for GPU backpressure (render-thread
    /// confined; resets on recovery). Rate-limits the stall logging.
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
    /// Ordered full-frame effects, applied after spatial upscaling so radii are
    /// expressed in presentation pixels and never feed temporal history.
    private let postProcessor: PostProcessor
    /// The pipeline choice made last encode — returned on dropped frames so the
    /// diagnostics readout doesn't flicker to a default (render-thread only).
    private var lastDiagnostics = RenderDiagnostics()
    /// Cone-prepass depth textures, one per in-flight frame (ring parallel to
    /// statsRing): frame N+1's prepass must not overwrite the texture frame
    /// N's march is still reading. Rebuilt on size change.
    private var coneRing: [MTLTexture?] = [nil, nil, nil]

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
        self.postProcessor = try PostProcessor(context: context)
    }

    /// Stats of the most recently COMPLETED frame (zeros until one finishes).
    func lastCompleted() -> FrameStatsSlot.Stats {
        statsSlot.loadForControl()
    }

    /// Encode one frame into the drawable's texture and present it. A failed
    /// allocation drops the frame (the drawable returns to the pool) — the
    /// live loop must never crash or block.
    @discardableResult
    func encode(_ request: RenderRequest, program: ExternalDEProgram? = nil,
                to drawable: CAMetalDrawable) -> RenderDiagnostics {
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

        // Pace the loop to the GPU without EVER blocking the display-link
        // callback. A Metal timeout takes roughly four seconds to surface;
        // even a bounded one-second wait therefore made the app visibly hang
        // four times before the driver finally returned an error. Keep the UI
        // and session clock live by dropping this presentation immediately.
        let recoveredBeforeWait = reclaimCompletedPermits()
        if recoveredBeforeWait > 0 {
            ThresholdLog.render.notice(
                "reclaimed \(recoveredBeforeWait) completed frame permit(s) before acquire")
        }
        guard recoverFaultedQueueIfNeeded() else {
            return drop("GPU queue recovery allocation failed")
        }

        let acquiredPermit = inflight.wait(timeout: .now()) == .success
        if !acquiredPermit {
            stalls += 1
            if stalls == 1 || stalls % 120 == 0 {
                let states = pending.compactMap { $0 }
                    .map { CommandBufferHealth.describe($0.commandBuffer.status) }
                    .joined(separator: ", ")
                ThresholdLog.render.fault(
                    """
                    GPU backpressure (#\(self.stalls)): dropping without \
                    blocking; in-flight: \
                    [\(states, privacy: .public)]
                    """)
            }
            return lastDiagnostics
        }
        if stalls > 0 {
            ThresholdLog.render.notice(
                "GPU pipeline resumed after \(self.stalls) non-blocking drop(s)")
            stalls = 0
        }
        // Every path after this point either commits (the completed handler
        // signals) or drops the frame (the defer signals).
        var committed = false
        defer { if !committed { inflight.signal() } }

        guard let paramsBuffer = try? context.makeFloatBuffer(
                  request.params, label: "session param table"),
              let opsBuffer = try? context.makeOpsBuffer(request.ops)
        else { return drop("param/ops buffer allocation failed") }

        guard let commandBuffer = CommandBufferHealth.makeCommandBuffer(on: queue)
        else { return drop("makeCommandBuffer returned nil") }
        commandBuffer.label = "session frame"

        let statsBuffer = statsRing[ringCursor]
        let pendingSlot = ringCursor
        // ringCursor advances only after commit (below): a dropped frame must
        // not skip a slot, or the next frame could reuse an in-flight one.

        // Zero the step counter on the ring slot's reuse (blit fill: ordered
        // on the queue, no CPU/GPU race).
        guard let blit = commandBuffer.makeBlitCommandEncoder()
        else { return drop("stats-zero blit encoder allocation failed") }
        blit.label = "session stats zero"
        blit.fill(buffer: statsBuffer, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
        blit.endEncoding()

        // Render scale (the governor's ONLY lever): march into a conventional
        // reduced-resolution 2D texture, then bilinear-upscale with a small
        // Metal compute pass. This is intentionally stateless and stays on the
        // same GPU command queue: the former MetalFX temporal scaler could
        // wedge its cross-engine work while the rest of the UI stayed alive.
        // Allocation failure falls back to a full-resolution direct render.
        let scale = min(max(request.renderScale, 0), 1)
        var spatialPass: PostProcessor.SpatialPass?
        var effectiveScale: Float = 1
        if scale < 0.985 {
            let bucketedScale = max(
                1 / Self.spatialScaleBuckets,
                (scale * Self.spatialScaleBuckets).rounded()
                    / Self.spatialScaleBuckets)
            let inputW = min(
                texture.width,
                max(32, Int((Float(texture.width) * bucketedScale).rounded())))
            let inputH = min(
                texture.height,
                max(32, Int((Float(texture.height) * bucketedScale).rounded())))
            if inputW < texture.width || inputH < texture.height {
                do {
                    spatialPass = try postProcessor.prepareSpatialPass(
                        inputWidth: inputW,
                        inputHeight: inputH,
                        matching: texture,
                        inFlightSlot: pendingSlot)
                    effectiveScale = Float(inputW) / Float(texture.width)
                } catch {
                    ThresholdLog.render.error(
                        "spatial upscale allocation failed; rendering full resolution: \(String(describing: error), privacy: .public)")
                }
            }
        }
        let spatialUpscaling = spatialPass != nil
        let marchTarget = spatialPass?.input ?? texture

        // Built-in DE with no external program active: render through the
        // specialized (direct-call, inlined) variant once it has compiled.
        // Spatial scaling needs color only, so the normal pipeline works for
        // both built-in and external DE programs.
        var specialized: SpecializedMarch?
        var diagnostics = RenderDiagnostics(
            renderScale: effectiveScale, upscaling: spatialUpscaling)
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
                    spec: plan.spec, auxOutputs: false)
                if specialized != nil {
                    diagnostics.pipeline = .specialized
                    diagnostics.bakedConstants = plan.spec.summary
                } else {
                    // Distinguish a live background compile from a terminal
                    // negative-cache entry. The generic pipeline renders in
                    // both cases; the UI must not say "Compiling…" forever.
                    diagnostics.specializationFailed = specializations.failureDescription(
                        deFunctionName: plan.deFunctionName,
                        spec: plan.spec, auxOutputs: false) != nil
                    diagnostics.specializationPending = !diagnostics.specializationFailed
                    diagnostics.pipeline = .generic
                }
            } else {
                diagnostics.pipeline = .generic
            }
        }
        // Pipeline transitions are rare and load-bearing (specialized variant
        // landed or external DE engaged) — one breadcrumb each.
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
        // resolution texture when spatial scaling is engaged) finds the tile's safe
        // start depth. Ring slot matches the stats ring so in-flight frames
        // never share a texture.
        var coneTexture: MTLTexture? = nil
        if program == nil, let prepass = specialized?.conePrepass {
            let tile = 8   // MUST match THRESH_CONE_TILE in RaymarchCore.metal
            let cw = (marchTarget.width + tile - 1) / tile
            let ch = (marchTarget.height + tile - 1) / tile
            let slot = pendingSlot
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
            diagnostics.pipeline = .generic
            lastDiagnostics = diagnostics
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return drop("march encoder allocation failed") }
        encoder.label = "session march"
        // SYNC-POINT: render binding contract — same buffer indices, palette
        // layout, and pipeline precedence as OffscreenRenderer and
        // ViewPassEncoder. Indices and precedence must match across all three.
        encoder.setComputePipelineState(
            program?.marchPipeline ?? specialized?.pipeline
                ?? context.marchPipeline)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(
                raw.baseAddress!, length: raw.count, index: Int(THRESH_BUFFER_UNIFORMS))
        }
        encoder.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
        encoder.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
        encoder.setBuffer(statsBuffer, offset: 0, index: Int(THRESH_BUFFER_STATS))
        if let table = program?.marchDETable ?? specialized?.deTable
            ?? context.marchDETable {
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

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(
            width: (marchTarget.width + 7) / 8,
            height: (marchTarget.height + 7) / 8,
            depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        var postSource = texture
        if let spatialPass {
            do {
                try postProcessor.encodeSpatial(
                    commandBuffer: commandBuffer, pass: spatialPass)
                postSource = spatialPass.output
            } catch {
                return drop("spatial upscale encode failed: \(String(describing: error))")
            }
        }
        do {
            try postProcessor.encode(
                commandBuffer: commandBuffer,
                source: postSource,
                destination: texture,
                stack: request.postProcessStack,
                time: uniforms.scaleCtx.x,
                inFlightSlot: pendingSlot)
        } catch {
            return drop("post-processing encode failed: \(String(describing: error))")
        }
        commandBuffer.present(drawable)

        // AUDIT — nonisolated(unsafe): the completion handler reads the stats
        // buffer only AFTER the command buffer that wrote it completed;
        // MTLBuffer.contents() is a stable pointer and Metal invokes handlers
        // on its own (single) completion thread. The Sendable FrameStatsSlot
        // carries the value out.
        nonisolated(unsafe) let completedStats = statsBuffer
        let slot = statsSlot
        let health = health
        let permit = CompletionPermit(semaphore: inflight)
        let committedGeneration = queueGeneration
        let faultState = queueFaultState
        commandBuffer.addCompletedHandler { completed in
            // Publish queue poison even when the render thread already
            // reclaimed this permit from a terminal status. The generation
            // check prevents late callbacks from an abandoned queue from
            // poisoning its replacement.
            if completed.status == .error,
               faultState.activeGeneration.load(ordering: .acquiring)
                    == committedGeneration {
                faultState.faulted.store(true, ordering: .releasing)
            }
            guard permit.claim() else { return }
            // Copy everything backed by this ring slot BEFORE releasing it:
            // the render thread may immediately acquire the permit and reuse
            // the buffer. Release as soon as those copies are safe, though —
            // health/error inspection and the mutex-backed stats publication
            // are observability work and must never hold frame pacing hostage.
            // A delayed completion callback previously produced one-second
            // encode stalls even while Metal already reported this buffer as
            // `.completed`.
            let steps = UInt64(completedStats.contents().load(as: UInt32.self))
            // Command-buffer GPU timestamps, not ambient time (Invariant 9).
            let ms = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000.0
            permit.signal()
            if completed.status == .completed {
                slot.store(gpuMilliseconds: ms, totalSteps: steps)
            }
            health.check(completed)
        }
        commandBuffer.commit()
        committed = true
        ringCursor = (ringCursor + 1) % statsRing.count
        pending[pendingSlot] = PendingFrame(
            commandBuffer: commandBuffer, permit: permit,
            queueGeneration: committedGeneration)
        return lastDiagnostics
    }
}

#endif  // os(macOS)
