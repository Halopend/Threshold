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

    private(set) var descriptor: DEDescriptor
    /// The AUTHORED warp stack — what snapshots/editors show.
    private(set) var authoredStack: [WarpOpDTO] = []
    /// The simplified buffer the GPU sees (plan §5.2). Rebuilt only on
    /// structural change, not per frame.
    private(set) var gpuOps: [ThreshWarpOp] = []
    private(set) var camera: CameraDTO = .default
    private(set) var paused = false
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
        self.descriptor = DERegistry.descriptor(forKey: defaultDEKey) ?? .mandelbulb
        if let scene = initialScene {
            apply(scene: scene)
        }
    }

    // MARK: - Frame

    /// One frame. `now` is the display link's targetTimestamp — the ONE
    /// permitted time source; `width`/`height` are the drawable's ACTUAL size
    /// this frame (resize follows the drawable, not a cached value).
    func step(now timestamp: Double, width: Int, height: Int) -> SessionFrame {
        for command in commands.drain() {
            handle(command)
        }

        clock.update(now: timestamp)

        signals.publish(
            id: .appTime,
            value: SIMD4(Float(clock.now), 0, 0, 0),
            confidence: 1,
            timestamp: clock.now)

        bindingEngine.apply(signals: signals, engine: engine, now: clock.now)

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
        let deValues = descriptor.paramLayout.map { param -> Float in
            // A DE whose params were never registered (defensive: the app
            // shell registers every built-in at startup) renders at declared
            // defaults rather than crashing the render thread.
            layout.slot(for: .de(descriptor.key, param.name))
                .map { resolved.values[$0] } ?? param.default
        }
        let (params, deParamOffset) = ParamTableLayout.build(
            engine: engineParams, deParams: deValues)

        // Uniforms from the session camera (same construction as the harness;
        // degenerate quaternions fall back to identity).
        var uniforms = ThreshFrameUniforms()
        uniforms.camPosFov = SIMD4(
            camera.position[0], camera.position[1], camera.position[2],
            tan(camera.fovYRadians * 0.5))
        let rawQuat = SIMD4(
            camera.orientation[0], camera.orientation[1],
            camera.orientation[2], camera.orientation[3])
        let quatLength = (rawQuat * rawQuat).sum().squareRoot()
        uniforms.camQuat = quatLength > 1e-6 && quatLength.isFinite
            ? rawQuat / quatLength
            : SIMD4(0, 0, 0, 1)
        uniforms.scaleCtx = SIMD4(Float(clock.now), 1e-3, 1, 1)
        uniforms.meta = SIMD4(
            UInt32(gpuOps.count), descriptor.index,
            UInt32(params.count), UInt32(deParamOffset))

        frameIndex &+= 1
        return SessionFrame(
            request: RenderRequest(
                uniforms: uniforms, params: params, ops: gpuOps,
                width: width, height: height),
            resolved: resolved,
            frameIndex: frameIndex,
            time: clock.now,
            deKey: descriptor.key,
            warpStack: authoredStack,
            paused: paused)
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
                descriptor = swapped
            }

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
        }
    }

    private func apply(scene envelope: SceneEnvelope) {
        // Authoritative apply: scene lane only; user/gesture/music offsets
        // survive (Invariant 11).
        SceneCodec.apply(envelope, layout: layout, engine: engine)
        setWarpStack(envelope.warpStack)
        camera = envelope.camera
        // Embedded DEs need the probe/compile path (ARCHITECTURE.md §4) —
        // not wired yet; the envelope contract says fractalTypeKey is ignored
        // when embeddedDE is set, so keep the current descriptor rather than
        // silently rendering the wrong DE.
        if envelope.embeddedDE == nil,
           let sceneDE = DERegistry.descriptor(forKey: envelope.fractalTypeKey) {
            descriptor = sceneDE
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
