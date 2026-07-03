// SessionContracts.swift — the seam between the interactive render session
// (render thread) and its clients (UI mirror, app shell). These types are the
// ONLY channels (Invariant 13): commands + lane mailbox in, snapshots out.

import Synchronization
import ThresholdCore

// MARK: - ConeStability

/// How far the cone-march prepass backs its shared tile start depth off the
/// surface — the shimmer↔speed lever. The hierarchical prepass starts every
/// pixel in a tile at one shared depth; near silhouettes those depths differ
/// sharply and jitter frame-to-frame (the "shimmer"). A higher margin leaves
/// the per-pixel march more refinement room, so fewer edge pixels lock onto
/// the tile depth — less shimmer, a few more steps. Each level is one cached
/// pipeline variant (function_constant 9), so it is discrete, not a slider.
public enum ConeStability: Int, Sendable, CaseIterable {
    case fast = 0       // 3× — the block-9 default (fastest, most shimmer)
    case balanced = 1   // 6×
    case stable = 2     // 12× (smoothest, slightly slower)

    /// The `margin × epsBase × t` multiplier baked into the prepass.
    public var margin: Int {
        switch self {
        case .fast: return 3
        case .balanced: return 6
        case .stable: return 12
        }
    }

    public var label: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .stable: return "Stable"
        }
    }
}

// MARK: - RenderTuning

/// Runtime-tunable render-pipeline knobs — the "advanced settings" the live
/// encoder consults each frame to choose a pipeline. Defaults reproduce the
/// pre-UI (env-only) behavior, so a build with no UI overrides renders exactly
/// as before. Sent in via `SessionCommand.setRenderTuning`.
public struct RenderTuning: Sendable, Equatable {
    /// Use the specialized (direct-call, inlined DE) pipeline variant once it
    /// has compiled. Off → always the generic table-dispatch pipeline (the
    /// A/B baseline). Lets the user SEE the specialization's effect on gpuMs.
    public var specializationEnabled: Bool
    /// Bake the resolved DE iteration count (function_constant 1) so the fold
    /// loop unrolls.
    public var bakeIterations: Bool
    /// Bake the march step cap (function_constant 2).
    public var bakeMaxSteps: Bool
    /// Bake warp-stack presence (function_constant 3): an empty stack DCEs the
    /// whole op interpreter out of the march.
    public var gateWarpOps: Bool
    /// Bake the color mapping mode (function_constant 4): drops the per-hit-
    /// pixel mapping switch.
    public var bakeColorMapMode: Bool
    /// Bake AO enablement (function_constant 5): skips the 5-tap AO when off.
    public var gateAO: Bool
    /// Hierarchical tile cone-march prepass (function_constant 8): a coarse
    /// dispatch finds each 8×8 tile's safe start depth before the per-pixel
    /// march (~2× on step-bound scenes, docs/perf-notes.md block 9). Changes
    /// marched output slightly (start points differ in float) — the toggle is
    /// the A/B lever.
    public var conePrepass: Bool
    /// Cone-prepass stability: how far the shared tile start depth backs off
    /// the surface (function_constant 9). Higher = less silhouette shimmer,
    /// slightly slower. Only meaningful with `conePrepass` on. Default `.fast`
    /// reproduces the block-9 hardcoded 3× margin.
    public var coneStability: ConeStability
    /// Manual internal render scale in (0, 1] used when the fps governor is
    /// OFF: the march runs at `drawable × scale` and MetalFX upscales to full
    /// resolution. 1 = full-res. Ignored while the governor drives the scale.
    public var manualRenderScale: Float

    public init(
        specializationEnabled: Bool = true, bakeIterations: Bool = false,
        bakeMaxSteps: Bool = false, gateWarpOps: Bool = false,
        bakeColorMapMode: Bool = false, gateAO: Bool = false,
        conePrepass: Bool = false, coneStability: ConeStability = .fast,
        manualRenderScale: Float = 1
    ) {
        self.specializationEnabled = specializationEnabled
        self.bakeIterations = bakeIterations
        self.bakeMaxSteps = bakeMaxSteps
        self.gateWarpOps = gateWarpOps
        self.bakeColorMapMode = bakeColorMapMode
        self.gateAO = gateAO
        self.conePrepass = conePrepass
        self.coneStability = coneStability
        self.manualRenderScale = manualRenderScale
    }

    /// The app's starting tuning; the UI overrides live. All function-constant
    /// bakes default ON: measured 2026-07 on Stress_test @1080p they are worth
    /// ~7% GPU (165.5 → 153.4 ms) with byte-identical output (the baked value
    /// IS the runtime value — marchSpec contract), and the generic pipeline
    /// still covers frames until the specialized variant finishes compiling.
    public static var envDefault: RenderTuning {
        RenderTuning(specializationEnabled: true,
                     bakeIterations: true, bakeMaxSteps: true,
                     gateWarpOps: true, bakeColorMapMode: true, gateAO: true,
                     conePrepass: true)
    }
}

// MARK: - RenderDiagnostics

/// What the live encoder actually did this frame — surfaced so the UI can SHOW
/// whether specialization is compiling / active (the "is it even compiling?"
/// readout). Read-only telemetry; carried on `RenderSnapshot`.
public struct RenderDiagnostics: Sendable, Equatable {
    public enum Pipeline: String, Sendable, Equatable {
        case generic         // table-dispatch, full-res
        case genericAux      // table-dispatch + temporal-upscale inputs
        case specialized     // direct-call inlined DE variant
        case specializedAux  // direct-call + temporal-upscale inputs
        case external        // an external DE program's own pipeline
        case raster          // visionOS Compositor stereo fragment path
        case viewCompute     // visionOS Compositor per-view COMPUTE backend

        public var label: String {
            switch self {
            case .generic:        return "Generic"
            case .genericAux:     return "Generic + Upscale"
            case .specialized:    return "Specialized"
            case .specializedAux: return "Specialized + Upscale"
            case .external:       return "External DE"
            case .raster:         return "Raster (visionOS)"
            case .viewCompute:    return "Compute (visionOS)"
            }
        }
        public var isSpecialized: Bool { self == .specialized || self == .specializedAux }
    }

    public var pipeline: Pipeline
    /// Specialization was requested (enabled, built-in DE) but its variant is
    /// still compiling off-thread — this frame fell back to generic.
    public var specializationPending: Bool
    /// Which function constants are baked into the active specialized variant
    /// (e.g. "iters=12, no-ops"); empty = none / not specialized.
    public var bakedConstants: String
    /// Internal render scale (governor × MetalFX); 1 = full-res.
    public var renderScale: Float
    /// MetalFX temporal upscaling engaged this frame.
    public var upscaling: Bool

    public init(
        pipeline: Pipeline = .generic, specializationPending: Bool = false,
        bakedConstants: String = "", renderScale: Float = 1, upscaling: Bool = false
    ) {
        self.pipeline = pipeline
        self.specializationPending = specializationPending
        self.bakedConstants = bakedConstants
        self.renderScale = renderScale
        self.upscaling = upscaling
    }
}

// MARK: - RenderSnapshot

/// What the render thread publishes after each frame. Immutable, Sendable —
/// the UI mirror and any recorder read this; nothing reads live lanes
/// (plan §3.3).
public struct RenderSnapshot: Sendable {
    public let resolved: ResolvedParams
    public let frameIndex: UInt64
    /// Session clock time (AppClock now, not wall time).
    public let time: Double
    /// Previous frame's GPU duration; 0 until the first frame completes.
    public let gpuMilliseconds: Double
    /// Previous frame's march-step total.
    public let totalSteps: UInt64
    public let deKey: String
    /// The AUTHORED warp stack (pre-simplification) — what editors display.
    public let warpStack: [WarpOpDTO]
    public let paused: Bool
    /// The active gradient palette — what the gradient editor displays.
    public let palette: Palette
    /// Animation transport state — what the play/scrub UI displays.
    public let animation: AnimationPlaybackState
    /// Dynamic-arena registrations (external DE params, plan phase 9): the
    /// UI renders rows for these exactly as for static layout entries. Empty
    /// when no external DE is active.
    public let dynamicEntries: [CatalogEntry]
    /// Zoom-rebase counter (plan §6.3) — total zoom depth in octaves is
    /// `Float(scaleOctave)` + the resolved `scale.zoom` value.
    public let scaleOctave: Int32
    /// What the live encoder did this frame (pipeline kind, compile status,
    /// render scale). Default on offscreen/test paths that don't specialize.
    public let diagnostics: RenderDiagnostics

    public init(
        resolved: ResolvedParams, frameIndex: UInt64, time: Double,
        gpuMilliseconds: Double, totalSteps: UInt64, deKey: String,
        warpStack: [WarpOpDTO], paused: Bool, palette: Palette,
        animation: AnimationPlaybackState = .idle,
        dynamicEntries: [CatalogEntry] = [],
        scaleOctave: Int32 = 0,
        diagnostics: RenderDiagnostics = RenderDiagnostics()
    ) {
        self.resolved = resolved
        self.frameIndex = frameIndex
        self.time = time
        self.gpuMilliseconds = gpuMilliseconds
        self.totalSteps = totalSteps
        self.deKey = deKey
        self.warpStack = warpStack
        self.paused = paused
        self.palette = palette
        self.animation = animation
        self.dynamicEntries = dynamicEntries
        self.scaleOctave = scaleOctave
        self.diagnostics = diagnostics
    }
}

// MARK: - SnapshotSlot

/// Single-slot latest-value handoff: render thread publishes, any thread
/// reads. Mutex-protected (a copy of a small value type under a short
/// critical section; the render thread never blocks on readers meaningfully).
public final class SnapshotSlot: Sendable {
    private let slot = Mutex<RenderSnapshot?>(nil)

    public init() {}

    public func publish(_ snapshot: RenderSnapshot) {
        slot.withLock { $0 = snapshot }
    }

    public var latest: RenderSnapshot? {
        slot.withLock { $0 }
    }
}

// MARK: - SceneCaptureSlot

/// Single-slot handoff for a scene capture: the render thread publishes the
/// snapshot envelope, the requesting thread polls `take()`. Same shape as
/// SnapshotSlot — command mailbox in, slot out (Invariant 13).
public final class SceneCaptureSlot: Sendable {
    private let slot = Mutex<SceneEnvelope?>(nil)

    public init() {}

    public func publish(_ envelope: SceneEnvelope) {
        slot.withLock { $0 = envelope }
    }

    /// Removes and returns the captured envelope, if one has landed.
    public func take() -> SceneEnvelope? {
        slot.withLock { captured in
            defer { captured = nil }
            return captured
        }
    }
}

// MARK: - ImageCaptureSlot

/// Single-slot handoff for a still-image capture: the render thread renders
/// the CURRENT frame's request offscreen at the requested size and publishes
/// the result; the requesting thread polls `take()`. Same shape as
/// SceneCaptureSlot — command mailbox in, slot out (Invariant 13).
public final class ImageCaptureSlot: Sendable {
    private let slot = Mutex<RenderResult?>(nil)

    public init() {}

    public func publish(_ result: RenderResult) {
        slot.withLock { $0 = result }
    }

    /// Removes and returns the captured image, if one has landed.
    public func take() -> RenderResult? {
        slot.withLock { captured in
            defer { captured = nil }
            return captured
        }
    }
}

// MARK: - SessionCommand

/// Structural changes, drained by the render thread at frame start so a
/// frame sees either the old structure or the new one, never a torn mix
/// (ARCHITECTURE.md §2). Continuous value changes do NOT go here — they go
/// through the lane mailbox (or `userEdit`, which needs engine state).
public enum SessionCommand: Sendable {
    /// Authoritative scene apply: scene lane + warp stack + DE + camera.
    case applyScene(SceneEnvelope)
    /// Switch the active DE; params keep their lane state (plan §2.1:
    /// scene switching never loses values). Clears any active external DE.
    case setDE(key: String)
    /// Activate a compiled+probed external DE program (nil reverts to the
    /// last built-in). Compilation is EXPENSIVE and must happen off the
    /// render thread — the app shell runs ExternalDELoader.load and sends
    /// the validated program here; the render thread only swaps a pointer.
    case setExternalDE(ExternalDEProgram?)
    /// Replace the authored warp stack.
    case setWarpStack([WarpOpDTO])
    /// Grab-what-you-see slider edit: the render thread computes the
    /// user-lane write that makes the resolved value equal `targetResolved`
    /// (inversion needs live engine state, which is render-thread confined).
    case userEdit(slot: Int, targetResolved: Float)
    /// End of a momentary interaction for one slot (slider release) that
    /// DISCARDS the edit — clears the user lane, reverting to the base.
    case clearUserEdit(slot: Int)
    /// Commit a slider/toggle edit: bake the resolved target into the authored
    /// SCENE lane (so it persists AND is captured by Save), then release the
    /// momentary user override. The resolved value is unchanged across the
    /// swap (grab-what-you-see continuity) — this is the normal slider-release
    /// path, replacing the revert-on-release `clearUserEdit`.
    case commitUserEdit(slot: Int, targetResolved: Float)
    case clearLane(Lane)
    case setPaused(Bool)
    /// Replace the active binding set (bindings are data — plan §4.2).
    case setBindings([Binding])
    /// Replace the active gradient palette (scene content — plan §5.5).
    case setPalette(Palette)
    /// Load (or unload with nil) the animation clip. Loading leaves the
    /// transport stopped; follow with `.animationTransport(.play)`.
    case setAnimationClip(AnimationClip?)
    /// Animation transport (plan §3.2: stop zeroes the animation lane;
    /// user/gesture/music offsets survive).
    case animationTransport(AnimationTransportCommand)
    /// Capture the AUTHORED scene (scene-lane catalog walk + warp stack +
    /// camera + palette + embedded DE) into the slot — the native save path.
    /// Snapshotting needs live engine state, which is render-thread confined.
    case captureScene(into: SceneCaptureSlot)
    /// Render the CURRENT frame's request offscreen at the given size and
    /// publish the pixels into the slot (image export). Consumed by live
    /// shells that build per-frame requests (InteractiveSession); the
    /// compositor shell ignores it (no flat 2D frame exists there).
    case captureImage(width: Int, height: Int, into: ImageCaptureSlot)
    /// Enable (or with nil, disable) the fps-holding quality governor
    /// (ADR-003): a registered system-lane writer emitting a 0…1 factor on
    /// the quality-class params. Disabling clears its lane writes.
    case setQualityGovernor(QualityGovernorConfig?)
    /// Replace the live render-pipeline tuning (specialization on/off,
    /// iteration bake). Read by the encoder via the frame's RenderRequest.
    case setRenderTuning(RenderTuning)
}

/// Transport verbs for the animation player, as session-command data.
public enum AnimationTransportCommand: Sendable, Equatable {
    case play
    case pause
    case stop
    case seek(Double)
}

// MARK: - FrameStatsSlot

/// Latest completed-frame GPU stats. Compiler-checked Sendable (a Mutex over
/// a POD) — written by Metal's completion-handler thread, read by the render
/// thread at frame start. Shared by every live shell (display-link and
/// Compositor).
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
