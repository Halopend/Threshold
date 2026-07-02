// ParamSpec.swift — the type-erased storage form of a parameter declaration
// (ARCHITECTURE.md §3: the plan's generic `ParamSpec<Value>` is an authoring
// convenience; the catalog stores this erased, dense form).

// MARK: - ParamKind

/// The value shape of a parameter. Bools and enums live in the same float
/// table as everything else (0/1, index-as-float — the GPU wants floats
/// anyway); vectors span consecutive slots.
public enum ParamKind: Sendable, Codable, Hashable {
    case float
    case bool
    case enumeration(caseCount: Int)
    case float3
    case float4

    /// How many consecutive catalog slots this kind occupies.
    public var slotWidth: Int {
        switch self {
        case .float, .bool, .enumeration: return 1
        case .float3: return 3
        case .float4: return 4
        }
    }
}

// MARK: - ParamSpec

/// One parameter declaration. A parameter exists ONLY as a catalog entry
/// (Invariant 1); UI, persistence, bindings, and GPU layout all derive from
/// this record.
public struct ParamSpec: Sendable, Hashable {
    public let key: ParamKey
    public let label: String
    public let kind: ParamKind
    /// Clamp range, applied PER COMPONENT for vector kinds. Clamping happens
    /// in exactly one place: lane resolution (plan §2.2).
    public let range: ClosedRange<Float>
    /// One value per slot (`count == kind.slotWidth`).
    public let defaultValue: [Float]
    /// UI/binding mapping metadata only — never applied during resolution.
    public let curve: ResponseCurve
    public let composition: Composition
    public let smoothing: Smoothing
    public let persistence: Persistence
    public let capabilities: Capabilities
    public let group: GroupID
    /// Non-nil ONLY for time-integrated phase params (ARCHITECTURE.md §3
    /// "Stateful params", Invariant 17): the resolved value of this param is
    /// a phase owned by the resolver, advanced each frame by
    /// `resolvedValue(integratorRateKey) × dt × timeScale` and wrapped into
    /// `range`. The *rate* is an ordinary lane-resolved param; the *phase* is
    /// resolver state. Integrator phase params must be scalar (`.float`).
    public let integratorRateKey: ParamKey?

    public init(
        key: ParamKey,
        label: String,
        kind: ParamKind,
        range: ClosedRange<Float>,
        defaultValue: [Float],
        curve: ResponseCurve = .linear,
        composition: Composition = .additive,
        smoothing: Smoothing = .default,
        persistence: Persistence = .scene,
        capabilities: Capabilities = [],
        group: GroupID = .shape,
        integratorRateKey: ParamKey? = nil
    ) {
        precondition(
            defaultValue.count == kind.slotWidth,
            "defaultValue for \(key) must have exactly \(kind.slotWidth) component(s), got \(defaultValue.count)"
        )
        if integratorRateKey != nil {
            precondition(kind == .float, "integrator phase param \(key) must be scalar (.float)")
        }
        self.key = key
        self.label = label
        self.kind = kind
        self.range = range
        self.defaultValue = defaultValue
        self.curve = curve
        self.composition = composition
        self.smoothing = smoothing
        self.persistence = persistence
        self.capabilities = capabilities
        self.group = group
        self.integratorRateKey = integratorRateKey
    }

    /// Scalar convenience.
    public init(
        key: ParamKey,
        label: String,
        kind: ParamKind = .float,
        range: ClosedRange<Float>,
        default defaultScalar: Float,
        curve: ResponseCurve = .linear,
        composition: Composition = .additive,
        smoothing: Smoothing = .default,
        persistence: Persistence = .scene,
        capabilities: Capabilities = [],
        group: GroupID = .shape,
        integratorRateKey: ParamKey? = nil
    ) {
        precondition(kind.slotWidth == 1, "scalar convenience init used with vector kind for \(key)")
        self.init(
            key: key, label: label, kind: kind, range: range,
            defaultValue: [defaultScalar], curve: curve, composition: composition,
            smoothing: smoothing, persistence: persistence, capabilities: capabilities,
            group: group, integratorRateKey: integratorRateKey
        )
    }
}
