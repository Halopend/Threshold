// SessionContracts.swift — the seam between the interactive render session
// (render thread) and its clients (UI mirror, app shell). These types are the
// ONLY channels (Invariant 13): commands + lane mailbox in, snapshots out.

import Synchronization
import ThresholdCore

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

    public init(
        resolved: ResolvedParams, frameIndex: UInt64, time: Double,
        gpuMilliseconds: Double, totalSteps: UInt64, deKey: String,
        warpStack: [WarpOpDTO], paused: Bool, palette: Palette,
        animation: AnimationPlaybackState = .idle,
        dynamicEntries: [CatalogEntry] = []
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
    /// End of a momentary interaction for one slot (slider release).
    case clearUserEdit(slot: Int)
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
}

/// Transport verbs for the animation player, as session-command data.
public enum AnimationTransportCommand: Sendable, Equatable {
    case play
    case pause
    case stop
    case seek(Double)
}
