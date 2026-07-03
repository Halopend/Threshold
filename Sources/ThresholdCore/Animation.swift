// Animation.swift — keyframe track data model + pure evaluation (plan §11
// phase 6; §3.2 animation-lane semantics). Tracks are DATA, like bindings:
// this file is the vocabulary and the math; AnimationPlayer.swift is the
// render-thread machine that turns evaluated values into animation-lane
// writes; AnimationCodec.swift is the .threshanim persistence envelope.
//
// Everything here is a Sendable value type and evaluation is a pure function
// of (track, time) — determinism for the harness comes for free.

import Foundation

// MARK: - Interpolation

/// How the segment LEAVING a keyframe interpolates toward the next one.
public enum KeyInterpolation: String, Sendable, Codable, Hashable {
    /// Hold this keyframe's value until the next keyframe time (discrete
    /// params: enums, toggles).
    case step
    case linear
    /// Smoothstep ease-in-out on the segment's normalized time.
    case smooth
}

// MARK: - Keyframe

/// One keyframe: a time (seconds, clip-local) and one value per param
/// component. `values.count` must equal the target param's slot width —
/// validated structurally when a clip is loaded, not trusted here.
public struct Keyframe: Sendable, Equatable, Codable {
    public var time: Double
    public var values: [Float]
    public var interpolation: KeyInterpolation

    public init(time: Double, values: [Float], interpolation: KeyInterpolation = .linear) {
        self.time = time
        self.values = values
        self.interpolation = interpolation
    }

    /// Scalar convenience.
    public init(time: Double, value: Float, interpolation: KeyInterpolation = .linear) {
        self.init(time: time, values: [value], interpolation: interpolation)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        values = try c.decode([Float].self, forKey: .values)
        // Unknown interpolation names from a newer writer degrade to linear
        // rather than failing the whole file (forward compatibility).
        interpolation =
            (try? c.decodeIfPresent(KeyInterpolation.self, forKey: .interpolation)) ?? .linear
    }
}

// MARK: - TrackMode

/// Whether a track's evaluated value replaces the parameter's base or rides
/// on top of it (plan §3.2: "a track declares whether it replaces the base or
/// offsets it").
public enum TrackMode: String, Sendable, Codable, Hashable {
    /// The evaluated value IS the target resolved-at-animation-stage value.
    /// The player converts it into the lane write that achieves it over the
    /// current base (scene-or-default).
    case absolute
    /// The evaluated value is written to the animation lane verbatim and
    /// composes per the param's `Composition` (additive offset,
    /// multiplicative factor, replace).
    case offset
}

// MARK: - AnimationTrack

/// Keyframes for one parameter. Keyframes are kept sorted by time; equal
/// times keep their authored order (later one wins at evaluation).
public struct AnimationTrack: Sendable, Equatable, Codable {
    public var param: ParamKey
    public var mode: TrackMode
    public private(set) var keyframes: [Keyframe]

    public init(param: ParamKey, mode: TrackMode = .absolute, keyframes: [Keyframe]) {
        self.param = param
        self.mode = mode
        self.keyframes = Self.sorted(keyframes)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        param = try c.decode(ParamKey.self, forKey: .param)
        // Unknown mode names from a newer writer degrade to .offset — the
        // conservative choice (an offset track can never yank a param away
        // from its base the way a misread absolute track could).
        mode = (try? c.decodeIfPresent(TrackMode.self, forKey: .mode)) ?? .offset
        keyframes = Self.sorted(try c.decode([Keyframe].self, forKey: .keyframes))
    }

    private static func sorted(_ keyframes: [Keyframe]) -> [Keyframe] {
        // Stable sort: Swift's sort is not documented stable, so decorate.
        keyframes.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    /// Latest keyframe time; 0 for an empty track.
    public var lastKeyTime: Double { keyframes.last?.time ?? 0 }

    /// Evaluate the track at clip-local time `t` (pure). Before the first
    /// keyframe → first values; after the last → last values; between two,
    /// the LEADING keyframe's interpolation shapes the segment. Returns nil
    /// for an empty track.
    public func value(at t: Double) -> [Float]? {
        guard !keyframes.isEmpty else { return nil }
        // Index of the last keyframe with time <= t (binary search).
        var lo = 0
        var hi = keyframes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keyframes[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        let after = lo  // first keyframe strictly after t
        guard after > 0 else { return keyframes[0].values }
        guard after < keyframes.count else { return keyframes[keyframes.count - 1].values }

        let a = keyframes[after - 1]
        let b = keyframes[after]
        let span = b.time - a.time
        guard span > 0 else { return b.values }

        let u = Float((t - a.time) / span)
        let w: Float
        switch a.interpolation {
        case .step: return a.values
        case .linear: w = u
        case .smooth: w = u * u * (3 - 2 * u)
        }
        // Component counts are validated at clip load; a malformed pair
        // (differing counts) blends over the shorter prefix rather than
        // trapping — never trust-and-crash on content.
        let n = min(a.values.count, b.values.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = a.values[i] + (b.values[i] - a.values[i]) * w
        }
        return out
    }
}

// MARK: - LoopMode

public enum LoopMode: String, Sendable, Codable, Hashable {
    /// Play to the end, hold the final pose, report finished.
    case once
    /// Wrap back to 0.
    case loop
    /// Bounce: 0 → duration → 0 → …
    case pingPong
}

// MARK: - AnimationClip

/// A named set of tracks with a duration and loop policy. Pure data.
public struct AnimationClip: Sendable, Equatable, Codable {
    public var name: String?
    public var loop: LoopMode
    /// Authored duration in seconds. If nil, the latest keyframe time across
    /// all tracks is used (see `effectiveDuration`).
    public var duration: Double?
    public var tracks: [AnimationTrack]

    public init(
        name: String? = nil,
        loop: LoopMode = .once,
        duration: Double? = nil,
        tracks: [AnimationTrack]
    ) {
        self.name = name
        self.loop = loop
        self.duration = duration
        self.tracks = tracks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        loop = (try? c.decodeIfPresent(LoopMode.self, forKey: .loop)) ?? .once
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        tracks = try c.decode([AnimationTrack].self, forKey: .tracks)
    }

    /// Authored duration if set (and positive/finite), else the latest
    /// keyframe time across tracks. Never negative or non-finite.
    public var effectiveDuration: Double {
        if let d = duration, d.isFinite, d > 0 { return d }
        let derived = tracks.map(\.lastKeyTime).max() ?? 0
        return derived.isFinite ? max(0, derived) : 0
    }

    /// Map an unbounded playhead onto clip-local time per the loop mode.
    /// A zero-duration clip always evaluates at 0.
    /// Returns (clipTime, finished) — finished is only ever true for `.once`.
    public func clipTime(forPlayhead t: Double) -> (time: Double, finished: Bool) {
        let d = effectiveDuration
        guard d > 0 else { return (0, loop == .once) }
        let clamped = max(0, t)
        switch loop {
        case .once:
            return (min(clamped, d), clamped >= d)
        case .loop:
            let r = clamped.truncatingRemainder(dividingBy: d)
            return (r, false)
        case .pingPong:
            let r = clamped.truncatingRemainder(dividingBy: 2 * d)
            return (r <= d ? r : 2 * d - r, false)
        }
    }
}
