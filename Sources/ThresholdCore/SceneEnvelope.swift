// SceneEnvelope.swift — the .threshscene document model (plan §7.1,
// ARCHITECTURE.md §7). Decoding preserves unknown content: foreign top-level
// keys land in `unknown`, foreign or non-numeric param entries land in
// `foreignParams`, and both are merged back verbatim on encode — this is what
// makes forward compatibility real rather than aspirational.

import Foundation

// MARK: - Sub-envelopes

/// One declared parameter of an embedded DE: enough metadata to build a
/// DEDescriptor param entry (and, later, catalog registration) for an
/// externally-authored formula.
public struct EmbeddedDEParam: Sendable, Equatable, Codable {
    public var name: String
    public var defaultValue: Float
    public var min: Float
    public var max: Float

    public init(name: String, defaultValue: Float, min: Float, max: Float) {
        self.name = name
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
    }
}

/// Externally-authored distance estimator embedded in a scene (plan §7.2).
/// Compilation/validation is the render layer's job; persistence just carries
/// the source and its provenance.
public struct EmbeddedDE: Sendable, Equatable, Codable {
    /// The DE ABI version this build targets. MUST mirror
    /// THRESHOLD_ABI_VERSION in ThresholdShaderABI.h — ThresholdCore cannot
    /// import the header (Foundation-only rule), so a cross-target test in
    /// ThresholdRenderTests asserts the two are equal. Writers (snapshots,
    /// migrations) stamp this into embedded DEs.
    public static let currentABIVersion = 3

    /// MSL source defining `[[visible]] float2 de_main(float3, thread const
    /// ThreshDEContext&)` — compiled at load against the published ABI header.
    public var source: String
    public var abiVersion: Int
    /// Content hash of `source` (hex); cache key and tamper check. Empty
    /// means the author declared none (e.g. migrated legacy formulas) — the
    /// loader then computes it for cache identity only.
    public var hash: String
    /// Declared params, in GPU slice order (same convention as built-in
    /// descriptors: the iteration count is appended after these).
    public var params: [EmbeddedDEParam]

    public init(source: String, abiVersion: Int, hash: String,
                params: [EmbeddedDEParam] = []) {
        self.source = source
        self.abiVersion = abiVersion
        self.hash = hash
        self.params = params
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        abiVersion = try c.decode(Int.self, forKey: .abiVersion)
        hash = try c.decode(String.self, forKey: .hash)
        params = try c.decodeIfPresent([EmbeddedDEParam].self, forKey: .params) ?? []
    }
}

/// One warp-stack slot, as pure data. Deliberately NOT the ABI struct —
/// ThresholdCore has no ABI dependency; ThresholdShaderIR provides the
/// conversion to `ThreshWarpOp`. `a`/`b` are always 4 components.
public struct WarpOpDTO: Sendable, Equatable, Codable {
    public var kind: UInt32
    public var flags: UInt32
    public var strength: Float
    public var a: [Float]
    public var b: [Float]

    public init(kind: UInt32, flags: UInt32 = 0, strength: Float, a: [Float], b: [Float]) {
        precondition(a.count == 4 && b.count == 4, "WarpOpDTO payloads are exactly 4 components")
        self.kind = kind
        self.flags = flags
        self.strength = strength
        self.a = a
        self.b = b
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(UInt32.self, forKey: .kind)
        flags = try c.decodeIfPresent(UInt32.self, forKey: .flags) ?? 0
        strength = try c.decode(Float.self, forKey: .strength)
        a = try c.decode([Float].self, forKey: .a)
        b = try c.decode([Float].self, forKey: .b)
        guard a.count == 4, b.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .a, in: c,
                debugDescription: "warp op payloads must have exactly 4 components")
        }
    }
}

public struct CameraDTO: Sendable, Equatable, Codable {
    /// World position, 3 components.
    public var position: [Float]
    /// Orientation quaternion (x, y, z, w); rotates -Z forward.
    public var orientation: [Float]
    public var fovYRadians: Float

    /// Off-axis 3/4 view looking at the origin from slightly below (distance
    /// ≈ 3, ~31° upward pitch about X — a pure vertical tilt, so left/right
    /// symmetry is preserved). A dead-on `[0,0,3]` view sits on the symmetry
    /// axis of the space-filling folds (pseudo-Kleinian), where the DE stays
    /// sub-threshold and every ray creeps → the fractal renders BLACK; nudging
    /// the camera off that axis breaks the degeneracy so a fresh pick / reset
    /// always shows a surface. It also frames the compact bulbs/box more
    /// flatteringly than face-on. Orientation is a verified look-at-origin
    /// quaternion (x,y,z,w) for position (0,-1.6,2.6).
    public static let `default` = CameraDTO(
        position: [0, -1.6, 2.6], orientation: [0.27234, 0, 0, 0.9622],
        fovYRadians: Float.pi / 3)

    public init(position: [Float], orientation: [Float], fovYRadians: Float) {
        precondition(position.count == 3 && orientation.count == 4)
        self.position = position
        self.orientation = orientation
        self.fovYRadians = fovYRadians
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode([Float].self, forKey: .position)
        orientation = try c.decode([Float].self, forKey: .orientation)
        fovYRadians = try c.decode(Float.self, forKey: .fovYRadians)
        guard position.count == 3, orientation.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .position, in: c,
                debugDescription: "camera: position is 3 components, orientation is 4")
        }
    }
}

// MARK: - SceneEnvelope

public struct SceneEnvelope: Sendable, Equatable {
    /// Format version (`SceneCodec.currentVersion` when saved by this build).
    public var version: Int
    /// DE ABI version in effect at save (relevant when `embeddedDE` is set).
    public var abiVersion: Int
    public var name: String?
    public var tags: [String]
    /// Built-in DE key (e.g. "mandelbulb"). Ignored when `embeddedDE` is set.
    public var fractalTypeKey: String
    public var embeddedDE: EmbeddedDE?
    /// `.scene`-persisted param values by ParamKey rawValue — the catalog
    /// walk's output. Unknown-but-numeric keys survive here untouched.
    public var params: [String: [Float]]
    /// Param entries whose JSON shape is not a numeric array/number. Never
    /// interpreted; merged back into "params" verbatim on encode.
    public var foreignParams: [String: JSONValue]
    /// Integrator phase snapshots by ParamKey rawValue.
    public var integratorPhases: [String: Float]
    /// Zoom-rebase counter at save (plan §6.3): integer octaves folded out of
    /// the `scale.zoom` phase, with `camera` saved in the REBASED world.
    /// Pure zoom-depth bookkeeping — phase + camera alone reproduce the
    /// image; 0 (the default, omitted on encode) for never-rebased scenes.
    public var scaleOctave: Int32
    public var warpStack: [WarpOpDTO]
    public var camera: CameraDTO
    /// Scene palette (gradient stops). `nil` means "no authored palette" — the
    /// renderer falls back to its default palette (plan §5.5).
    public var palette: Palette?
    /// Signal→param bindings this scene carries (music reactivity + LFO
    /// routing). Scene-embedded so a scene is a self-contained audio-visual
    /// preset; `apply` installs them into the BindingEngine. Empty for scenes
    /// that predate the feature or carry no reactive behavior.
    public var bindings: [Binding]
    /// Procedural LFO bank this scene carries. Bindings reference an LFO by its
    /// `lfo.*` slot; `apply` installs these into the LFOEngine.
    public var lfos: [LFOSpec]
    /// The tunable Focus Band this scene carries (music's "LFO equivalent").
    /// `nil` = the scene predates the feature / carries none; the app shell
    /// pushes it to the mic DSP on load (it is not render-session state).
    public var focusBand: AudioFocusBand?
    /// Foreign top-level keys, preserved verbatim.
    public var unknown: [String: JSONValue]

    public init(
        version: Int,
        abiVersion: Int = 1,
        name: String? = nil,
        tags: [String] = [],
        fractalTypeKey: String,
        embeddedDE: EmbeddedDE? = nil,
        params: [String: [Float]] = [:],
        foreignParams: [String: JSONValue] = [:],
        integratorPhases: [String: Float] = [:],
        scaleOctave: Int32 = 0,
        warpStack: [WarpOpDTO] = [],
        camera: CameraDTO = .default,
        palette: Palette? = nil,
        bindings: [Binding] = [],
        lfos: [LFOSpec] = [],
        focusBand: AudioFocusBand? = nil,
        unknown: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.abiVersion = abiVersion
        self.name = name
        self.tags = tags
        self.fractalTypeKey = fractalTypeKey
        self.embeddedDE = embeddedDE
        self.params = params
        self.foreignParams = foreignParams
        self.integratorPhases = integratorPhases
        self.scaleOctave = scaleOctave
        self.warpStack = warpStack
        self.camera = camera
        self.palette = palette
        self.bindings = bindings
        self.lfos = lfos
        self.focusBand = focusBand
        self.unknown = unknown
    }
}

// MARK: - Codable with unknown-key preservation

/// String-keyed coding key for walking arbitrary JSON objects.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension SceneEnvelope: Codable {
    /// Known top-level keys. Anything else is preserved in `unknown`.
    private static let knownKeys: Set<String> = [
        "version", "abiVersion", "name", "tags", "fractalTypeKey",
        "embeddedDE", "params", "integratorPhases", "scaleOctave",
        "warpStack", "camera", "palette", "bindings", "lfos", "focusBand",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)

        func key(_ s: String) -> DynamicCodingKey { DynamicCodingKey(s) }

        guard let version = try c.decodeIfPresent(Int.self, forKey: key("version")) else {
            throw DecodingError.keyNotFound(
                key("version"),
                .init(codingPath: c.codingPath, debugDescription: "scene envelope missing version"))
        }
        self.version = version
        abiVersion = try c.decodeIfPresent(Int.self, forKey: key("abiVersion")) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: key("name"))
        tags = try c.decodeIfPresent([String].self, forKey: key("tags")) ?? []
        fractalTypeKey = try c.decodeIfPresent(String.self, forKey: key("fractalTypeKey")) ?? ""
        embeddedDE = try c.decodeIfPresent(EmbeddedDE.self, forKey: key("embeddedDE"))
        integratorPhases =
            try c.decodeIfPresent([String: Float].self, forKey: key("integratorPhases")) ?? [:]
        scaleOctave = try c.decodeIfPresent(Int32.self, forKey: key("scaleOctave")) ?? 0
        warpStack = try c.decodeIfPresent([WarpOpDTO].self, forKey: key("warpStack")) ?? []
        camera = try c.decodeIfPresent(CameraDTO.self, forKey: key("camera")) ?? .default
        palette = try c.decodeIfPresent(Palette.self, forKey: key("palette"))
        bindings = try c.decodeIfPresent([Binding].self, forKey: key("bindings")) ?? []
        lfos = try c.decodeIfPresent([LFOSpec].self, forKey: key("lfos")) ?? []
        focusBand = try c.decodeIfPresent(AudioFocusBand.self, forKey: key("focusBand"))

        // Params: split numeric-shaped entries from foreign shapes, keeping
        // both (numeric values normalize to [Float]; bare numbers become
        // 1-element arrays — a documented, semantic-preserving normalization).
        var params: [String: [Float]] = [:]
        var foreign: [String: JSONValue] = [:]
        if let rawParams = try c.decodeIfPresent([String: JSONValue].self, forKey: key("params")) {
            for (k, v) in rawParams {
                if let components = v.asFloatComponents {
                    params[k] = components
                } else {
                    foreign[k] = v
                }
            }
        }
        self.params = params
        self.foreignParams = foreign

        // Preserve every foreign top-level key.
        var unknown: [String: JSONValue] = [:]
        for k in c.allKeys where !Self.knownKeys.contains(k.stringValue) {
            unknown[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        self.unknown = unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)

        func key(_ s: String) -> DynamicCodingKey { DynamicCodingKey(s) }

        try c.encode(version, forKey: key("version"))
        try c.encode(abiVersion, forKey: key("abiVersion"))
        try c.encodeIfPresent(name, forKey: key("name"))
        if !tags.isEmpty { try c.encode(tags, forKey: key("tags")) }
        try c.encode(fractalTypeKey, forKey: key("fractalTypeKey"))
        try c.encodeIfPresent(embeddedDE, forKey: key("embeddedDE"))

        // Merge typed + foreign params back into one object.
        var merged: [String: JSONValue] = foreignParams
        for (k, components) in params {
            merged[k] = .array(components.map { .number(Double($0)) })
        }
        try c.encode(merged, forKey: key("params"))

        if !integratorPhases.isEmpty {
            try c.encode(integratorPhases, forKey: key("integratorPhases"))
        }
        if scaleOctave != 0 { try c.encode(scaleOctave, forKey: key("scaleOctave")) }
        try c.encode(warpStack, forKey: key("warpStack"))
        try c.encode(camera, forKey: key("camera"))
        try c.encodeIfPresent(palette, forKey: key("palette"))
        if !bindings.isEmpty { try c.encode(bindings, forKey: key("bindings")) }
        if !lfos.isEmpty { try c.encode(lfos, forKey: key("lfos")) }
        try c.encodeIfPresent(focusBand, forKey: key("focusBand"))

        // Foreign top-level keys ride along; a collision with a known key
        // cannot arise from our own decode (they were filtered) — skip any
        // user-constructed collision rather than emitting duplicate keys.
        for (k, v) in unknown where !Self.knownKeys.contains(k) {
            try c.encode(v, forKey: key(k))
        }
    }
}
