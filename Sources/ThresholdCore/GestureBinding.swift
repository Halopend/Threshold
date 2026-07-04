// GestureBinding.swift — the pure value vocabulary that maps a hand gesture
// onto a bindable parameter (the rebuild's port of the legacy
// GestureSlot/GestureActionBinding model, generalized).
//
// Everything here is a Sendable value type over `ParamKey`, so the SAME model
// serves built-in `.float3` params and externally-authored flat scalars alike
// (external DE params surface as ParamKey-addressed CatalogEntries — see
// SessionCore.setExternal). Gesture DETECTION (ARKit, visionOS) and the
// binding EDITOR (SwiftUI) both consume this; neither owns it.
//
// Persistence philosophy matches SceneEnvelope: a table is stored as
// `[persistenceKey: GestureBinding]` with STRING keys, so unknown/foreign
// source keys survive a decode→encode round-trip on a future build (forward
// compatibility — orientation gestures land later without breaking old files).

// MARK: - Physical vocabulary

/// Which hand a gesture uses.
public enum GestureHand: String, Sendable, Codable, Hashable, CaseIterable {
    case left
    case right
}

/// A non-thumb digit. The thumb is the anchor the other fingers tap against
/// (`tapThumb`), so it is never itself a source finger.
public enum GestureFinger: String, Sendable, Codable, Hashable, CaseIterable {
    case index
    case middle
    case ring
    case pinky
}

/// A spatial axis. Legacy called these vertical/horizontal/depth; the rebuild
/// names them by the parameter component they drive so grouped `.float3`
/// binding reads directly (x→x, y→y, z→z).
public enum GestureAxis: String, Sendable, Codable, Hashable, CaseIterable {
    case x
    case y
    case z

    /// Component offset into a `.float3` param's slot range.
    public var component: Int {
        switch self {
        case .x: return 0
        case .y: return 1
        case .z: return 2
        }
    }
}

// MARK: - GestureSource

/// A physical gesture channel a binding attaches to.
///
/// Each case reports an `arity`: a `.vector` source yields a 3D delta (so it
/// can drive a whole `.float3` or split across three scalar params); a
/// `.scalar` source yields one value (touch strength, closure, speed).
///
/// The `orient` family (a hand's rotation → x/y/z of a param) is intentionally
/// absent for now — it is a future `.vector` source that slots in beside
/// `swipe` without a model change (the reason the target model is arity-typed
/// rather than hard-coded to fingers).
public enum GestureSource: Sendable, Hashable, Codable {
    /// A finger tip pinched to the thumb, then dragged in space — a 3D drag
    /// (legacy "tap to thumb"). Vector.
    case tapThumb(hand: GestureHand, finger: GestureFinger)
    /// A finger tapped to the palm — one of the four palm drop-points. A
    /// momentary/continuous touch strength. Scalar.
    case tapPalm(hand: GestureHand, finger: GestureFinger)
    /// The whole hand swiped through the air — a 3D velocity. Vector.
    case swipe(hand: GestureHand)
    /// A closed fist — closure amount 0…1. Scalar.
    case fist(hand: GestureHand)

    /// Whether this source produces a 3D delta or a single scalar.
    public var arity: GestureArity {
        switch self {
        case .tapThumb, .swipe: return .vector
        case .tapPalm, .fist: return .scalar
        }
    }
}

/// The dimensionality of a source's output — the constraint a binding must
/// satisfy (a `.scalar` source cannot drive a `.float3` param wholesale).
public enum GestureArity: Sendable, Hashable {
    case scalar
    case vector
}

// MARK: - GestureSource persistence key

extension GestureSource {
    /// Stable string identity for on-disk storage (`"R.index.tapThumb"`).
    /// Mirrors legacy `GestureSlot.persistenceKey`; the ONLY sanctioned way to
    /// key a `GestureBindingTable`'s dictionary so JSON stays legible and
    /// forward-compatible.
    public var persistenceKey: String {
        switch self {
        case let .tapThumb(hand, finger): return "\(hand.tag).\(finger.rawValue).tapThumb"
        case let .tapPalm(hand, finger): return "\(hand.tag).\(finger.rawValue).tapPalm"
        case let .swipe(hand): return "\(hand.tag).swipe"
        case let .fist(hand): return "\(hand.tag).fist"
        }
    }

    /// Reconstruct a source from its `persistenceKey`. Returns nil for keys a
    /// future build minted (they are preserved verbatim by the table, not
    /// dropped — see `GestureBindingTable`).
    public init?(persistenceKey key: String) {
        let parts = key.split(separator: ".").map(String.init)
        guard let hand = parts.first.flatMap(GestureHand.init(tag:)) else { return nil }
        switch parts.count {
        case 2 where parts[1] == "swipe": self = .swipe(hand: hand)
        case 2 where parts[1] == "fist": self = .fist(hand: hand)
        case 3:
            guard let finger = GestureFinger(rawValue: parts[1]) else { return nil }
            switch parts[2] {
            case "tapThumb": self = .tapThumb(hand: hand, finger: finger)
            case "tapPalm": self = .tapPalm(hand: hand, finger: finger)
            default: return nil
            }
        default: return nil
        }
    }
}

private extension GestureHand {
    var tag: String { self == .left ? "L" : "R" }
    init?(tag: String) {
        switch tag {
        case "L": self = .left
        case "R": self = .right
        default: return nil
        }
    }
}

// MARK: - Vec3Target

/// Where a `.vector` source's 3D delta goes.
///
/// The two cases are exactly the "grouped and named x/y/z all at once" vs.
/// "individual parameters to x/y/z" distinction: `.native` is a built-in (or
/// external) `.float3` param bound whole; `.grouped` binds three independent
/// scalar params — either an auto-detected external triple (`Vec3Group`) or an
/// ad-hoc mix the user assembled per axis. Any grouped axis may be nil
/// (unassigned), so a half-built triple round-trips cleanly.
public enum Vec3Target: Sendable, Hashable, Codable {
    /// A single `.float3` parameter driven by all three axes.
    case native(ParamKey)
    /// Three scalar parameters, one per axis (any may be unassigned).
    case grouped(x: ParamKey?, y: ParamKey?, z: ParamKey?)

    /// The scalar key driving a given axis (`.native` returns nil — it has no
    /// per-axis keys; the caller drives the float3's component directly).
    public func key(for axis: GestureAxis) -> ParamKey? {
        guard case let .grouped(x, y, z) = self else { return nil }
        switch axis {
        case .x: return x
        case .y: return y
        case .z: return z
        }
    }

    /// A grouped target with one axis reassigned (no-op on `.native`).
    public func settingKey(_ key: ParamKey?, for axis: GestureAxis) -> Vec3Target {
        guard case let .grouped(x, y, z) = self else { return self }
        switch axis {
        case .x: return .grouped(x: key, y: y, z: z)
        case .y: return .grouped(x: x, y: key, z: z)
        case .z: return .grouped(x: x, y: y, z: key)
        }
    }
}

// MARK: - CoreGestureAction

/// A built-in behavior a gesture can drive that is NOT a plain parameter write
/// (legacy `FingerGestureAction`'s non-parameter members). Ordinary camera
/// controls (orbit/dolly) are reached as regular param targets; only genuinely
/// special behaviors live here.
public enum CoreGestureAction: String, Sendable, Hashable, Codable, CaseIterable {
    /// Two-hand grab-zoom: hand separation maps to fractal scale about the
    /// pinned midpoint (legacy `.grab`).
    case grabZoom
    /// Reset the camera rig to the scene pose.
    case resetView
}

// MARK: - GestureBinding

/// What a `GestureSource` is bound to. Absence of an entry in a
/// `GestureBindingTable` means "unbound"; there is no `.none` case.
public enum GestureBinding: Sendable, Hashable, Codable {
    /// A 3D target — valid only for `.vector` sources.
    case vector(Vec3Target)
    /// A single scalar parameter. Valid for `.scalar` sources, and for
    /// `.vector` sources that drive one param from their delta magnitude.
    case scalar(ParamKey)
    /// A built-in behavior (grab-zoom, reset).
    case core(CoreGestureAction)

    /// Whether this binding is legal for a source of the given arity.
    public func isValid(for arity: GestureArity) -> Bool {
        switch self {
        case .vector: return arity == .vector
        case .scalar, .core: return true
        }
    }

    /// Every parameter key this binding references (0…3), for reverse lookup
    /// ("which gestures drive this param?") and orphan pruning on DE switch.
    public var referencedKeys: [ParamKey] {
        switch self {
        case let .vector(.native(key)): return [key]
        case let .vector(.grouped(x, y, z)): return [x, y, z].compactMap { $0 }
        case let .scalar(key): return [key]
        case .core: return []
        }
    }
}

// MARK: - GestureBindingTable

/// The per-fractal set of bindings. Stored as `[persistenceKey: GestureBinding]`
/// so JSON is legible and any source key a FUTURE build minted survives a
/// decode→encode cycle untouched (`unknownBindings`), matching SceneEnvelope's
/// forward-compatibility contract.
public struct GestureBindingTable: Sendable, Hashable, Codable {
    /// Bindings this build understands, keyed by source.
    public private(set) var bindings: [GestureSource: GestureBinding]
    /// Raw keys this build did not recognize, preserved verbatim on re-encode.
    public private(set) var unknownBindings: [String: GestureBinding]

    public init(
        bindings: [GestureSource: GestureBinding] = [:],
        unknownBindings: [String: GestureBinding] = [:]
    ) {
        self.bindings = bindings
        self.unknownBindings = unknownBindings
    }

    public var isEmpty: Bool { bindings.isEmpty && unknownBindings.isEmpty }

    public func binding(for source: GestureSource) -> GestureBinding? {
        bindings[source]
    }

    /// Assign (or with nil, clear) the binding for a source. A binding whose
    /// arity does not match the source is REJECTED (no-op) — the model never
    /// stores an illegal pairing.
    public mutating func setBinding(_ binding: GestureBinding?, for source: GestureSource) {
        guard let binding else {
            bindings[source] = nil
            return
        }
        guard binding.isValid(for: source.arity) else { return }
        bindings[source] = binding
    }

    /// Drop every binding that references a param key no longer present (e.g.
    /// after a DE switch changes the available params). `.core` bindings and
    /// unknown-key bindings are left untouched.
    public mutating func pruning(toKeys valid: Set<ParamKey>) {
        for (source, binding) in bindings {
            let refs = binding.referencedKeys
            guard !refs.isEmpty else { continue }        // .core — keep
            if !refs.allSatisfy(valid.contains) {
                bindings[source] = nil
            }
        }
    }

    /// All sources currently bound to a given param key.
    public func sources(referencing key: ParamKey) -> [GestureSource] {
        bindings.compactMap { source, binding in
            binding.referencedKeys.contains(key) ? source : nil
        }
    }

    // MARK: Codable (string-keyed, forward-compatible)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer()
            .decode([String: GestureBinding].self)
        var known: [GestureSource: GestureBinding] = [:]
        var unknown: [String: GestureBinding] = [:]
        for (key, binding) in raw {
            if let source = GestureSource(persistenceKey: key) {
                known[source] = binding
            } else {
                unknown[key] = binding
            }
        }
        self.bindings = known
        self.unknownBindings = unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var raw = unknownBindings
        for (source, binding) in bindings {
            raw[source.persistenceKey] = binding
        }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// MARK: - Vec3Group (auto-detect)

/// An x/y/z triple discovered among flat scalar params (external scenes name
/// their components `"Translate.x"`, `"Translate.y"`, `"Translate.z"` rather
/// than declaring a `.float3`). Seeds a `.grouped` `Vec3Target` in the editor;
/// the user may regroup or ungroup afterward (the "auto-detect + manual
/// override" decision).
public struct Vec3Group: Sendable, Hashable, Codable {
    /// The shared stem, for display (`"Translate"`).
    public let name: String
    public let x: ParamKey?
    public let y: ParamKey?
    public let z: ParamKey?
    /// Union of the component ranges — the drag's usable span.
    public let range: ClosedRange<Float>

    public init(name: String, x: ParamKey?, y: ParamKey?, z: ParamKey?, range: ClosedRange<Float>) {
        self.name = name
        self.x = x
        self.y = y
        self.z = z
        self.range = range
    }

    /// The `.grouped` target this triple seeds.
    public var target: Vec3Target { .grouped(x: x, y: y, z: z) }

    /// How many of the three axes are present.
    public var axisCount: Int { [x, y, z].compactMap { $0 }.count }

    // MARK: Detection

    /// Discover x/y/z triples among scalar (`.float`) catalog entries by their
    /// label's trailing axis token. Entries sharing a stem with at least two
    /// distinct axes form a group; native `.float3` params are ignored here (a
    /// float3 needs no grouping — it binds via `.native`).
    ///
    /// Detection is case-insensitive and tolerant of common separators
    /// (`Translate.x`, `translate_y`, `Offset Z`).
    public static func autoDetect(from entries: [CatalogEntry]) -> [Vec3Group] {
        // Preserve first-seen stem order for stable UI.
        var order: [String] = []
        var byStem: [String: [(axis: GestureAxis, entry: CatalogEntry)]] = [:]
        for entry in entries where entry.spec.kind == .float {
            guard let (stem, axis) = splitAxis(entry.spec.label) else { continue }
            let lower = stem.lowercased()
            if byStem[lower] == nil { byStem[lower] = []; order.append(lower) }
            // First component to claim an axis wins; ignore duplicates.
            if !byStem[lower]!.contains(where: { $0.axis == axis }) {
                byStem[lower]!.append((axis, entry))
            }
        }

        var groups: [Vec3Group] = []
        for stemLower in order {
            let members = byStem[stemLower]!
            guard members.count >= 2 else { continue }   // a lone ".x" is not a group
            let byAxis = Dictionary(uniqueKeysWithValues: members.map { ($0.axis, $0.entry) })
            let x = byAxis[.x], y = byAxis[.y], z = byAxis[.z]
            let present = [x, y, z].compactMap { $0 }
            let lo = present.map { $0.spec.range.lowerBound }.min() ?? 0
            let hi = present.map { $0.spec.range.upperBound }.max() ?? 1
            // Display name from the first member's original-case stem.
            let displayStem = members.first.flatMap { splitAxis($0.entry.spec.label)?.stem } ?? stemLower
            groups.append(Vec3Group(
                name: displayStem,
                x: x?.key, y: y?.key, z: z?.key,
                range: lo...max(lo, hi)))
        }
        return groups
    }

    /// Split a label into `(stem, axis)` if it ends in an axis token, else nil.
    /// Recognizes `.x` / `_x` / ` x` (and X/Y/Z), for x, y, z.
    static func splitAxis(_ label: String) -> (stem: String, axis: GestureAxis)? {
        guard let last = label.unicodeScalars.last else { return nil }
        let axisChar = Character(last)
        let axis: GestureAxis
        switch axisChar {
        case "x", "X": axis = .x
        case "y", "Y": axis = .y
        case "z", "Z": axis = .z
        default: return nil
        }
        // Must be preceded by a separator so we don't split "Max" → "Ma"+x.
        let body = label.dropLast()
        guard let sep = body.last, sep == "." || sep == "_" || sep == " " else { return nil }
        let stem = body.dropLast()
        guard !stem.isEmpty else { return nil }
        return (String(stem), axis)
    }
}
