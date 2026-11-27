// CompositorSession.swift — the visionOS Compositor Services shell
// (plan §6.4, ADR-001): a DEDICATED render thread driving the LayerRenderer
// frame loop, reached only through the lane mailbox and the command mailbox,
// with egress only via the SnapshotSlot — the same channel contract as
// InteractiveSession (Invariant 13), and the same per-frame body
// (SessionCore.step) tests drive against OffscreenRenderer.
//
// Spike decisions (documented for the compute-path phase 2):
// - RASTER path, not compute: the fragment shell reuses the original app's
//   proven Compositor mechanics — layered layout + vertex amplification,
//   foveation rate maps (free on raster; the interpolated NDC varying keeps
//   rays correct), and native [[depth]] writes for reprojection. ADR-001's
//   open compute questions (rate-map sampling from compute, drawable
//   compute-writes) stay open; the feature table tracks both paths.
// - Full immersion only; the progressive-immersion portal pass (drawable
//   render context + stencil mask) is a follow-up slot.
// - External DEs: both backends dispatch an active external DE through the
//   program's own lazily-built variant pipelines (ExternalDE.swift) — no
//   cone prepass/specialization for external content, same as the
//   interactive compute path. A variant-construction failure keeps the
//   standing drop-frame behavior.

#if os(visionOS)

import ARKit
import CompositorServices
import Foundation
import Metal
import os
import SwiftUI
import Synchronization
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR

/// Explicit ownership transfer for the SDK's non-Sendable LayerRenderer.
/// The reference is immutable; `CompositorSession.start` creates this box and
/// the dedicated compositor thread is the only code that dereferences it.
/// This is narrower than marking the whole imported framework preconcurrency.
private final class LayerRendererTransfer: @unchecked Sendable {
    let renderer: LayerRenderer

    init(_ renderer: LayerRenderer) {
        self.renderer = renderer
    }
}

/// AUDIT — `@unchecked Sendable`, same precedent as InteractiveSession:
/// mailboxes/snapshot slot are compiler-checked Sendable; `context`, `layout`,
/// `signals`, `initialScene` are Sendable `let`s; `stopRequested` is an
/// Atomic; `phase` is a Mutex and `finished` a semaphore; `onFrame` is written
/// before `start(_:)` (documented contract) and read only by the render thread.
public final class CompositorSession: @unchecked Sendable {

    // MARK: Channels (Invariant 13)

    public let laneMailbox: LaneMailbox
    public let commands: CommandMailbox<SessionCommand>
    public let snapshots: SnapshotSlot

    /// World grab (WorldGrab.swift): system-pinch move/turn/scale of the
    /// fractal in room space. Fed by the layer's spatial-event channel,
    /// read once per frame by the render loop — not a fourth channel: input
    /// only, egress still flows through the snapshot.
    public let worldGrab = WorldGrabSession()

    // MARK: Configuration

    private let context: GPUContext
    private let layout: CatalogLayout
    private let signals: SignalTable
    private let initialScene: SceneEnvelope?
    private let stopRequested = Atomic<Bool>(false)

    // MARK: Lifecycle state (joinable teardown — parity with InteractiveSession)

    private let phase = Mutex(CompositorSessionLifecycle())
    // Accessed only by successive, non-overlapping render loops. Preserve the
    // scene, parameter lanes, animation and bindings across immersive layers.
    private var retainedCore: SessionCore?
    /// Called on the render thread after a layer exits. Set before start;
    /// UI clients must hop to MainActor. A natural exit permits reopening.
    public var onRenderLoopEnded: (@Sendable () -> Void)?
    /// Signaled by the render loop on EVERY exit path (`defer` at loop entry),
    /// so `stop()` can join it. Bounded wait — the loop may be parked in
    /// `waitUntilRunning()` / `Clock().wait(until:)` when the stop lands and
    /// won't notice `stopRequested` until it returns.
    private let finished = DispatchSemaphore(value: 0)

    /// Per-frame input hook, called on the render thread with the frame's
    /// SESSION-clock time right before the step — the seam through which the
    /// hand tracker publishes signals + gesture-lane writes without this
    /// module depending on ThresholdInputs. Set before `start(_:)`.
    public var onFrame: (@Sendable (Double) -> Void)?

    public init(
        context: GPUContext,
        layout: CatalogLayout,
        signals: SignalTable,
        initialScene: SceneEnvelope?
    ) {
        self.context = context
        self.layout = layout
        self.signals = signals
        self.initialScene = initialScene
        self.laneMailbox = LaneMailbox()
        self.commands = CommandMailbox<SessionCommand>()
        self.snapshots = SnapshotSlot()
    }

    /// Rendering backend for the compositor shell (ADR-001 compute phase 2,
    /// perf block 13). Chosen at LAYER CONFIGURATION time (not live): the
    /// compute backend cannot consume rasterization rate maps, so foveation
    /// must be decided before the layer exists. Persisted in UserDefaults —
    /// the Settings picker writes it; it applies the next time the immersive
    /// space opens.
    public enum RenderBackend: String, Sendable, CaseIterable {
        /// Stereo raster fragment path — foveated, the shipping default.
        case fragment
        /// Per-view compute march into intermediates + blit — EXPERIMENTAL:
        /// no foveation, two extra copies; exists to A/B on device whether
        /// compute-coherent marching beats foveated rasterization.
        case compute

        public var label: String {
            switch self {
            case .fragment: return "Fragment (Foveated)"
            case .compute: return "Compute (Experimental)"
            }
        }
    }

    /// UserDefaults key for the backend choice (read at layer configuration
    /// and at render-loop start — the two must agree, hence one source).
    public static let renderBackendKey = "threshold.render.backend"

    /// The persisted backend choice (default: fragment).
    public static var selectedBackend: RenderBackend {
        UserDefaults.standard.string(forKey: renderBackendKey)
            .flatMap(RenderBackend.init(rawValue:)) ?? .fragment
    }

    /// UserDefaults key for the temporal-reconstruction mode on the compute
    /// backend ("off" | "stabilize" | "taau"; default off). `THRESHOLD_RECON`
    /// overrides it for dev/bench runs. Read at render-loop start — flipping
    /// it applies the next time the immersive space opens, same contract as
    /// the backend picker.
    public static let reconstructionKey = "threshold.render.reconstruction"

    /// Temporal-reconstruction mode, the UI-facing mirror of the internal
    /// `TemporalReconstructor.Mode` (raw values match the UserDefaults /
    /// `THRESHOLD_RECON` strings). Compute backend only — the fragment path's
    /// rate-map-warped space can't host per-pixel reprojection.
    public enum Reconstruction: String, Sendable, CaseIterable {
        /// Phase-0 present only: spatial upsample + sharpen, no history.
        case off
        /// Accumulate at MARCH resolution — steadies the image at the same
        /// sharpness (the conservative choice).
        case stabilize
        /// Accumulate at OUTPUT resolution — jittered samples recover real
        /// sub-pixel detail at low march scales (the ambitious choice).
        case taau

        public var label: String {
            switch self {
            case .off: return "Off"
            case .stabilize: return "Stabilize"
            case .taau: return "TAAU"
            }
        }
    }

    /// The persisted reconstruction choice (default: off). The render loop
    /// arms it at start; `THRESHOLD_RECON` overrides for dev/bench runs.
    public static var selectedReconstruction: Reconstruction {
        UserDefaults.standard.string(forKey: reconstructionKey)
            .flatMap(Reconstruction.init(rawValue:)) ?? .off
    }

    /// The reconstruction mode the next render loop will arm.
    static var reconstructionMode: TemporalReconstructor.Mode {
        if let env = ProcessInfo.processInfo.environment["THRESHOLD_RECON"],
           let mode = TemporalReconstructor.Mode(rawValue: env) {
            return mode
        }
        return TemporalReconstructor.Mode(
            rawValue: selectedReconstruction.rawValue) ?? .off
    }

    /// UserDefaults key for temporal seeding (phase A2) on the reconstruction
    /// path — default ON (it only ever engages inside an armed temporal
    /// mode). `THRESHOLD_RECON_SEED=0` is the dev/bench kill switch.
    public static let reconSeedKey = "threshold.render.reconSeed"

    /// Whether the next render loop arms temporal seeding.
    public static var reconSeedEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["THRESHOLD_RECON_SEED"] {
            return env != "0"
        }
        if UserDefaults.standard.object(forKey: reconSeedKey) == nil {
            return true   // default ON — absent key means never touched
        }
        return UserDefaults.standard.bool(forKey: reconSeedKey)
    }

    /// The governor config the shell arms at attach. Temporal reconstruction
    /// holds quality at lower march scales, so its floor drops to 0.35 — the
    /// whole point of the reconstruction (plan §toggles/governor).
    public static var governorDefault: QualityGovernorConfig {
        var config = QualityGovernorConfig.platformDefault
        if selectedBackend == .compute, reconstructionMode != .off {
            config.minRenderScale = 0.35
        }
        return config
    }

    /// Compositor render-quality CEILING (visionOS 26). This is the Vision Pro
    /// counterpart of the Mac render-scale lever's top: `maxRenderQuality` is
    /// set once and governs the drawable color-texture MEMORY allocation; the
    /// per-frame `renderQuality` (driven by the quality governor) scales the
    /// actual drawable size within it for free — no reallocation. 0.8 follows
    /// Apple's "set the max to the most your content needs" guidance and the
    /// original app's measured choice: it trims per-eye drawable memory (and
    /// sustained fill/thermals) on a constrained headset, and a heavy fractal
    /// that is GPU-bound well below native gains nothing from a 1.0 ceiling.
    /// The governor renders at or below this; tune with on-device memory data.
    public static let maxRenderQuality: Float = 0.8

    /// The layer configuration the shell renders against. Called from the
    /// CompositorLayer configuration closure.
    public static func configure(
        capabilities: LayerRenderer.Capabilities,
        configuration: inout LayerRenderer.Configuration
    ) {
        // Linear march output into an sRGB drawable: the hardware encodes on
        // write, matching the compute path's linear-in-texture convention.
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        // The compute backend cannot consume rasterization rate maps —
        // foveation is only armed on the fragment backend (RenderBackend doc).
        let foveation = capabilities.supportsFoveation
            && selectedBackend == .fragment
        configuration.isFoveationEnabled = foveation
        let layouts = capabilities.supportedLayouts(options:
            foveation ? [.foveationEnabled] : [])
        // Layered = ONE vertex-amplified pass covering both eyes, so it also
        // needs the Metal device to amplify ×2. The Simulator offers the
        // layout but its Metal device cannot amplify (pipeline creation
        // aborts) — dedicated's per-view passes need no amplification.
        let canAmplify = MTLCreateSystemDefaultDevice()?
            .supportsVertexAmplificationCount(2) ?? false
        configuration.layout = (layouts.contains(.layered) && canAmplify)
            ? .layered : .dedicated
        // Runtime render-quality control only takes effect with foveation on
        // (the compositor's foveation-aware upscaler is what resizes the
        // drawable). maxRenderQuality caps the per-frame renderQuality set in
        // the loop; without it the platform default sits well below native and
        // the image is uniformly soft (the original app's finding).
        if configuration.isFoveationEnabled {
            configuration.maxRenderQuality = LayerRenderer.RenderQuality(maxRenderQuality)
        }
    }

    /// Spawn the render thread against a live LayerRenderer. Called from the
    /// CompositorLayer content closure when the immersive space opens.
    @MainActor public func start(_ layerRenderer: LayerRenderer) {
        // Natural layer invalidation permits a new layer; explicit stop is terminal.
        // Reset the stop flag under the same lock as begin(): a stop() landing
        // between the two would otherwise be overwritten and ignored.
        let shouldStart = phase.withLock { phase in
            let begin = phase.begin()
            if begin { stopRequested.store(false, ordering: .releasing) }
            return begin
        }
        guard shouldStart else { return }
        _ = finished.wait(timeout: .now()) // consume the previous loop completion
        // World grab input: system pinches arrive through the layer's
        // spatial-event channel (the BorgVR pattern). Installed
        // unconditionally — the session gates on its Settings toggle per
        // delivery, so enabling/disabling applies live, and disabling also
        // resets the transform (WorldGrabSession.handle doc).
        layerRenderer.onSpatialEvent = { [worldGrab] events in
            worldGrab.handle(events)
        }
        let transferred = LayerRendererTransfer(layerRenderer)
        let thread = Thread { [self, transferred] in
            renderLoop(transferred.renderer)
        }
        thread.name = "threshold.compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ask the loop to exit and JOIN it (bounded). The loop also self-exits
    /// when the layer invalidates — dismissing the immersive space tears it
    /// down — in which case `finished` is already signaled and the join
    /// returns immediately. Idempotent: only the first call after `start()`
    /// joins; a never-started or already-stopped session returns at once.
    public func stop() {
        let shouldJoin = phase.withLock { phase in
            let join = phase.requestStop()
            if join { stopRequested.store(true, ordering: .releasing) }
            return join
        }
        guard shouldJoin else { return }

        ThresholdLog.session.notice("compositor session stop requested")
        // BOUNDED join: the loop may be parked in the compositor's
        // waitUntilRunning()/Clock().wait(until:) and won't observe the flag
        // until it returns. On timeout, say so and abandon the join — the
        // thread closure retains `self`, so bailing leaks the thread, never
        // crashes (same contract as InteractiveSession.stop()).
        if finished.wait(timeout: .now() + 5) == .timedOut {
            ThresholdLog.session.fault(
                """
                stop(): compositor render loop did not exit after 5s — likely \
                parked in the compositor frame wait; abandoning join (thread leaked)
                """)
        } else {
            ThresholdLog.session.notice("compositor session stopped (joined cleanly)")
        }
    }

    // MARK: Render thread

    private func renderLoop(_ layer: LayerRenderer) {
        // Signal the join on EVERY exit path — dead-on-arrival returns, layer
        // invalidation, and stop-requested alike — so stop() never waits the
        // full timeout on a loop that already exited.
        defer {
            phase.withLock {
                $0.end()
                finished.signal()
            }
            onRenderLoopEnded?()
        }
        // Render-thread-confined state survives immersive-space reopening.
        let core = retainedCore ?? SessionCore(
            layout: layout,
            signals: signals,
            laneMailbox: laneMailbox,
            commands: commands,
            initialScene: initialScene)
        retainedCore = core

        guard let queue = context.device.makeCommandQueue() else {
            ThresholdLog.session.fault(
                "compositor session dead on arrival — no command queue")
            return
        }
        queue.label = "threshold.compositor.queue"

        let layered = layer.configuration.layout == .layered
        // Backend choice (RenderBackend doc): fragment (foveated, default) or
        // the experimental per-view compute march. Exactly one encoder exists.
        let backend = Self.selectedBackend
        var raster: ViewPassEncoder? = nil
        var rasterPost: PostProcessor? = nil
        var computeGPU: ViewComputeEncoder? = nil
        var computeRecon: TemporalReconstructor? = nil
        switch backend {
        case .fragment:
            do {
                let builtRaster = try ViewPassEncoder(
                    context: context,
                    colorFormat: layer.configuration.colorFormat,
                    depthFormat: layer.configuration.depthFormat,
                    maxViewCount: layered ? 2 : 1)
                let builtPost = try PostProcessor(context: context)
                raster = builtRaster
                rasterPost = builtPost
            } catch {
                ThresholdLog.session.fault(
                    """
                    compositor session dead on arrival — raster encoder init \
                    failed: \(String(describing: error), privacy: .public)
                    """)
            }
        case .compute:
            do {
                computeGPU = try ViewComputeEncoder(
                    context: context,
                    colorFormat: layer.configuration.colorFormat)
            } catch {
                ThresholdLog.session.fault(
                    """
                    compositor session dead on arrival — compute encoder init \
                    failed: \(String(describing: error), privacy: .public)
                    """)
            }
            // The compute backend's resolution lever (march.renderScale):
            // reduced-resolution march + present upsample, driven by the same
            // governor scale the fragment backend maps to renderQuality.
            // Loop-start construction so the resolve-library compile never
            // lands mid-frame. Failure is non-fatal — nil keeps the backend
            // at full drawable resolution exactly as before the lever.
            if computeGPU != nil {
                do {
                    computeRecon = try TemporalReconstructor(
                        context: context,
                        colorFormat: layer.configuration.colorFormat)
                    // Temporal mode (phase A) + seeding (A2): armed once per
                    // loop, same apply-on-reopen contract as the backend
                    // picker.
                    computeRecon?.mode = Self.reconstructionMode
                    computeRecon?.seedingEnabled = Self.reconSeedEnabled
                    if let recon = computeRecon, recon.mode != .off {
                        ThresholdLog.session.notice(
                            """
                            temporal reconstruction armed: \
                            \(recon.mode.rawValue, privacy: .public)\
                            \(recon.seedingEnabled ? "+seed" : "", privacy: .public)
                            """)
                    }
                } catch {
                    ThresholdLog.session.error(
                        """
                        reconstruction unavailable — compute backend stays at \
                        full resolution: \(String(describing: error), privacy: .public)
                        """)
                }
            }
        }
        guard raster != nil || computeGPU != nil else { return }
        func lastCompletedStats() -> FrameStatsSlot.Stats {
            raster?.lastCompleted() ?? computeGPU!.lastCompleted()
        }

        // Head tracking: the compositor needs a device anchor per frame for
        // reprojection; the eye poses derive from it.
        let arSession = ARKitSession()
        let worldTracking = WorldTrackingProvider()
        let trackingTask = Task {
            defer { if Task.isCancelled { arSession.stop() } }
            do {
                try Task.checkCancellation()
                try await arSession.run([worldTracking])
            } catch {
                // Non-fatal but very visible in use: no head anchor means the
                // eyes render from the identity pose.
                ThresholdLog.session.error(
                    """
                    compositor world tracking failed: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }

        defer {
            trackingTask.cancel()
            arSession.stop()
        }

        /// Head room-position at first tracked frame — the room point mapped
        /// onto the session camera (CompositorViewMath.viewUniforms doc).
        var anchorPosition: SIMD3<Float>?
        var lastGrabWasIdentity = true
        /// The previous frame's SESSION-clock time — what inputs stamp their
        /// signals with so binding/staleness math compares like with like
        /// (one frame stale, well inside every freshness tolerance).
        var sessionTime = 0.0

        // Adaptive render quality (the Vision Pro resolution lever). The
        // governor's resolution target for the PREVIOUS frame (SessionCore
        // computes it from prior-frame GPU time and carries it on the request)
        // sets THIS frame's drawable size. One frame late is immaterial: the
        // governor already reacts to prior-frame timing, and the compositor
        // ramps renderQuality smoothly over several frames regardless. Seeded
        // at the ceiling so a light opening scene starts sharp.
        let foveated = layer.configuration.isFoveationEnabled
        var pendingRenderQuality = Self.maxRenderQuality
        var lastAppliedRenderQuality: Float = -1

        // Temporal reconstruction per-frame state: the previous ENCODED
        // frame's views (motion/reprojection reference — history was written
        // by that frame, so the pair stays consistent across dropped frames)
        // and the reset funnel's change detectors.
        var previousViews: [ThreshViewUniforms]? = nil
        var lastOctave: Int32? = nil
        var lastHistoryEpoch: UInt32? = nil

        // Profiling seam (RenderTelemetry.swift). Until now the visionOS render
        // path had NO os_signpost coverage — a Metal System Trace / os_signpost
        // capture on Vision Pro showed unnamed regions and no phase breakdown.
        // We emit the SAME named phases as the Mac InteractiveSession path
        // ("drawable" wait, "core.step", "encode") so both device traces read
        // alike, plus a periodic os_log summary for numbers WITHOUT Instruments.
        let profiler = FrameProfiler(telemetry: RenderTelemetry(), logSummaries: true)
        let sp = profiler.signposter
        var frameIndex: UInt64 = 0

        ThresholdLog.session.notice(
            """
            compositor render loop up (device: \
            \(self.context.device.name, privacy: .public), backend: \
            \(backend.rawValue, privacy: .public), layered: \(layered), \
            foveated: \(foveated))
            """)

        while !stopRequested.load(ordering: .acquiring) {
            switch layer.state {
            case .invalidated:
                ThresholdLog.session.notice(
                    "compositor layer invalidated — render loop exiting")
                return
            case .paused:
                // System-paused (immersion dropped, device doffed). The wait
                // blocks this thread — bracket it so a log tells "system
                // paused us" apart from "wedged".
                ThresholdLog.session.notice("compositor layer paused — waiting")
                layer.waitUntilRunning()
                ThresholdLog.session.notice("compositor layer resumed")
                continue
            case .running:
                break
            @unknown default:
                break
            }

            guard let frame = layer.queryNextFrame() else { continue }
            frame.startUpdate()
            frame.endUpdate()

            // Apply the resolution target BEFORE querying the drawable, so the
            // drawable is sized for it. Deduped — the compositor tweens each
            // change, so re-setting the same value every frame would fight its
            // ramp. Gated on foveation (renderQuality is inert without it).
            if foveated, abs(pendingRenderQuality - lastAppliedRenderQuality) > 0.001 {
                lastAppliedRenderQuality = pendingRenderQuality
                layer.renderQuality = LayerRenderer.RenderQuality(pendingRenderQuality)
            }

            guard let timing = frame.predictTiming() else { continue }

            // Frame entry stamp for the profiler's inter-frame cadence measure
            // (Mono is telemetry-only — Invariant 9 — never the render clock).
            let frameEntry = Mono.now()

            // "drawable" phase: the compositor input-time wait + drawable
            // acquisition. On a GPU-bound headset this is where the render
            // thread blocks waiting for a free frame slot; a large value here
            // vs. a small "encode" is the CPU/sync-bound signature.
            let waitStart = Mono.now()
            let drawableState = sp.beginInterval("drawable")
            LayerRenderer.Clock().wait(until: timing.optimalInputTime)

            frame.startSubmission()
            guard let drawable = frame.queryDrawables().first else {
                sp.endInterval("drawable", drawableState)
                frame.endSubmission()
                continue
            }
            sp.endInterval("drawable", drawableState)
            let drawableMs = Mono.ms(waitStart, Mono.now())

            let anchorTime = Self.seconds(timing.trackableAnchorTime)
            let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: anchorTime)
            drawable.deviceAnchor = deviceAnchor

            // Frame timestamps come from the compositor's clock — the ONE
            // permitted time source on this shell (Invariant 9).
            let now = Self.seconds(timing.presentationTime)

            // Inputs (hands) publish BEFORE the step so bindings and the
            // gesture lane see this frame's values.
            onFrame?(sessionTime)

            let stats = lastCompletedStats()
            let colorTexture = drawable.colorTextures[0]
            // "core.step" phase: per-frame session logic + the quality governor.
            let stepStart = Mono.now()
            let stepState = sp.beginInterval("core.step")
            let sessionFrame = core.step(
                now: now,
                width: colorTexture.width,
                height: colorTexture.height,
                gpuMilliseconds: stats.governorMilliseconds)
            sp.endInterval("core.step", stepState)
            let stepMs = Mono.ms(stepStart, Mono.now())
            sessionTime = sessionFrame.time
            // The compositor shell has no offscreen export backend. Complete
            // the request with an explicit terminal failure instead of leaving
            // a caller to poll an empty slot forever.
            if let capture = core.takePendingImageCapture() {
                capture.slot.publish(
                    failure: "still-image capture is unavailable in the visionOS compositor")
            }
            // The governor's resolution scale becomes next frame's compositor
            // renderQuality. On this shell renderScale is NOT an intermediate
            // texture (that is the Mac/InteractiveSession path) — the drawable
            // itself shrinks, so the march runs fewer fragments and the
            // compositor upscales natively. CLAMP to the configured ceiling:
            // the governor's scale reaches 1.0 on light scenes, and the
            // compositor rejects any renderQuality above maxRenderQuality
            // ("BUG IN CLIENT: called -setRenderQuality with value larger than
            // configuration render quality").
            pendingRenderQuality = min(sessionFrame.request.renderScale, Self.maxRenderQuality)

            // Reset funnel (temporal reconstruction): an octave rebase moves
            // the world by a power of two and a history-epoch bump means a
            // structurally different world — either way yesterday's history
            // lies. Mirrors the Mac path's noteOctave.
            if let recon = computeRecon, recon.mode != .off {
                if (lastOctave != nil && lastOctave != sessionFrame.scaleOctave)
                    || (lastHistoryEpoch != nil
                        && lastHistoryEpoch != sessionFrame.historyEpoch) {
                    recon.requestHistoryReset()
                }
                lastOctave = sessionFrame.scaleOctave
                lastHistoryEpoch = sessionFrame.historyEpoch
            }

            let originFromDevice =
                deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            if anchorPosition == nil, deviceAnchor != nil {
                anchorPosition = SIMD3(
                    originFromDevice.columns.3.x,
                    originFromDevice.columns.3.y,
                    originFromDevice.columns.3.z)
            }
            // World Grab: read once per frame and fold into BOTH the eyes and
            // the hand stamping so they agree. A jump back to identity (reset,
            // toggle off, scene load) is a teleport — drop temporal history.
            let grab = worldGrab.current()
            if grab.isIdentity, !lastGrabWasIdentity,
               let recon = computeRecon, recon.mode != .off {
                recon.requestHistoryReset()
            }
            lastGrabWasIdentity = grab.isIdentity
            let views = drawable.views.indices.map { i in
                CompositorViewMath.viewUniforms(
                    projection: drawable.computeProjection(viewIndex: i),
                    eyeToRoom: originFromDevice * drawable.views[i].transform,
                    anchorPosition: anchorPosition ?? .zero,
                    base: sessionFrame.request.uniforms,
                    grab: grab)
            }

            // Spatial hand path (plan §4.3): drive-flagged ops get their
            // geometry stamped from the hand signals, through the same
            // room→fractal map as the eyes.
            let request = stampHandOps(
                sessionFrame.request, now: sessionFrame.time,
                anchorPosition: anchorPosition ?? .zero, grab: grab)

            // "encode" phase: CPU cost of building + committing the command
            // buffer (the GPU work itself lands in gpuMilliseconds, next frame).
            let encodeStart = Mono.now()
            let encodeState = sp.beginInterval("encode")
            if let commandBuffer = CommandBufferHealth.makeCommandBuffer(on: queue) {
                commandBuffer.label = "compositor frame"
                let marched: Bool
                if let raster {
                    marched = encode(
                        request, views: views, drawable: drawable,
                        layered: layered, gpu: raster,
                        postProcessor: rasterPost,
                        program: sessionFrame.externalProgram,
                        commandBuffer: commandBuffer)
                } else if let computeGPU {
                    marched = encodeCompute(
                        request, views: views, drawable: drawable,
                        layered: layered, gpu: computeGPU,
                        program: sessionFrame.externalProgram,
                        recon: computeRecon,
                        prevViews: previousViews,
                        commandBuffer: commandBuffer)
                    previousViews = views
                } else {
                    marched = false
                }
                // A skipped march must STILL present a defined image: mixed
                // immersion composites the drawable over passthrough, so an
                // unwritten texture is undefined content (a garbage flash) —
                // exactly what the frames between a scene apply and its
                // external-DE variant compile would show. Clear to
                // transparent-black (the miss color) instead.
                if !marched {
                    clearDrawable(
                        drawable, viewCount: drawable.views.count,
                        layered: layered, commandBuffer: commandBuffer)
                }
                drawable.encodePresent(commandBuffer: commandBuffer)
                commandBuffer.commit()
            }
            sp.endInterval("encode", encodeState)
            frame.endSubmission()
            let encodeMs = Mono.ms(encodeStart, Mono.now())

            // Feed the profiler: rolling phase averages + hitch attribution to
            // os_log every 60 frames, and a signpost "hitch" event on stutters.
            frameIndex += 1
            profiler.record(
                entry: frameEntry, stepMs: stepMs, drawableMs: drawableMs,
                encodeMs: encodeMs, gpuMs: stats.gpuMilliseconds,
                frameIndex: frameIndex,
                pixels: colorTexture.width * colorTexture.height)

            // Debug telemetry for the control-window panel. Report the
            // renderQuality actually applied (clamped to the ceiling) — the
            // drawable shrinks and the compositor upscales natively, so
            // `upscaling` tracks quality < 1. The compute backend reports the
            // REALIZED march scale of its own lever (multiple-of-8 rounding
            // makes it differ slightly from the governor's ask), or full
            // scale when the reconstructor is unavailable.
            let scale: Float
            if foveated {
                scale = pendingRenderQuality
            } else if computeRecon != nil,
                      let m = TemporalReconstructor.marchSize(
                          outputWidth: colorTexture.width,
                          outputHeight: colorTexture.height,
                          scale: request.renderScale) {
                scale = Float(m.width) / Float(colorTexture.width)
            } else {
                scale = 1
            }
            let pipeline: RenderDiagnostics.Pipeline =
                sessionFrame.externalProgram != nil ? .external
                    : (backend == .compute ? .viewCompute : .raster)
            snapshots.publish(sessionFrame.snapshot(
                gpuMilliseconds: stats.gpuMilliseconds,
                totalSteps: stats.totalSteps,
                diagnostics: RenderDiagnostics(
                    pipeline: pipeline,
                    renderScale: scale,
                    upscaling: scale < 0.999,
                    reconstruction: {
                        guard let recon = computeRecon, recon.mode != .off
                        else { return "off" }
                        return recon.mode.rawValue
                            + (recon.seedingEnabled ? "+seed" : "")
                    }())))
        }
        ThresholdLog.session.notice("compositor render loop exited (stop requested)")
    }

    /// One pass (layered: amplified across both views) or one per view
    /// (dedicated: the views buffer slides by one entry per pass).
    /// `program` is the active external DE (nil = built-in set) — both
    /// backends render external DE scenes by dispatching the program's own
    /// variant pipelines (ExternalDE.swift).
    private func encode(
        _ request: RenderRequest,
        views: [ThreshViewUniforms],
        drawable: LayerRenderer.Drawable,
        layered: Bool,
        gpu: ViewPassEncoder,
        postProcessor: PostProcessor?,
        program: ExternalDEProgram?,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        func pass(colorIndex: Int) -> MTLRenderPassDescriptor {
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture = drawable.colorTextures[colorIndex]
            desc.colorAttachments[0].loadAction = .dontCare
            desc.colorAttachments[0].storeAction = .store
            desc.depthAttachment.texture = drawable.depthTextures[colorIndex]
            desc.depthAttachment.loadAction = .dontCare
            desc.depthAttachment.storeAction = .store
            if drawable.rasterizationRateMaps.indices.contains(colorIndex) {
                desc.rasterizationRateMap = drawable.rasterizationRateMaps[colorIndex]
            }
            return desc
        }

        if layered {
            let desc = pass(colorIndex: 0)
            desc.renderTargetArrayLength = drawable.views.count
            let marched = gpu.encode(
                request, views: views, renderPass: desc,
                commandBuffer: commandBuffer,
                amplificationCount: drawable.views.count,
                program: program)
            if marched {
                encodePostProcess(
                    request, texture: drawable.colorTextures[0],
                    postProcessor: postProcessor, commandBuffer: commandBuffer)
            }
            return marched
        } else {
            var marched = false
            for (i, _) in views.enumerated()
            where drawable.colorTextures.indices.contains(i) {
                let encoded = gpu.encode(
                    request, views: views,
                    viewsByteOffset: i * MemoryLayout<ThreshViewUniforms>.stride,
                    renderPass: pass(colorIndex: i),
                    commandBuffer: commandBuffer,
                    program: program)
                marched = marched || encoded
                if encoded {
                    encodePostProcess(
                        request, texture: drawable.colorTextures[i],
                        postProcessor: postProcessor, commandBuffer: commandBuffer)
                }
            }
            return marched
        }
    }

    /// A no-march frame: clear every drawable attachment to the miss color
    /// (transparent black) + far depth, so the composited frame is defined
    /// passthrough rather than undefined texture content. Layered: one array
    /// attachment (renderTargetArrayLength) covers both views; dedicated:
    /// one clear pass per view texture.
    private func clearDrawable(
        _ drawable: LayerRenderer.Drawable, viewCount: Int, layered: Bool,
        commandBuffer: MTLCommandBuffer
    ) {
        let views = max(1, layered ? 1 : min(viewCount, drawable.colorTextures.count))
        for i in 0..<views {
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture = drawable.colorTextures[i]
            desc.colorAttachments[0].loadAction = .clear
            desc.colorAttachments[0].storeAction = .store
            desc.colorAttachments[0].clearColor =
                MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if drawable.depthTextures.indices.contains(i) {
                desc.depthAttachment.texture = drawable.depthTextures[i]
                desc.depthAttachment.loadAction = .clear
                desc.depthAttachment.storeAction = .store
                desc.depthAttachment.clearDepth = 1.0
            }
            if layered {
                desc.renderTargetArrayLength = max(1, viewCount)
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: desc) else { return }
            encoder.label = "compositor clear-on-drop"
            encoder.endEncoding()
        }
    }

    /// Raster-compositor post stage. System drawable textures are commonly
    /// blit-capable but not shader-readable; PostProcessor detects that and
    /// inserts a private input copy before the ordered HDR ping-pong passes.
    private func encodePostProcess(
        _ request: RenderRequest,
        texture: MTLTexture,
        postProcessor: PostProcessor?,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let postProcessor else { return }
        do {
            try postProcessor.encode(
                commandBuffer: commandBuffer,
                source: texture,
                destination: texture,
                stack: request.postProcessStack,
                time: request.uniforms.scaleCtx.x)
        } catch {
            ThresholdLog.render.error(
                "compositor raster post-processing failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Compute-backend encode: intermediates + blit per view. Layered: the
    /// drawable's textures are arrays (slice per view); dedicated: one
    /// texture per view at slice 0.
    private func encodeCompute(
        _ request: RenderRequest,
        views: [ThreshViewUniforms],
        drawable: LayerRenderer.Drawable,
        layered: Bool,
        gpu: ViewComputeEncoder,
        program: ExternalDEProgram?,
        recon: TemporalReconstructor?,
        prevViews: [ThreshViewUniforms]?,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        var colorTargets: [(texture: MTLTexture, slice: Int)] = []
        var depthTargets: [(texture: MTLTexture, slice: Int)] = []
        if layered {
            for i in views.indices {
                colorTargets.append((drawable.colorTextures[0], i))
                depthTargets.append((drawable.depthTextures[0], i))
            }
        } else {
            for i in views.indices
            where drawable.colorTextures.indices.contains(i) {
                colorTargets.append((drawable.colorTextures[i], 0))
                depthTargets.append((drawable.depthTextures[i], 0))
            }
        }
        return gpu.encode(
            request, views: views,
            colorTargets: colorTargets, depthTargets: depthTargets,
            commandBuffer: commandBuffer, program: program,
            recon: recon, prevViews: prevViews)
    }

    // MARK: Hand-driven ops

    /// Signals older than this are treated as lost tracking (the tracker
    /// publishes every frame while a hand is tracked).
    private static let handSignalFreshness = 0.25

    private func stampHandOps(
        _ request: RenderRequest, now: Double, anchorPosition: SIMD3<Float>,
        grab: WorldGrabTransform
    ) -> RenderRequest {
        guard request.ops.contains(where: {
            WarpFlags(rawValue: $0.flags)
                .intersection([.driveRightHand, .driveLeftHand]) != []
        }) else { return request }

        func point(_ id: SignalID) -> SIMD3<Float>? {
            guard let signal = signals.read(id: id),
                  now - signal.timestamp < Self.handSignalFreshness
            else { return nil }
            return SIMD3(signal.value.x, signal.value.y, signal.value.z)
        }

        let right = HandOpStamper.Hand(
            palm: point(.handRightPalm),
            wrist: point(.handRightPosition),
            forearm: point(.handRightForearm))
        let left = HandOpStamper.Hand(
            palm: point(.handLeftPalm),
            wrist: point(.handLeftPosition),
            forearm: point(.handLeftForearm))

        return RenderRequest(
            uniforms: request.uniforms,
            params: request.params,
            ops: HandOpStamper.stamp(
                request.ops, right: right, left: left,
                base: request.uniforms, anchorPosition: anchorPosition,
                grab: grab),
            palette: request.palette,
            postProcessStack: request.postProcessStack,
            width: request.width,
            height: request.height,
            // Preserve the render-pipeline tuning (specialization + cone
            // prepass) and scale — the raster encoder consults request.tuning.
            renderScale: request.renderScale,
            tuning: request.tuning,
            worldVolatility: request.worldVolatility)
    }

    // MARK: Clock

    /// Compositor clock instant → seconds since its epoch (feeds
    /// SessionCore.step, which baselines its own session clock).
    static func seconds(_ instant: LayerRenderer.Clock.Instant) -> Double {
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: instant)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
    }
}

#endif  // os(visionOS)
