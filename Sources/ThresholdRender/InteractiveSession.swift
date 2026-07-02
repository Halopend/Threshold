// InteractiveSession.swift — the live counterpart of the offscreen harness
// (ARCHITECTURE.md §2, ADR-004): a DEDICATED render thread (not an actor)
// driven by CAMetalDisplayLink, reached only through the lane mailbox and the
// command mailbox, with egress only via the SnapshotSlot (Invariant 13 — no
// third channel).
//
// The display-link callback is a thin shell over SessionCore.step(now:) —
// the same per-frame body tests drive manually against OffscreenRenderer.
//
// macOS-only for now: the display-link plumbing is gated below; iPadOS uses
// the same CAMetalDisplayLink API and visionOS uses the Compositor frame loop
// (both later phases).

#if os(macOS)

import Foundation
import Metal
import QuartzCore
import Synchronization
import ThresholdCore
import ThresholdShaderABI

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

        let link = CAMetalDisplayLink(metalLayer: layer)
        let proxy = DisplayLinkProxy { [self] update in
            if stopRequested.load(ordering: .acquiring) {
                CFRunLoopStop(CFRunLoopGetCurrent())
                return
            }
            renderFrame(core: core, gpu: gpu, update: update)
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
    private func renderFrame(
        core: SessionCore, gpu: SessionGPUEncoder, update: CAMetalDisplayLink.Update
    ) {
        let drawable = update.drawable
        let texture = drawable.texture
        // targetTimestamp is the ONE permitted time source (Invariant 9);
        // the dispatch grid follows the drawable's ACTUAL size each frame.
        let frame = core.step(
            now: update.targetTimestamp,
            width: texture.width,
            height: texture.height)
        // Previous completed frame's stats — the frame path never waits.
        let stats = gpu.lastCompleted()
        gpu.encode(frame.request, to: drawable)
        snapshots.publish(frame.snapshot(
            gpuMilliseconds: stats.gpuMilliseconds,
            totalSteps: stats.totalSteps))
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

// MARK: - FrameStatsSlot

/// Latest completed-frame GPU stats. Compiler-checked Sendable (a Mutex over
/// a POD) — written by Metal's completion-handler thread, read by the render
/// thread at frame start.
final class FrameStatsSlot: Sendable {
    struct Stats: Sendable {
        var gpuMilliseconds: Double = 0
        var totalSteps: UInt64 = 0
    }

    private let slot = Mutex<Stats>(Stats())

    func store(gpuMilliseconds: Double, totalSteps: UInt64) {
        slot.withLock {
            $0 = Stats(gpuMilliseconds: gpuMilliseconds, totalSteps: totalSteps)
        }
    }

    func load() -> Stats {
        slot.withLock { $0 }
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
    }

    /// Stats of the most recently COMPLETED frame (zeros until one finishes).
    func lastCompleted() -> FrameStatsSlot.Stats {
        statsSlot.load()
    }

    /// Encode one frame into the drawable's texture and present it. A failed
    /// allocation drops the frame (the drawable returns to the pool) — the
    /// live loop must never crash or block.
    func encode(_ request: RenderRequest, to drawable: CAMetalDrawable) {
        let texture = drawable.texture
        guard texture.width > 0, texture.height > 0,
              request.params.count >= Int(THRESH_SLOT_ENGINE_COUNT),
              Int(request.uniforms.meta.z) <= request.params.count,
              request.uniforms.meta.w < request.uniforms.meta.z,
              Int(request.uniforms.meta.y) < context.deFunctionCount
        else { return }

        var uniforms = request.uniforms
        uniforms.meta.x = UInt32(request.ops.count)  // can never disagree

        guard let paramsBuffer = try? context.makeFloatBuffer(
                  request.params, label: "session param table"),
              let opsBuffer = try? context.makeOpsBuffer(request.ops),
              let commandBuffer = queue.makeCommandBuffer()
        else { return }
        commandBuffer.label = "session frame"

        let statsBuffer = statsRing[ringCursor]
        ringCursor = (ringCursor + 1) % statsRing.count

        // Zero the step counter on the ring slot's reuse (blit fill: ordered
        // on the queue, no CPU/GPU race).
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "session stats zero"
        blit.fill(buffer: statsBuffer, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
        blit.endEncoding()

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "session march"
        encoder.setComputePipelineState(context.marchPipeline)
        withUnsafeBytes(of: uniforms) { raw in
            encoder.setBytes(
                raw.baseAddress!, length: raw.count, index: Int(THRESH_BUFFER_UNIFORMS))
        }
        encoder.setBuffer(paramsBuffer, offset: 0, index: Int(THRESH_BUFFER_PARAMS))
        encoder.setBuffer(opsBuffer, offset: 0, index: Int(THRESH_BUFFER_WARP_OPS))
        encoder.setBuffer(statsBuffer, offset: 0, index: Int(THRESH_BUFFER_STATS))
        encoder.setVisibleFunctionTable(
            context.marchDETable, bufferIndex: GPUContext.deTableBufferIndex)
        encoder.setTexture(texture, index: Int(THRESH_TEXTURE_OUTPUT))

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(
            width: (texture.width + 7) / 8,
            height: (texture.height + 7) / 8,
            depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.present(drawable)

        // AUDIT — nonisolated(unsafe): the completion handler reads the stats
        // buffer only AFTER the command buffer that wrote it completed;
        // MTLBuffer.contents() is a stable pointer and Metal invokes handlers
        // on its own (single) completion thread. The Sendable FrameStatsSlot
        // carries the value out.
        nonisolated(unsafe) let completedStats = statsBuffer
        let slot = statsSlot
        commandBuffer.addCompletedHandler { completed in
            let steps = UInt64(completedStats.contents().load(as: UInt32.self))
            // Command-buffer GPU timestamps, not ambient time (Invariant 9).
            let ms = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000.0
            slot.store(gpuMilliseconds: ms, totalSteps: steps)
        }
        commandBuffer.commit()
    }
}

#endif  // os(macOS)
