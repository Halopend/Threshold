// SessionCore.swift — the interactive session's per-frame logic, extracted
// from the display-link shell so tests can drive frames manually and render
// through OffscreenRenderer (ARCHITECTURE.md §2: "the harness's manual
// step(dt:) and the Compositor loop call the same" frame body).
//
// Concurrency (ADR-004): NOT Sendable. A SessionCore is created ON the render
// thread (or the test's driving thread) and never leaves it. Its only ingress
// is the lane mailbox (owned by the engine) + the command mailbox; its only
// egress is the SessionFrame value returned from `step`, whose contents are
// all Sendable.
//
// Frame order (ARCHITECTURE.md §2, SessionContracts.swift): drain commands →
// clock.update → publish app.time → bindings → resolve → build request. The
// command drain happens BEFORE resolution so a frame sees either the old
// structure or the new one, never a torn mix.

import Foundation
import os
import simd
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR

final class SessionCore {
    let layout: CatalogLayout
    let signals: SignalTable
    let commands: CommandMailbox<SessionCommand>

    /// Fed frame timestamps by the caller (display link's targetTimestamp,
    /// or synthetic timestamps in tests) — never reads wall time itself
    /// (Invariant 9).
    let clock: WallClock
    let engine: ModulationEngine
    let bindingEngine: BindingEngine
    let animationPlayer: AnimationPlayer
    let lfoEngine: LFOEngine

    private(set) var descriptor: DEDescriptor
    /// Active external DE program; when set, `descriptor` is its descriptor
    /// and the encoder binds its pipeline/table.
    private(set) var externalProgram: ExternalDEProgram?
    /// The built-in to revert to when the external program is cleared.
    private var lastBuiltinDescriptor: DEDescriptor
    /// Dynamic-arena bookkeeping for the external DE's declared params: each
    /// activation registers them into the arena (sliders/bindings work like
    /// built-ins), each deactivation recycles it (Catalog.freeze doc).
    private var arena: ArenaAllocator
    /// Arena slots of the active external DE's params, in paramLayout order;
    /// empty when no external DE is active OR the arena was exhausted (then
    /// the DE renders at declared defaults).
    private var externalParamSlots: Range<Int> = 0..<0
    /// Catalog-shaped entries for the dynamic registrations, published in
    /// snapshots so the UI derives controls exactly as for static entries.
    private(set) var dynamicEntries: [CatalogEntry] = []
    /// The latest applied scene's raw params — seeds the scene lane for
    /// external DE params registered AFTER the scene apply (the setExternalDE
    /// command follows applyScene; SceneCodec.apply drops unknown keys).
    private var lastSceneParams: [String: [Float]] = [:]
    /// The active scene's embedded DE source, kept for re-saving (the
    /// compiled program does not retain its source).
    private var activeEmbeddedDE: EmbeddedDE?
    /// The fps-holding quality governor (ADR-003) — the first registered
    /// system-lane writer. nil = disabled.
    private var governorConfig: QualityGovernorConfig?
    private var governor = QualityGovernor()
    /// Live render-pipeline tuning (specialization on/off, iteration bake),
    /// seeded from the env and overridden by `setRenderTuning`. Carried on the
    /// frame's RenderRequest for the encoder to read.
    private var tuning = RenderTuning.envDefault
    /// The AUTHORED warp stack — what snapshots/editors show.
    private(set) var authoredStack: [WarpOpDTO] = []
    /// The simplified buffer the GPU sees (plan §5.2). Rebuilt only on
    /// structural change, not per frame.
    private(set) var gpuOps: [ThreshWarpOp] = []
    private(set) var camera: CameraDTO = .default
    /// Zoom-rebase counter (plan §6.3): integer octaves folded out of the
    /// `scale.zoom` phase, with `camera` living in the correspondingly
    /// rebased world. Bookkeeping — the kernel never sees it.
    private(set) var octave: Int32 = 0
    /// Bumped on DE switch / scene apply / external-DE swap — the shells'
    /// signal that temporal history describes a world that no longer exists
    /// (the reset funnel, temporal-reconstruction plan).
    private(set) var historyEpoch: UInt32 = 0
    /// Previous frame's world state for the volatility measure; nil until
    /// the first frame steps.
    private var volatilityBasis: WorldVolatility.Basis?
    private(set) var paused = false
    /// Active gradient palette (scene content). Defaults to the renderer's
    /// built-in stops until a scene or `setPalette` command replaces it.
    private(set) var palette = Palette(stops: PaletteWire.defaultStops)

    /// Scene-transition camera tween (ADR-005): `camera` above is always the
    /// AUTHORED target (what captureScene saves); while a tween is in flight
    /// this carries the displayed pose, easing toward the target with the
    /// same exponential the engine uses on the scene lane, landing exactly
    /// when the window closes.
    private struct CameraTween {
        var current: CameraDTO
        var remaining: Double
        var tau: Double
    }
    private var cameraTween: CameraTween?

    /// Scene-transition palette crossfade (ADR-005): `palette` above is the
    /// authored target; the GPU sees `Palette.crossfade(from:to:)` until the
    /// window closes.
    private struct PaletteTween {
        var from: Palette
        var elapsed: Double
        var duration: Double
        var tau: Double
    }
    private var paletteTween: PaletteTween?

    /// The pose the GPU renders this frame — the tween's pose mid-flight,
    /// the authored camera otherwise.
    private var displayedCamera: CameraDTO { cameraTween?.current ?? camera }

    /// The palette the GPU renders this frame.
    private var displayedPalette: Palette {
        guard let tween = paletteTween else { return palette }
        let w = 1 - exp(-tween.elapsed / tween.tau)
        return Palette.crossfade(from: tween.from, to: palette, weight: Float(w))
    }
    private var frameIndex: UInt64 = 0
    /// Latched image-export request (captureImage command). The shell's frame
    /// loop consumes it via `takePendingImageCapture` right after building a
    /// frame, so the export renders exactly what the screen shows.
    private var pendingImageCapture: (width: Int, height: Int, slot: ImageCaptureSlot)?

    init(
        layout: CatalogLayout,
        signals: SignalTable,
        laneMailbox: LaneMailbox,
        commands: CommandMailbox<SessionCommand>,
        initialScene: SceneEnvelope?,
        defaultDEKey: String = DEDescriptor.mandelbulb.key
    ) {
        self.layout = layout
        self.signals = signals
        self.commands = commands
        self.clock = WallClock()
        // The injected mailbox is what the session handed to clients before
        // this engine existed — the reason for ModulationEngine's mailbox
        // parameter.
        self.engine = ModulationEngine(layout: layout, clock: clock, mailbox: laneMailbox)
        self.bindingEngine = BindingEngine(layout: layout)
        self.animationPlayer = AnimationPlayer(layout: layout)
        self.lfoEngine = LFOEngine()
        let initial = DERegistry.descriptor(forKey: defaultDEKey) ?? .mandelbulb
        self.descriptor = initial
        self.lastBuiltinDescriptor = initial
        self.arena = ArenaAllocator(range: layout.arenaRange)
        if let scene = initialScene {
            apply(scene: scene)
        }
    }

    // MARK: - Frame

    /// One frame. `now` is the display link's targetTimestamp — the ONE
    /// permitted time source; `width`/`height` are the drawable's ACTUAL size
    /// this frame (resize follows the drawable, not a cached value).
    /// `gpuMilliseconds` is the PREVIOUS completed frame's GPU duration
    /// (0 = unknown; the shell feeds it, offline paths pass nothing) — the
    /// quality governor's only input.
    func step(
        now timestamp: Double, width: Int, height: Int,
        gpuMilliseconds: Double = 0
    ) -> SessionFrame {
        for command in commands.drain() {
            handle(command)
        }

        // Octave rebase (plan §6.3): BEFORE resolution, so the frame renders
        // from a consistent (phase, camera) pair — never a torn mix. Folding
        // an integer octave out of the phase and scaling the camera by the
        // matching power of two are both float-exact, so the image does not
        // change; the phase and the camera's coordinates stay in a healthy
        // float range at any zoom depth (ScaleContext header).
        if let zoomSlot = layout.slot(for: .scaleZoom),
           let phase = engine.readIntegratorPhase(slot: zoomSlot) {
            let k = ScaleContext.rebaseStep(zoomOctaves: phase)
            if k != 0 {
                engine.setIntegratorPhase(slot: zoomSlot, value: phase - Float(k))
                let worldScale = exp2(-Float(k))
                camera.position = camera.position.map { $0 * worldScale }
                // A mid-flight camera tween lives in the same world — rebase
                // its displayed pose too, or the glide would jump an octave.
                if var tween = cameraTween {
                    tween.current.position = tween.current.position.map { $0 * worldScale }
                    cameraTween = tween
                }
                octave &+= k
            }
        }

        // Quality governor (ADR-003): resolution is the ONLY lever. The
        // factor ≈ pixel-cost fraction, so √factor per axis; each shell
        // applies the scale through its platform mechanism (visionOS:
        // compositor renderQuality; Mac/iOS: MetalFX temporal upscale).
        // Quantized to 1/20ths so the additive-recovery creep doesn't
        // thrash texture/scaler allocations every frame. Iteration/step
        // writes were deliberately removed — they reshape the fractal
        // (docs/perf-notes.md perf block 5).
        // The user's Render Quality setting is the CEILING in both modes
        // (ADR-003: "quality sliders stay the user's ceiling; the governor
        // only modulates below them"). Governor on → adaptive within
        // [minRenderScale, ceiling]; off → the ceiling IS the scale.
        let qualityCeiling = min(max(tuning.manualRenderScale, 0.1), 1)
        var renderScale: Float = 1
        if let config = governorConfig {
            let factor = governor.update(gpuMilliseconds: gpuMilliseconds, config: config)
            renderScale = min(max(sqrt(factor), config.minRenderScale), 1)
            renderScale = (renderScale * 20).rounded() / 20
            renderScale = min(renderScale, qualityCeiling)
        } else {
            renderScale = qualityCeiling
        }

        clock.update(now: timestamp)

        // Scene-transition tweens (ADR-005) advance on CONTENT time, exactly
        // like the engine's smoothing — pausing freezes them mid-flight.
        advanceTweens(dt: clock.paused ? 0 : max(0, clock.delta))

        signals.publish(
            id: .appTime,
            value: SIMD4(Float(clock.now), 0, 0, 0),
            confidence: 1,
            timestamp: clock.now)

        // Procedural LFOs publish into the signal table BEFORE the binding
        // engine reads it, so an LFO's value reaches its bound param the SAME
        // frame (no one-frame lag). Content time (clock.now): LFOs freeze while
        // paused, exactly like animation and integrators.
        lfoEngine.publish(into: signals, now: clock.now)

        bindingEngine.apply(signals: signals, engine: engine, now: clock.now)

        // Live audio levels for the Music-pane meter. Read here on the render
        // thread (the SignalTable's read path is render-thread-confined — the
        // same thread the resolver reads on) and shipped out on the snapshot;
        // the UI never touches the table. Cheap: seven seqlock reads.
        func audioLevel(_ id: SignalID) -> Float { signals.read(id: id)?.value.x ?? 0 }
        let audioLevels = AudioLevels(
            rms: audioLevel(.audioRMS),
            bandLow: audioLevel(.audioBandLow),
            bandMid: audioLevel(.audioBandMid),
            bandHigh: audioLevel(.audioBandHigh),
            centroid: audioLevel(.audioCentroid),
            onset: audioLevel(.audioOnset),
            bandUser: audioLevel(.audioBandUser))

        // Animation lane writes (plan §3.2). Content time: delta is already 0
        // while paused; timeScale scales playback like integrators.
        animationPlayer.step(engine: engine, scaledDelta: clock.delta * clock.timeScale)

        let resolved = engine.resolve()

        // Param table: reserved engine slots + the active DE's slice, exactly
        // as the offscreen harness wires it (Sources/threshold-render/main.swift).
        var engineParams = EngineParams()
        engineParams.maxSteps = resolved.values[Int(THRESH_SLOT_MAX_STEPS)]
        engineParams.maxDist = resolved.values[Int(THRESH_SLOT_MAX_DIST)]
        engineParams.stepSafety = resolved.values[Int(THRESH_SLOT_STEP_SAFETY)]
        engineParams.iterations = resolved.values[Int(THRESH_SLOT_ITERATIONS)]
        engineParams.aoStrength = resolved.values[Int(THRESH_SLOT_AO_STRENGTH)]
        engineParams.shadowSoft = resolved.values[Int(THRESH_SLOT_SHADOW_SOFT)]
        // Color pipeline scalars (plan §5.5) — resolved from their fixed slots.
        engineParams.gradientRepeat = resolved.values[Int(THRESH_SLOT_GRAD_REPEAT)]
        engineParams.gradientOffset = resolved.values[Int(THRESH_SLOT_GRAD_OFFSET)]
        engineParams.gradientSmoothing = resolved.values[Int(THRESH_SLOT_GRAD_SMOOTH)]
        engineParams.colorMapMode = resolved.values[Int(THRESH_SLOT_MAP_MODE)]
        engineParams.saturation = resolved.values[Int(THRESH_SLOT_SATURATION)]
        engineParams.contrast = resolved.values[Int(THRESH_SLOT_CONTRAST)]
        engineParams.vibrance = resolved.values[Int(THRESH_SLOT_VIBRANCE)]
        engineParams.brightness = resolved.values[Int(THRESH_SLOT_BRIGHTNESS)]
        engineParams.gamma = resolved.values[Int(THRESH_SLOT_GAMMA)]
        engineParams.tonemap = resolved.values[Int(THRESH_SLOT_TONEMAP)]
        engineParams.bubbleEnabled = resolved.values[Int(THRESH_SLOT_BUBBLE_ENABLED)]
        engineParams.bubbleRadius = resolved.values[Int(THRESH_SLOT_BUBBLE_RADIUS)]
        engineParams.bubbleShape = resolved.values[Int(THRESH_SLOT_BUBBLE_SHAPE)]
        engineParams.bubbleBlend = resolved.values[Int(THRESH_SLOT_BUBBLE_BLEND)]
        // Atmosphere (legacy Effects ▸ Static) — resolved from their fixed slots.
        engineParams.glowEnabled = resolved.values[Int(THRESH_SLOT_GLOW_ENABLED)]
        engineParams.glowIntensity = resolved.values[Int(THRESH_SLOT_GLOW_INTENSITY)]
        engineParams.bloomEnabled = resolved.values[Int(THRESH_SLOT_BLOOM_ENABLED)]
        engineParams.bloomStrength = resolved.values[Int(THRESH_SLOT_BLOOM_STRENGTH)]
        engineParams.fogEnabled = resolved.values[Int(THRESH_SLOT_FOG_ENABLED)]
        engineParams.fogIntensity = resolved.values[Int(THRESH_SLOT_FOG_INTENSITY)]
        engineParams.fogColor = SIMD3(
            resolved.values[Int(THRESH_SLOT_FOG_COLOR_R)],
            resolved.values[Int(THRESH_SLOT_FOG_COLOR_G)],
            resolved.values[Int(THRESH_SLOT_FOG_COLOR_B)])
        let deValues: [Float]
        if externalProgram != nil, externalParamSlots.count == descriptor.paramLayout.count {
            // External DE: params live in the dynamic arena (setExternal).
            deValues = externalParamSlots.map { resolved.values[$0] }
        } else {
            deValues = descriptor.paramLayout.map { param -> Float in
                // A DE whose params were never registered (defensive: the app
                // shell registers every built-in at startup; an external DE
                // that exhausted the arena) renders at declared defaults
                // rather than crashing the render thread.
                layout.slot(for: .de(descriptor.key, param.name))
                    .map { resolved.values[$0] } ?? param.default
            }
        }
        let (params, deParamOffset) = ParamTableLayout.build(
            engine: engineParams, deParams: deValues)

        // Camera: the scene's base pose + resolved rig offsets (plan §8.3 —
        // gesture orbit, sliders, animation, and music drift are all just
        // lane values on camera.* params). Mid scene-transition the base is
        // the tween's displayed pose (ADR-005); rig offsets ride on top.
        var uniforms = ThreshFrameUniforms()
        func rigValue(_ key: ParamKey, _ fallback: Float) -> Float {
            layout.slot(for: key).map { resolved.values[$0] } ?? fallback
        }
        let baseCamera = displayedCamera
        let pose = CameraRig.pose(
            base: baseCamera,
            yaw: rigValue(.cameraOrbitYaw, 0),
            pitch: rigValue(.cameraOrbitPitch, 0),
            dolly: rigValue(.cameraDolly, 1))
        uniforms.camPosFov = SIMD4(pose.position, tan(baseCamera.fovYRadians * 0.5))
        uniforms.camQuat = pose.orientation
        // Zoom (plan §6.3): resolved scale.zoom (integrator phase driven by
        // scale.zoomSpeed) → ScaleContext, THE scale derivation site.
        let scaleContext = ScaleContext(
            zoomOctaves: layout.slot(for: .scaleZoom).map { resolved.values[$0] } ?? 0,
            octave: octave)
        uniforms.scaleCtx = SIMD4(
            Float(clock.now), scaleContext.epsilonBase, scaleContext.modelScale, 1)
        uniforms.meta = SIMD4(
            UInt32(gpuOps.count), descriptor.index,
            UInt32(params.count), UInt32(deParamOffset))

        // World volatility (temporal-reconstruction plan): how hard the
        // world morphs THIS frame, measured on exactly what the GPU sees —
        // param table, ops, palette, scale context. Camera and time are
        // deliberately absent (reprojection explains the camera; time only
        // matters through the params it already moved). Paused ⇒ 0.
        let basis = WorldVolatility.Basis(
            params: params, deParamOffset: deParamOffset,
            ops: gpuOps, paletteStops: displayedPalette.stops,
            modelScale: scaleContext.modelScale,
            epsilonBase: scaleContext.epsilonBase)
        let worldVolatility: Float
        if paused {
            worldVolatility = 0
        } else if let previous = volatilityBasis {
            worldVolatility = WorldVolatility.measure(from: previous, to: basis)
        } else {
            worldVolatility = 0
        }
        volatilityBasis = basis

        frameIndex &+= 1
        return SessionFrame(
            request: RenderRequest(
                uniforms: uniforms, params: params, ops: gpuOps,
                // The GPU sees the crossfaded palette mid-transition; the
                // frame's `palette` below stays the AUTHORED one (what the
                // gradient editor shows and captureScene saves).
                palette: displayedPalette.stops, width: width, height: height,
                renderScale: renderScale, tuning: tuning,
                worldVolatility: worldVolatility),
            resolved: resolved,
            frameIndex: frameIndex,
            time: clock.now,
            deKey: descriptor.key,
            warpStack: authoredStack,
            paused: paused,
            palette: palette,
            animation: animationPlayer.playbackState,
            dynamicEntries: dynamicEntries,
            scaleOctave: octave,
            historyEpoch: historyEpoch,
            externalProgram: externalProgram,
            audioLevels: audioLevels)
    }

    /// Removes and returns the latched image-export request, if any.
    func takePendingImageCapture() -> (width: Int, height: Int, slot: ImageCaptureSlot)? {
        defer { pendingImageCapture = nil }
        return pendingImageCapture
    }

    // MARK: - Commands

    /// One log breadcrumb per drained command, so a frozen-session log shows
    /// what the user did leading up to it. Structural commands are low-rate →
    /// .info (memory ring, in every sysdiagnose); per-interaction commands →
    /// .debug (stream-only); continuous userEdit ticks are never logged.
    private func logCommand(_ command: SessionCommand) {
        let log = ThresholdLog.session
        switch command {
        case .userEdit:
            break  // per-tick during drags — too hot even for .debug
        case .applyScene(let envelope, let transition):
            let name = envelope.name ?? "untitled"
            log.info("""
                command: applyScene '\(name, privacy: .public)' \
                (\(transition == nil ? "snap" : "tween", privacy: .public))
                """)
        case .setDE(let key):
            log.info("command: setDE \(key, privacy: .public)")
        case .setExternalDE(let program):
            log.info("""
                command: setExternalDE \
                \(program == nil ? "nil (revert to built-in)" : "program", privacy: .public)
                """)
        case .setWarpStack(let stack):
            log.debug("command: setWarpStack (\(stack.count) ops)")
        case .clearUserEdit(let slot):
            log.debug("command: clearUserEdit slot \(slot)")
        case .commitUserEdit(let slot, _):
            log.debug("command: commitUserEdit slot \(slot)")
        case .clearLane(let lane):
            log.debug("command: clearLane \(String(describing: lane), privacy: .public)")
        case .setPaused(let isPaused):
            log.info("command: setPaused \(isPaused)")
        case .setBindings(let bindings):
            log.debug("command: setBindings (\(bindings.count))")
        case .setLFOs(let specs):
            log.debug("command: setLFOs (\(specs.count))")
        case .setPalette:
            log.debug("command: setPalette")
        case .setAnimationClip(let clip):
            let name = clip.map { $0.name ?? "unnamed" } ?? "nil (unload)"
            log.info("command: setAnimationClip \(name, privacy: .public)")
        case .animationTransport(let verb):
            log.info("command: animationTransport \(String(describing: verb), privacy: .public)")
        case .setQualityGovernor(let config):
            let desc = config.map { "target \($0.targetMilliseconds)ms" } ?? "off"
            log.info("command: setQualityGovernor \(desc, privacy: .public)")
        case .setRenderTuning:
            log.info("command: setRenderTuning")
        case .captureImage(let width, let height, _):
            log.info("command: captureImage \(width)x\(height)")
        case .captureScene:
            log.info("command: captureScene")
        }
    }

    private func handle(_ command: SessionCommand) {
        logCommand(command)
        switch command {
        case .applyScene(let envelope, let transition):
            apply(scene: envelope, transition: transition)
            historyEpoch &+= 1

        case .setDE(let key):
            // Swap the descriptor ONLY — lane state persists (plan §2.1:
            // scene switching never loses values). Unknown keys are ignored
            // (never trust-and-crash on the render thread).
            if let swapped = DERegistry.descriptor(forKey: key) {
                lastBuiltinDescriptor = swapped
                setExternal(nil)
                historyEpoch &+= 1
            }

        case .setExternalDE(let program):
            setExternal(program)
            historyEpoch &+= 1

        case .setWarpStack(let stack):
            setWarpStack(stack)

        case .userEdit(let slot, let target):
            // Grab-what-you-see: write the user-lane value whose composition
            // resolves to clamp(target) given every other lane's CURRENT
            // smoothed contribution (Inversion.swift).
            guard slot >= 0 && slot < layout.slotCount else { return }
            engine.write(
                lane: .user, slot: slot,
                value: Inversion.userLaneValue(toAchieve: target, slot: slot, in: engine))

        case .clearUserEdit(let slot):
            // Discard a momentary edit: revert to base instantly. A discard is
            // a one-shot command like commit (ADR-005) — it must not depend on
            // later frames landing to finish a glide, so it snaps rather than
            // eases. (Continuous FOLLOW during the drag itself still eases; it
            // is only the cancel that is immediate.)
            guard slot >= 0 && slot < layout.slotCount else { return }
            engine.clearLane(.user, slot: slot)

        case .commitUserEdit(let slot, let target):
            // Persist the edit into the authored scene lane (the only lane Save
            // captures — SceneCodec.snapshot), then release the momentary user
            // override. The commit is INSTANT on purpose (ADR-005): the live
            // drag already eased the resolved value to `target` via the user
            // lane's continuous smoothing, so baking `target` into the scene
            // lane and clearing user keeps the resolved value exactly where it
            // is — no post-commit motion, no dependency on extra frames landing
            // (a throttled/idle render loop must not strand a committed edit
            // mid-glide). sceneLaneValue keeps resolved at `target` given the
            // other transient lanes.
            guard slot >= 0 && slot < layout.slotCount else { return }
            engine.write(
                lane: .scene, slot: slot,
                value: Inversion.sceneLaneValue(toAchieve: target, slot: slot, in: engine))
            engine.clearLane(.user, slot: slot)

        case .clearLane(let lane):
            engine.clearLane(lane)

        case .setPaused(let isPaused):
            // Pause freezes the CLOCK only (smoothing, decay, integrators);
            // frames keep stepping and encoding so the image stays up and
            // instant-lane edits still land (Modulation.resolve doc).
            paused = isPaused
            clock.paused = isPaused

        case .setBindings(let bindings):
            bindingEngine.bindings = bindings

        case .setLFOs(let specs):
            lfoEngine.lfos = specs

        case .setPalette(let newPalette):
            palette = newPalette

        case .setAnimationClip(let clip):
            animationPlayer.setClip(clip)

        case .animationTransport(let verb):
            switch verb {
            case .play: animationPlayer.play()
            case .pause: animationPlayer.pause()
            case .stop: animationPlayer.stop()
            case .seek(let t): animationPlayer.seek(to: t)
            }

        case .setQualityGovernor(let config):
            governorConfig = config
            if config == nil {
                governor.reset()
            }

        case .setRenderTuning(let newTuning):
            tuning = newTuning

        case .captureImage(let width, let height, let slot):
            // Latched for the shell's frame loop: the request that renders
            // this export is the SAME one the next frame presents, just at
            // the export size (takePendingImageCapture).
            pendingImageCapture = (width: width, height: height, slot: slot)

        case .captureScene(let slot):
            // Authored content only: scene lane + structure. Transient lanes
            // (user/gesture/music) deliberately do not persist (Invariant 3).
            var envelope = SceneCodec.snapshot(
                layout: layout,
                engine: engine,
                fractalTypeKey: externalProgram != nil
                    ? lastBuiltinDescriptor.key : descriptor.key,
                warpStack: authoredStack,
                camera: camera,
                embeddedDE: externalProgram != nil ? activeEmbeddedDE : nil,
                abiVersion: EmbeddedDE.currentABIVersion)
            envelope.palette = palette
            // Camera is saved in the rebased world (the codec snapshotted the
            // matching rebased phase) — carry the depth counter alongside.
            envelope.scaleOctave = octave
            // Reactive content is scene-embedded (unlike the transient lanes):
            // the active bindings + LFO bank ARE authored content and save with
            // the scene.
            envelope.bindings = bindingEngine.bindings
            envelope.lfos = lfoEngine.lfos
            slot.publish(envelope)
        }
    }

    /// Activate (or with nil, deactivate) an external DE program: recycle any
    /// previous dynamic registrations, then register the new program's
    /// declared params into the arena so sliders/music/animation bind to them
    /// like built-ins (Invariant 5's spirit, CPU-side).
    private func setExternal(_ program: ExternalDEProgram?) {
        if !externalParamSlots.isEmpty {
            engine.unregisterDynamic(slots: externalParamSlots)
        }
        arena.reset()
        externalParamSlots = 0..<0
        dynamicEntries = []
        externalProgram = program
        descriptor = program?.descriptor ?? lastBuiltinDescriptor

        guard let d = program?.descriptor, !d.paramLayout.isEmpty else { return }
        guard let slots = arena.allocate(d.paramLayout.count) else {
            // Arena exhausted (256 slots — would take an absurd param list):
            // the DE still renders, at declared defaults (deValues fallback).
            return
        }
        for (i, param) in d.paramLayout.enumerated() {
            let spec = ParamSpec(
                key: .de(d.key, param.name),
                label: "\(d.displayName) \(param.name)",
                range: param.range,
                default: param.default,
                composition: .additive,
                smoothing: .continuous,  // same feel as built-ins (ADR-005)
                persistence: .scene,
                capabilities: [.musicBindable, .animatable],
                group: .shape)
            engine.registerDynamic(spec, atSlot: slots.lowerBound + i)
            dynamicEntries.append(CatalogEntry(slot: slots.lowerBound + i, spec: spec))
            // Scene-authored value (raw "de.external.<name>" params — the
            // offscreen harness convention) lands on the scene lane, exactly
            // as SceneCodec.apply would have if the key had been static.
            if let authored = lastSceneParams["de.external.\(param.name)"]?.first {
                engine.write(lane: .scene, slot: slots.lowerBound + i, value: authored)
            }
        }
        externalParamSlots = slots
    }

    private func apply(scene envelope: SceneEnvelope, transition: SceneTransition? = nil) {
        // Authoritative apply: scene lane only; user/gesture/music offsets
        // survive (Invariant 11).
        //
        // With a transition (ADR-005) the continuous params ease inside the
        // engine, and the two pieces of scene content the lanes don't carry —
        // the camera pose and the palette — tween HERE, on the same clock and
        // the same exponential. Everything structural (warp stack, DE, zoom
        // octave, discrete params) snaps, as the legacy app did.
        let tweening = transition.map { $0.duration > 0 && $0.duration.isFinite } ?? false
        if tweening, let transition {
            // Ease FROM whatever is displayed right now — mid-flight applies
            // re-aim rather than restart.
            cameraTween = CameraTween(
                current: displayedCamera,
                remaining: transition.duration,
                tau: transition.duration / 4)
            if let scenePalette = envelope.palette, scenePalette != palette {
                paletteTween = PaletteTween(
                    from: displayedPalette,
                    elapsed: 0,
                    duration: transition.duration,
                    tau: transition.duration / 4)
            } else {
                paletteTween = nil
            }
        } else {
            cameraTween = nil
            paletteTween = nil
        }
        SceneCodec.apply(envelope, layout: layout, engine: engine, transition: transition)
        setWarpStack(envelope.warpStack)
        camera = envelope.camera
        octave = envelope.scaleOctave
        // Palette is scene content; a scene without one keeps the current
        // palette rather than snapping to a default (Invariant 11 spirit).
        if let scenePalette = envelope.palette {
            palette = scenePalette
        }
        // Reactive content (scene-embedded): the scene owns its bindings + LFO
        // bank. Installed unconditionally (even when empty) so a scene is a
        // self-contained preset — loading one replaces the previous scene's
        // reactive behavior, like its warp stack and palette do.
        bindingEngine.bindings = envelope.bindings
        lfoEngine.lfos = envelope.lfos
        // Embedded DEs compile OFF this thread: the app shell runs
        // ExternalDELoader.load and follows the applyScene command with
        // setExternalDE. Until that lands, keep the current descriptor
        // (fractalTypeKey is ignored when embeddedDE is set).
        lastSceneParams = envelope.params
        activeEmbeddedDE = envelope.embeddedDE
        if envelope.embeddedDE == nil,
           let sceneDE = DERegistry.descriptor(forKey: envelope.fractalTypeKey) {
            lastBuiltinDescriptor = sceneDE
            setExternal(nil)
        }
    }

    /// Advance the scene-transition camera/palette tweens by one frame of
    /// content time (ADR-005). Same shape as the engine's scene-lane
    /// smoothing: exponential glide at τ = duration/4, exact landing when the
    /// window closes. `dt == 0` (paused) freezes mid-flight.
    private func advanceTweens(dt: Double) {
        if var tween = cameraTween {
            if dt > 0 {
                tween.remaining -= dt
                if tween.remaining <= 0 {
                    cameraTween = nil  // landed: displayedCamera == camera
                } else {
                    let alpha = Float(1 - exp(-dt / tween.tau))
                    tween.current = Self.eased(
                        from: tween.current, toward: camera, alpha: alpha)
                    cameraTween = tween
                }
            }
        }
        if var tween = paletteTween, dt > 0 {
            tween.elapsed += dt
            paletteTween = tween.elapsed >= tween.duration ? nil : tween
        }
    }

    /// One exponential step of a camera pose toward a target: position and
    /// fov lerp by `alpha`, orientation slerps by `alpha` along the shortest
    /// arc. Degenerate quaternions fall back to the target (same
    /// normalize-or-identity policy as CameraRig).
    private static func eased(
        from: CameraDTO, toward target: CameraDTO, alpha: Float
    ) -> CameraDTO {
        let p = zip(from.position, target.position).map { $0 + ($1 - $0) * alpha }
        let fov = from.fovYRadians + (target.fovYRadians - from.fovYRadians) * alpha

        func unitQuat(_ raw: [Float]) -> simd_quatf? {
            let v = SIMD4(raw[0], raw[1], raw[2], raw[3])
            let len = (v * v).sum().squareRoot()
            guard len > 1e-6, len.isFinite else { return nil }
            return simd_quatf(vector: v / len)
        }
        let orientation: [Float]
        if let q0 = unitQuat(from.orientation), var q1 = unitQuat(target.orientation) {
            // Shortest arc: q and -q are the same rotation; pick the near side.
            if simd_dot(q0.vector, q1.vector) < 0 {
                q1 = simd_quatf(vector: -q1.vector)
            }
            orientation = { let q = simd_slerp(q0, q1, alpha)
                            return [q.vector.x, q.vector.y, q.vector.z, q.vector.w] }()
        } else {
            orientation = target.orientation
        }
        return CameraDTO(position: p, orientation: orientation, fovYRadians: fov)
    }

    private func setWarpStack(_ stack: [WarpOpDTO]) {
        authoredStack = stack
        // Unknown kinds stay in the authored stack (round-trip preserved) but
        // are not rendered — same policy as the offscreen harness.
        let (raw, _) = [ThreshWarpOp].fromDTOs(stack)
        gpuOps = WarpSimplifier.simplify(raw)
    }
}

// MARK: - WorldVolatility

/// The temporal-reconstruction plan's world-morph scalar: how much of the
/// GPU-visible WORLD changed between two frames, [0, 1]. Fractal surfaces
/// morph under LFO/music modulation in ways camera reprojection cannot see —
/// this is measured HOST-side from the lane engine's own outputs (the one
/// place that knows the deltas) and discounts temporal history in the
/// resolve. Pure and value-typed so VolatilityTests pin it on the CPU.
enum WorldVolatility {
    struct Basis {
        var params: [Float]
        /// First DE-slice index in `params` — DE params morph geometry
        /// (weight 1); engine slots ahead of it are mostly shading
        /// (weight 0.25).
        var deParamOffset: Int
        var ops: [ThreshWarpOp]
        var paletteStops: [GradientStop]
        var modelScale: Float
        var epsilonBase: Float
    }

    /// `1 − exp(−8·V)` over the weighted relative deltas. An iteration-count
    /// step or any structural change (param-table shape, op count/kind,
    /// palette shape) is a hard cut (1) — the fractal is a different surface.
    static func measure(from prev: Basis, to cur: Basis) -> Float {
        let iterationsSlot = Int(THRESH_SLOT_ITERATIONS)
        guard prev.params.count == cur.params.count,
              prev.deParamOffset == cur.deParamOffset,
              prev.params.indices.contains(iterationsSlot),
              prev.params[iterationsSlot].rounded()
                  == cur.params[iterationsSlot].rounded()
        else { return 1 }

        func rel(_ a: Float, _ b: Float) -> Float {
            abs(a - b) / max(max(abs(a), abs(b)), 1e-3)
        }

        var v: Float = 0
        for i in cur.params.indices where i != iterationsSlot {
            let weight: Float = i >= cur.deParamOffset ? 1.0 : 0.25
            v += weight * rel(prev.params[i], cur.params[i])
        }

        if prev.ops.count != cur.ops.count {
            v += 1
        } else {
            for (p, c) in zip(prev.ops, cur.ops) {
                if p.kind != c.kind || p.flags != c.flags {
                    v += 1
                    continue
                }
                v += rel(p.strength, c.strength)
                for lane in 0..<4 {
                    v += rel(p.a[lane], c.a[lane])
                    v += rel(p.b[lane], c.b[lane])
                }
            }
        }

        v += 4 * abs(log2(max(cur.modelScale, 1e-9))
                     - log2(max(prev.modelScale, 1e-9)))
        v += 4 * abs(log2(max(cur.epsilonBase, 1e-12))
                     - log2(max(prev.epsilonBase, 1e-12)))

        if prev.paletteStops.count != cur.paletteStops.count {
            v += 1
        } else {
            var paletteDelta: Float = 0
            for (p, c) in zip(prev.paletteStops, cur.paletteStops) {
                paletteDelta += abs(p.position - c.position)
                    + abs(p.red - c.red)
                    + abs(p.green - c.green)
                    + abs(p.blue - c.blue)
            }
            v += 0.5 * paletteDelta
        }

        return 1 - exp(-8 * v)
    }
}
