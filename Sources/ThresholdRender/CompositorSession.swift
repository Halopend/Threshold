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
// - Built-in DEs only: the raster pipeline links the built-in set. A scene
//   with an embedded DE still applies (params, palette, warps); its DE
//   renders once external programs grow a raster pipeline.

#if os(visionOS)

import ARKit
import CompositorServices
import Foundation
import Metal
import Synchronization
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR

/// AUDIT — `@unchecked Sendable`, same precedent as InteractiveSession:
/// mailboxes/snapshot slot are compiler-checked Sendable; `context`, `layout`,
/// `signals`, `initialScene` are Sendable `let`s; `stopRequested` is an
/// Atomic; `onFrame` is written before `start(_:)` (documented contract) and
/// read only by the render thread.
public final class CompositorSession: @unchecked Sendable {

    // MARK: Channels (Invariant 13)

    public let laneMailbox: LaneMailbox
    public let commands: CommandMailbox<SessionCommand>
    public let snapshots: SnapshotSlot

    // MARK: Configuration

    private let context: GPUContext
    private let layout: CatalogLayout
    private let signals: SignalTable
    private let initialScene: SceneEnvelope?
    private let stopRequested = Atomic<Bool>(false)

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
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
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
    public func start(_ layerRenderer: LayerRenderer) {
        stopRequested.store(false, ordering: .releasing)
        let thread = Thread { [self] in
            renderLoop(layerRenderer)
        }
        thread.name = "threshold.compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ask the loop to exit (it also exits when the layer invalidates —
    /// dismissing the immersive space tears it down without an explicit stop).
    public func stop() {
        stopRequested.store(true, ordering: .releasing)
    }

    // MARK: Render thread

    private func renderLoop(_ layer: LayerRenderer) {
        // Render-thread-confined state comes to life HERE (ADR-004).
        let core = SessionCore(
            layout: layout,
            signals: signals,
            laneMailbox: laneMailbox,
            commands: commands,
            initialScene: initialScene)

        guard let queue = context.device.makeCommandQueue() else { return }
        queue.label = "threshold.compositor.queue"

        let layered = layer.configuration.layout == .layered
        // Backend choice (RenderBackend doc): fragment (foveated, default) or
        // the experimental per-view compute march. Exactly one encoder exists.
        let backend = Self.selectedBackend
        var raster: ViewPassEncoder? = nil
        var computeGPU: ViewComputeEncoder? = nil
        switch backend {
        case .fragment:
            raster = try? ViewPassEncoder(
                context: context,
                colorFormat: layer.configuration.colorFormat,
                depthFormat: layer.configuration.depthFormat,
                maxViewCount: layered ? 2 : 1)
        case .compute:
            computeGPU = try? ViewComputeEncoder(
                context: context,
                colorFormat: layer.configuration.colorFormat)
        }
        guard raster != nil || computeGPU != nil else { return }
        func lastCompletedStats() -> FrameStatsSlot.Stats {
            raster?.lastCompleted() ?? computeGPU!.lastCompleted()
        }

        // Head tracking: the compositor needs a device anchor per frame for
        // reprojection; the eye poses derive from it.
        let arSession = ARKitSession()
        let worldTracking = WorldTrackingProvider()
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                print("compositor world tracking failed: \(error)")
            }
        }

        /// Head room-position at first tracked frame — the room point mapped
        /// onto the session camera (CompositorViewMath.viewUniforms doc).
        var anchorPosition: SIMD3<Float>?
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

        // Profiling seam (RenderTelemetry.swift). Until now the visionOS render
        // path had NO os_signpost coverage — a Metal System Trace / os_signpost
        // capture on Vision Pro showed unnamed regions and no phase breakdown.
        // We emit the SAME named phases as the Mac InteractiveSession path
        // ("drawable" wait, "core.step", "encode") so both device traces read
        // alike, plus a periodic os_log summary for numbers WITHOUT Instruments.
        let profiler = FrameProfiler(telemetry: RenderTelemetry(), logSummaries: true)
        let sp = profiler.signposter
        var frameIndex: UInt64 = 0

        while !stopRequested.load(ordering: .acquiring) {
            switch layer.state {
            case .invalidated:
                return
            case .paused:
                layer.waitUntilRunning()
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
                gpuMilliseconds: stats.gpuMilliseconds)
            sp.endInterval("core.step", stepState)
            let stepMs = Mono.ms(stepStart, Mono.now())
            sessionTime = sessionFrame.time
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

            let originFromDevice =
                deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            if anchorPosition == nil, deviceAnchor != nil {
                anchorPosition = SIMD3(
                    originFromDevice.columns.3.x,
                    originFromDevice.columns.3.y,
                    originFromDevice.columns.3.z)
            }
            let views = drawable.views.indices.map { i in
                CompositorViewMath.viewUniforms(
                    projection: drawable.computeProjection(viewIndex: i),
                    eyeToRoom: originFromDevice * drawable.views[i].transform,
                    anchorPosition: anchorPosition ?? .zero,
                    base: sessionFrame.request.uniforms)
            }

            // Spatial hand path (plan §4.3): drive-flagged ops get their
            // geometry stamped from the hand signals, through the same
            // room→fractal map as the eyes.
            let request = stampHandOps(
                sessionFrame.request, now: sessionFrame.time,
                anchorPosition: anchorPosition ?? .zero)

            // "encode" phase: CPU cost of building + committing the command
            // buffer (the GPU work itself lands in gpuMilliseconds, next frame).
            let encodeStart = Mono.now()
            let encodeState = sp.beginInterval("encode")
            if let commandBuffer = queue.makeCommandBuffer() {
                commandBuffer.label = "compositor frame"
                if let raster {
                    encode(
                        request, views: views, drawable: drawable,
                        layered: layered, gpu: raster, commandBuffer: commandBuffer)
                } else if let computeGPU {
                    encodeCompute(
                        request, views: views, drawable: drawable,
                        layered: layered, gpu: computeGPU,
                        commandBuffer: commandBuffer)
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
            // `upscaling` tracks quality < 1. The compute backend has no
            // renderQuality lever (foveation off) — it reports full scale.
            let scale = foveated ? pendingRenderQuality : 1
            snapshots.publish(sessionFrame.snapshot(
                gpuMilliseconds: stats.gpuMilliseconds,
                totalSteps: stats.totalSteps,
                diagnostics: RenderDiagnostics(
                    pipeline: backend == .compute ? .viewCompute : .raster,
                    renderScale: scale,
                    upscaling: scale < 0.999)))
        }
    }

    /// One pass (layered: amplified across both views) or one per view
    /// (dedicated: the views buffer slides by one entry per pass).
    private func encode(
        _ request: RenderRequest,
        views: [ThreshViewUniforms],
        drawable: LayerRenderer.Drawable,
        layered: Bool,
        gpu: ViewPassEncoder,
        commandBuffer: MTLCommandBuffer
    ) {
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
            gpu.encode(
                request, views: views, renderPass: desc,
                commandBuffer: commandBuffer,
                amplificationCount: drawable.views.count)
        } else {
            for (i, _) in views.enumerated()
            where drawable.colorTextures.indices.contains(i) {
                gpu.encode(
                    request, views: views,
                    viewsByteOffset: i * MemoryLayout<ThreshViewUniforms>.stride,
                    renderPass: pass(colorIndex: i),
                    commandBuffer: commandBuffer)
            }
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
        commandBuffer: MTLCommandBuffer
    ) {
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
        gpu.encode(
            request, views: views,
            colorTargets: colorTargets, depthTargets: depthTargets,
            commandBuffer: commandBuffer)
    }

    // MARK: Hand-driven ops

    /// Signals older than this are treated as lost tracking (the tracker
    /// publishes every frame while a hand is tracked).
    private static let handSignalFreshness = 0.25

    private func stampHandOps(
        _ request: RenderRequest, now: Double, anchorPosition: SIMD3<Float>
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
                base: request.uniforms, anchorPosition: anchorPosition),
            palette: request.palette,
            width: request.width,
            height: request.height,
            // Preserve the render-pipeline tuning (specialization + cone
            // prepass) and scale — the raster encoder consults request.tuning.
            renderScale: request.renderScale,
            tuning: request.tuning)
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
