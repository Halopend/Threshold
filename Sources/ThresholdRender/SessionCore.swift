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
    private(set) var paused = false
    /// Active gradient palette (scene content). Defaults to the renderer's
    /// built-in stops until a scene or `setPalette` command replaces it.
    private(set) var palette = Palette(stops: PaletteWire.defaultStops)
    private var frameIndex: UInt64 = 0

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
        var renderScale: Float = 1
        if let config = governorConfig {
            let factor = governor.update(gpuMilliseconds: gpuMilliseconds, config: config)
            renderScale = min(max(sqrt(factor), config.minRenderScale), 1)
            renderScale = (renderScale * 20).rounded() / 20
        }

        clock.update(now: timestamp)

        signals.publish(
            id: .appTime,
            value: SIMD4(Float(clock.now), 0, 0, 0),
            confidence: 1,
            timestamp: clock.now)

        bindingEngine.apply(signals: signals, engine: engine, now: clock.now)

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
        // lane values on camera.* params).
        var uniforms = ThreshFrameUniforms()
        func rigValue(_ key: ParamKey, _ fallback: Float) -> Float {
            layout.slot(for: key).map { resolved.values[$0] } ?? fallback
        }
        let pose = CameraRig.pose(
            base: camera,
            yaw: rigValue(.cameraOrbitYaw, 0),
            pitch: rigValue(.cameraOrbitPitch, 0),
            dolly: rigValue(.cameraDolly, 1))
        uniforms.camPosFov = SIMD4(pose.position, tan(camera.fovYRadians * 0.5))
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

        frameIndex &+= 1
        return SessionFrame(
            request: RenderRequest(
                uniforms: uniforms, params: params, ops: gpuOps,
                palette: palette.stops, width: width, height: height,
                renderScale: renderScale, tuning: tuning),
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
            externalProgram: externalProgram)
    }

    // MARK: - Commands

    private func handle(_ command: SessionCommand) {
        switch command {
        case .applyScene(let envelope):
            apply(scene: envelope)

        case .setDE(let key):
            // Swap the descriptor ONLY — lane state persists (plan §2.1:
            // scene switching never loses values). Unknown keys are ignored
            // (never trust-and-crash on the render thread).
            if let swapped = DERegistry.descriptor(forKey: key) {
                lastBuiltinDescriptor = swapped
                setExternal(nil)
            }

        case .setExternalDE(let program):
            setExternal(program)

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
            guard slot >= 0 && slot < layout.slotCount else { return }
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

    private func apply(scene envelope: SceneEnvelope) {
        // Authoritative apply: scene lane only; user/gesture/music offsets
        // survive (Invariant 11).
        SceneCodec.apply(envelope, layout: layout, engine: engine)
        setWarpStack(envelope.warpStack)
        camera = envelope.camera
        octave = envelope.scaleOctave
        // Palette is scene content; a scene without one keeps the current
        // palette rather than snapping to a default (Invariant 11 spirit).
        if let scenePalette = envelope.palette {
            palette = scenePalette
        }
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

    private func setWarpStack(_ stack: [WarpOpDTO]) {
        authoredStack = stack
        // Unknown kinds stay in the authored stack (round-trip preserved) but
        // are not rendered — same policy as the offscreen harness.
        let (raw, _) = [ThreshWarpOp].fromDTOs(stack)
        gpuOps = WarpSimplifier.simplify(raw)
    }
}
