// ParamTypes.swift — the small value vocabulary of the parameter system
// (plan §2.1, ARCHITECTURE.md §3).
//
// Everything here is a Sendable value type: these cross threads freely inside
// specs, layouts, and snapshots.

// MARK: - ParamKey

/// Stable, hierarchical string identity of a parameter (`"shape.boxFold.limit"`).
///
/// Invariant 14: `ParamKey`s are DECLARED CONSTANTS or FACTORY-CONSTRUCTED —
/// never ad-hoc interpolated strings at call sites. All static keys live in
/// one file per namespace so the migration table (plan §7.3) diffs cleanly.
/// The only sanctioned dynamic constructions are the factories below
/// (`ParamKey.warp(slot:field:)`, `ParamKey.de(_:_:)`). A raw-string `init`
/// exists because Codable and migration tables need it; feature code must not
/// use it for new keys.
public struct ParamKey: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Factory for warp-stack slot fields: `"warp.slot{N}.{field}"`.
    /// (Invariant 14 — the ONLY way to mint warp-slot keys.)
    public static func warp(slot: Int, field: String) -> ParamKey {
        ParamKey("warp.slot\(slot).\(field)")
    }

    /// Factory for DE parameters: `"de.{deKey}.{name}"`.
    /// (Invariant 14 — the ONLY way to mint DE param keys.)
    public static func de(_ deKey: String, _ name: String) -> ParamKey {
        ParamKey("de.\(deKey).\(name)")
    }

    public var description: String { rawValue }
}

// MARK: - Lane

/// Modulation lanes. RAW VALUE ORDER IS COMPOSITION ORDER (Invariant 16):
/// `scene ▷ animation ▷ system ▷ user ▷ gesture ▷ music`, global and fixed.
///
/// `system` sits between `animation` and `user` (ADR-003): only registered
/// automated non-user writers (quality governor, safety caps, platform caps)
/// may write it. `gesture` and `music` are the transient lanes (Invariant 3):
/// they are never folded into base state.
public enum Lane: Int, CaseIterable, Sendable, Codable, Comparable, Hashable {
    case scene = 0
    case animation = 1
    case system = 2
    case user = 3
    case gesture = 4
    case music = 5

    /// Composition order: lower composes first.
    public static func < (lhs: Lane, rhs: Lane) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Composition

/// How a lane's value composes onto the accumulated result (plan §3.1).
///
/// Lane-neutral values: additive `0`, multiplicative `1`, replace has no
/// numeric neutral — an unset replace lane simply does not participate.
public enum Composition: String, Sendable, Codable, Hashable {
    /// Lane value is added: offsets on top of base.
    case additive
    /// Lane value multiplies: scale-like params; ADR-003 quality-class params
    /// declare this so a governor's `system` write is a 0…1 factor the user
    /// can lower past but not raise.
    case multiplicative
    /// Lane value replaces the accumulated value (enums, toggles).
    case replace
}

// MARK: - Persistence

/// Per-param persistence policy (plan §2.1 — per-param, never per-struct).
public enum Persistence: String, Sendable, Codable, Hashable {
    /// Serialized into scene/preset files.
    case scene
    /// Persisted on this device only (e.g. quality/acceleration settings).
    case deviceLocal
    /// Never persisted (e.g. integrator phases by default).
    case transient
}

// MARK: - Capabilities

/// What derived systems may attach to this parameter (plan §2.2).
public struct Capabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let musicBindable = Capabilities(rawValue: 1 << 0)
    public static let gestureBindable = Capabilities(rawValue: 1 << 1)
    public static let animatable = Capabilities(rawValue: 1 << 2)
    /// Exposed only after an explicit user opt-in (e.g. photosensitivity-risk
    /// or custom-content params).
    public static let requiresOptIn = Capabilities(rawValue: 1 << 3)
}

// MARK: - ResponseCurve

/// UI / binding mapping metadata ONLY. A slider or a music binding maps its
/// normalized input through this curve into the param's range. It is NOT
/// applied during lane resolution — lane values are already in param units.
public enum ResponseCurve: Sendable, Codable, Hashable {
    case linear
    case exp(k: Float)
    case sCurve
}

// MARK: - Smoothing

/// Per-lane exponential smoothing time constants, in seconds. `0` = instant
/// (the lane's current value jumps to its target at resolve).
///
/// The resolver moves each lane's smoothed value toward its target by
/// `alpha = 1 - exp(-dt/tau)` per frame (plan §3.3); the music lane uses its
/// tau both for attack and for its always-on decay toward neutral.
public struct Smoothing: Sendable, Codable, Hashable {
    public var scene: Double
    public var animation: Double
    public var system: Double
    public var user: Double
    public var gesture: Double
    public var music: Double

    public init(
        scene: Double = 0,
        animation: Double = 0,
        system: Double = 0,
        user: Double = 0,
        gesture: Double = 0,
        music: Double = 0
    ) {
        self.scene = scene
        self.animation = animation
        self.system = system
        self.user = user
        self.gesture = gesture
        self.music = music
    }

    /// The standard feel: user/scene/system/animation instant,
    /// gesture 0.15 s, music 0.08 s.
    public static let `default` = Smoothing(gesture: 0.15, music: 0.08)

    /// All lanes instant. Useful for tests and discrete params.
    public static let instant = Smoothing()

    public func tau(for lane: Lane) -> Double {
        switch lane {
        case .scene: return scene
        case .animation: return animation
        case .system: return system
        case .user: return user
        case .gesture: return gesture
        case .music: return music
        }
    }
}

// MARK: - GroupID

/// UI section placement (plan §2.1).
public struct GroupID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let shape = GroupID("shape")
    public static let color = GroupID("color")
    public static let camera = GroupID("camera")
    public static let performance = GroupID("performance")

    public var description: String { rawValue }
}
