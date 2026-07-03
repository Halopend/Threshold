// AnimationPlayer.swift — the render-thread machine that evaluates the loaded
// clip each frame and writes the ANIMATION lane (plan §3.2, §11 phase 6).
//
// Lane semantics (plan §3.2): the animation lane is evaluated from tracks
// each frame; a track declares absolute-vs-offset (TrackMode). STOPPING
// playback zeroes the lane — user/gesture/music offsets are untouched, so
// "music survives animation playback" holds by construction.
//
// Concurrency (ADR-004, same confinement pattern as BindingEngine): final
// class, deliberately NOT Sendable, render-thread confined. Clip loads and
// transport arrive through the session command mailbox between frames.
//
// Capabilities note: like BindingEngine, the player does not gate on
// `Capabilities.animatable` — capability flags drive what the UI OFFERS
// (plan §2.2), not what the engine executes. Structural validation (unknown
// key, component-count mismatch) skips the track and is surfaced via
// `lastSkippedCount`, never a crash.

/// Immutable per-frame playback state — what the UI transport shows
/// (published inside RenderSnapshot; nothing reads the live player).
public struct AnimationPlaybackState: Sendable, Equatable {
    public let hasClip: Bool
    public let clipName: String?
    /// Clip-local time (post loop mapping), seconds.
    public let time: Double
    public let duration: Double
    public let isPlaying: Bool
    public let isFinished: Bool

    public static let idle = AnimationPlaybackState(
        hasClip: false, clipName: nil, time: 0, duration: 0,
        isPlaying: false, isFinished: false)

    public init(
        hasClip: Bool, clipName: String?, time: Double, duration: Double,
        isPlaying: Bool, isFinished: Bool
    ) {
        self.hasClip = hasClip
        self.clipName = clipName
        self.time = time
        self.duration = duration
        self.isPlaying = isPlaying
        self.isFinished = isFinished
    }
}

public final class AnimationPlayer {
    public let layout: CatalogLayout

    /// Playback transport state.
    public enum Transport: Sendable, Equatable {
        /// No clip loaded, or stopped: lane cleared, playhead at 0.
        case stopped
        case playing
        /// Playhead frozen; the lane holds the current pose (still written
        /// each frame, so a seek while paused updates the image).
        case paused
    }

    public private(set) var transport: Transport = .stopped
    /// Unbounded playhead in clip seconds; loop mapping happens at evaluation.
    public private(set) var playhead: Double = 0
    public private(set) var clip: AnimationClip?
    /// True once a `.once` clip has reached its end (pose holds; call `stop()`
    /// or `seek` to move on).
    public private(set) var isFinished = false
    /// Tracks in the current clip that could not be executed (unknown param
    /// key, component-count mismatch, or no keyframes).
    public private(set) var lastSkippedCount = 0

    /// One executable track with its param key pre-resolved to slots.
    private struct CachedTrack {
        let track: AnimationTrack
        let slot: Int
        let width: Int
    }

    private var cache: [CachedTrack] = []

    public init(layout: CatalogLayout) {
        self.layout = layout
    }

    // MARK: - Transport

    /// Load a clip (or nil to unload). Resets the playhead to 0 and leaves
    /// the transport STOPPED — the previous clip's lane slots are released by
    /// the next `step` (stop semantics below).
    public func setClip(_ newClip: AnimationClip?) {
        clip = newClip
        playhead = 0
        isFinished = false
        transport = .stopped
        scheduleLaneClear()  // releases the OLD clip's slots — before rebuild
        rebuildCache()
    }

    public func play() {
        guard clip != nil else { return }
        // Re-playing a finished `.once` clip restarts it.
        if isFinished {
            playhead = 0
            isFinished = false
        }
        transport = .playing
    }

    public func pause() {
        if transport == .playing { transport = .paused }
    }

    /// Stop: playhead to 0, lane released on the next `step` (plan §3.2
    /// "stopping playback zeroes the lane").
    public func stop() {
        playhead = 0
        isFinished = false
        transport = .stopped
        scheduleLaneClear()
    }

    /// Move the playhead. Implies pause when stopped (a seek means the user
    /// wants to see that pose); playing playback keeps playing.
    public func seek(to t: Double) {
        guard clip != nil, t.isFinite else { return }
        playhead = max(0, t)
        isFinished = false
        if transport == .stopped {
            transport = .paused
        }
    }

    /// Slot ranges owed a lane clear on the next `step` — captured at the
    /// moment of stop/unload so a subsequent clip swap cannot redirect the
    /// clear onto the wrong slots. Pending clears are never cancelled: they
    /// run at the TOP of `step`, before this frame's writes, so a
    /// stop-then-play in the same command batch still resolves to the pose.
    private var pendingClearSlots: [Range<Int>] = []

    private func scheduleLaneClear() {
        pendingClearSlots = cache.map { $0.slot..<($0.slot + $0.width) }
    }

    // MARK: - Frame

    /// One frame. Call on the render thread BEFORE `engine.resolve()`.
    /// `scaledDelta` is content time: `clock.delta * clock.timeScale`, 0 while
    /// paused (Invariant 9: the caller owns the clock; the player never reads
    /// time itself).
    public func step(engine: ModulationEngine, scaledDelta: Double) {
        if !pendingClearSlots.isEmpty {
            // Release ONLY this player's slots — the animation lane is shared
            // in principle (a future second writer must not be stomped), and
            // per-slot clears keep the release scoped to the clip that wrote.
            for range in pendingClearSlots {
                for slot in range {
                    engine.clearLane(.animation, slot: slot)
                }
            }
            pendingClearSlots = []
        }

        guard let clip, transport != .stopped else { return }

        if transport == .playing, scaledDelta > 0 {
            playhead += scaledDelta
        }

        let (t, finished) = clip.clipTime(forPlayhead: playhead)
        if finished, transport == .playing {
            transport = .paused  // hold the final pose
            isFinished = true
        }

        for cached in cache {
            guard let values = cached.track.value(at: t) else { continue }
            for i in 0..<min(values.count, cached.width) {
                let slot = cached.slot + i
                let write: Float
                switch cached.track.mode {
                case .offset:
                    write = values[i]
                case .absolute:
                    write = absoluteLaneValue(values[i], slot: slot, engine: engine)
                }
                engine.write(lane: .animation, slot: slot, value: write)
            }
        }
    }

    /// Convert an absolute target into the animation-lane write that achieves
    /// it over the current base (scene-or-default). Same shape as
    /// `Inversion.userLaneValue`, but only base composes BEFORE the animation
    /// lane (Invariant 16), so only base is inverted out.
    private func absoluteLaneValue(
        _ target: Float, slot: Int, engine: ModulationEngine
    ) -> Float {
        guard let composition = engine.compositionForSlot(slot) else { return target }
        switch composition {
        case .replace:
            return target
        case .additive:
            return target - engine.baseValue(slot: slot)
        case .multiplicative:
            let base = engine.baseValue(slot: slot)
            guard abs(base) > 1e-6 else { return 1 }  // not invertible → neutral
            return target / base
        }
    }

    // MARK: - State

    /// Current playback state as an immutable value (for snapshots).
    public var playbackState: AnimationPlaybackState {
        guard let clip else { return .idle }
        let (t, _) = clip.clipTime(forPlayhead: playhead)
        return AnimationPlaybackState(
            hasClip: true,
            clipName: clip.name,
            time: t,
            duration: clip.effectiveDuration,
            isPlaying: transport == .playing,
            isFinished: isFinished)
    }

    // MARK: - Cache

    private func rebuildCache() {
        cache.removeAll(keepingCapacity: true)
        var skips = 0
        guard let clip else {
            lastSkippedCount = 0
            return
        }
        for track in clip.tracks {
            guard let entry = layout.entry(for: track.param) else {
                skips += 1
                continue
            }
            let width = entry.kind.slotWidth
            guard !track.keyframes.isEmpty,
                track.keyframes.allSatisfy({ $0.values.count == width })
            else {
                skips += 1
                continue
            }
            cache.append(CachedTrack(track: track, slot: entry.slot, width: width))
        }
        lastSkippedCount = skips
    }
}
