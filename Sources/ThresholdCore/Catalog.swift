// Catalog.swift — the ParameterCatalog builder and its frozen layout
// (plan §2, ARCHITECTURE.md §3).
//
// `Catalog` is a startup-time BUILDER: mutable, NOT Sendable, used on one
// thread during app launch. `freeze()` produces the immutable, Sendable
// `CatalogLayout` that everything else (resolver, GPU encoder, UI derivation,
// persistence) consumes. Slot order IS the GPU layout (plan §5.4): the
// resolver's output array is uploaded verbatim.

// MARK: - EngineSlot

/// Engine-reserved slots in the resolved param table.
///
/// Raw values MUST match the `THRESH_SLOT_*` constants in
/// `Sources/ThresholdShaderABI/include/ThresholdShaderABI.h` (the CPU↔GPU
/// contract). `ThresholdCore` deliberately cannot import the ABI header
/// (Foundation + simd only — ARCHITECTURE.md §1), so a cross-target test in a
/// target that links `ThresholdShaderABI` asserts `EngineSlot` raw values and
/// `reservedCount` against the header constants. Do not renumber.
public enum EngineSlot: Int, CaseIterable, Sendable, Codable, Hashable {
    case maxSteps = 0    // THRESH_SLOT_MAX_STEPS
    case maxDist = 1     // THRESH_SLOT_MAX_DIST
    case stepSafety = 2  // THRESH_SLOT_STEP_SAFETY
    case iterations = 3  // THRESH_SLOT_ITERATIONS
    case aoStrength = 4  // THRESH_SLOT_AO_STRENGTH
    case shadowSoft = 5  // THRESH_SLOT_SHADOW_SOFT
    // Color pipeline (plan §5.5) — must match THRESH_SLOT_* in the ABI header.
    case gradRepeat = 6      // THRESH_SLOT_GRAD_REPEAT
    case gradOffset = 7      // THRESH_SLOT_GRAD_OFFSET
    case gradSmoothing = 8   // THRESH_SLOT_GRAD_SMOOTH
    case colorMapMode = 9    // THRESH_SLOT_MAP_MODE
    case saturation = 10     // THRESH_SLOT_SATURATION
    case contrast = 11       // THRESH_SLOT_CONTRAST
    case vibrance = 12       // THRESH_SLOT_VIBRANCE
    case brightness = 13     // THRESH_SLOT_BRIGHTNESS
    case gamma = 14          // THRESH_SLOT_GAMMA
    case tonemap = 15        // THRESH_SLOT_TONEMAP

    /// Slots `0..<reservedCount` are engine-reserved; normal registration
    /// starts at `reservedCount`. Mirrors `THRESH_SLOT_ENGINE_COUNT`.
    public static let reservedCount = 16
}

// MARK: - Engine param keys

// Invariant 14: declared constants, one namespace per file section.
extension ParamKey {
    public static let engineMaxSteps = ParamKey("engine.maxSteps")
    public static let engineMaxDist = ParamKey("engine.maxDist")
    public static let engineStepSafety = ParamKey("engine.stepSafety")
    public static let engineIterations = ParamKey("engine.iterations")
    public static let engineAOStrength = ParamKey("engine.aoStrength")
    public static let engineShadowSoft = ParamKey("engine.shadowSoft")
    // Color pipeline scalars (plan §5.5).
    public static let colorGradientRepeat = ParamKey("color.gradient.repeat")
    public static let colorGradientOffset = ParamKey("color.gradient.offset")
    public static let colorGradientSmoothing = ParamKey("color.gradient.smoothing")
    public static let colorMapMode = ParamKey("color.mapMode")
    public static let colorSaturation = ParamKey("color.saturation")
    public static let colorContrast = ParamKey("color.contrast")
    public static let colorVibrance = ParamKey("color.vibrance")
    public static let colorBrightness = ParamKey("color.brightness")
    public static let colorGamma = ParamKey("color.gamma")
    public static let colorTonemap = ParamKey("color.tonemap")
}

// MARK: - Errors

public enum CatalogError: Error, Equatable, Sendable {
    /// A spec with this key is already registered. Duplicate registration
    /// THROWS (chosen over trapping so callers registering dynamic/external
    /// content can recover).
    case duplicateKey(ParamKey)
    /// The fixed engine slot is already occupied by another engine param.
    case engineSlotOccupied(Int)
}

// MARK: - CatalogEntry

/// One registered parameter with its assigned base slot. Vector params span
/// `slot ..< slot + kind.slotWidth` consecutive slots.
public struct CatalogEntry: Sendable, Hashable {
    public let slot: Int
    public let spec: ParamSpec

    /// Public so dynamic-arena registrars (SessionCore's external-DE path)
    /// can publish catalog-shaped entries in snapshots.
    public init(slot: Int, spec: ParamSpec) {
        self.slot = slot
        self.spec = spec
    }

    public var key: ParamKey { spec.key }
    public var kind: ParamKind { spec.kind }
    public var slotRange: Range<Int> { slot..<(slot + spec.kind.slotWidth) }
}

// MARK: - Catalog (builder)

/// Startup-time catalog builder. NOT Sendable — build on one thread, then
/// `freeze()` and share only the `CatalogLayout`.
public final class Catalog {
    private var entries: [CatalogEntry] = []
    private var indexByKey: [ParamKey: Int] = [:]
    private var occupiedEngineSlots: Set<Int> = []
    /// Dense slot cursor for normal registration. Slots `0..<16` are
    /// engine-reserved, so content registration starts at 16 even when no
    /// engine params are registered.
    private var nextSlot: Int = EngineSlot.reservedCount

    public init() {}

    /// Register a content param. Slots are assigned densely in registration
    /// order, append-only; vector params occupy consecutive slots.
    /// - Returns: the assigned base slot.
    /// - Throws: `CatalogError.duplicateKey`.
    @discardableResult
    public func register(_ spec: ParamSpec) throws -> Int {
        guard indexByKey[spec.key] == nil else { throw CatalogError.duplicateKey(spec.key) }
        let slot = nextSlot
        nextSlot += spec.kind.slotWidth
        indexByKey[spec.key] = entries.count
        entries.append(CatalogEntry(slot: slot, spec: spec))
        return slot
    }

    /// Place a SCALAR engine param at a fixed reserved slot (< 16) so the GPU
    /// kernel can read it without knowing catalog registration order.
    /// - Throws: `CatalogError.duplicateKey`, `CatalogError.engineSlotOccupied`.
    public func registerEngine(_ spec: ParamSpec, atSlot slot: Int) throws {
        precondition(
            slot >= 0 && slot < EngineSlot.reservedCount,
            "engine slots are 0..<\(EngineSlot.reservedCount), got \(slot)"
        )
        precondition(spec.kind.slotWidth == 1, "engine params must be scalar: \(spec.key)")
        guard indexByKey[spec.key] == nil else { throw CatalogError.duplicateKey(spec.key) }
        guard !occupiedEngineSlots.contains(slot) else { throw CatalogError.engineSlotOccupied(slot) }
        occupiedEngineSlots.insert(slot)
        indexByKey[spec.key] = entries.count
        entries.append(CatalogEntry(slot: slot, spec: spec))
    }

    /// A catalog pre-loaded with the six engine params at their fixed slots,
    /// defaults from docs/op-semantics.md "March defaults".
    ///
    /// Composition per ADR-003: quality-class params (`maxSteps`,
    /// `iterations`) declare `.multiplicative` so the governor's system-lane
    /// write is a 0…1 factor; the rest are `.replace` settings. Ranges are
    /// provisional engineering bounds.
    public static func withEngineDefaults() -> Catalog {
        let catalog = Catalog()
        // Safe by construction: fresh catalog, six distinct keys/slots.
        // swiftlint:disable force_try
        try! catalog.registerEngine(
            ParamSpec(key: .engineMaxSteps, label: "Max March Steps",
                      range: 1...4096, default: 256,
                      composition: .multiplicative, persistence: .deviceLocal,
                      group: .performance),
            atSlot: EngineSlot.maxSteps.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .engineMaxDist, label: "Max March Distance",
                      range: 0.1...4096, default: 64.0,
                      composition: .replace, persistence: .scene,
                      group: .performance),
            atSlot: EngineSlot.maxDist.rawValue)
        // Doubles as the over-relaxation factor ω (enhanced sphere tracing):
        // < 1 conservative, 1 = plain sphere trace, > 1 over-relaxes (fewer
        // march steps across empty space, with an overstep-retreat guard so
        // surfaces are never tunneled). Default 0.9 keeps prior behavior.
        try! catalog.registerEngine(
            ParamSpec(key: .engineStepSafety, label: "Step Multiplier (ω)",
                      range: 0.5...2.0, default: 0.9,
                      composition: .replace, persistence: .deviceLocal,
                      group: .performance),
            atSlot: EngineSlot.stepSafety.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .engineIterations, label: "DE Iterations",
                      range: 1...256, default: 12,
                      composition: .multiplicative, persistence: .scene,
                      group: .performance),
            atSlot: EngineSlot.iterations.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .engineAOStrength, label: "AO Strength",
                      range: 0...2, default: 0.5,
                      composition: .replace, persistence: .scene,
                      group: .performance),
            atSlot: EngineSlot.aoStrength.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .engineShadowSoft, label: "Shadow Softness",
                      range: 1...64, default: 8.0,
                      composition: .replace, persistence: .scene,
                      group: .performance),
            atSlot: EngineSlot.shadowSoft.rawValue)

        // Color pipeline (plan §5.5). Grading + palette-sampling controls;
        // the palette STOPS are scene content in the envelope, not here.
        // All `.replace` settings so scene authors them and the music/animation
        // lanes add offsets on top (e.g. Color Offset pulsing to the beat).
        try! catalog.registerEngine(
            ParamSpec(key: .colorGradientRepeat, label: "Gradient Repeat",
                      range: 1...16, default: 1,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.gradRepeat.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .colorGradientOffset, label: "Color Offset",
                      range: 0...1, default: 0,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.gradOffset.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .colorGradientSmoothing, label: "Gradient Smoothing",
                      range: 0...1, default: 0,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.gradSmoothing.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .colorMapMode, label: "Color Mapping",
                      kind: .enumeration(caseCount: 4), range: 0...3, default: 0,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.colorMapMode.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .colorSaturation, label: "Saturation",
                      range: 0...2, default: 1,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.saturation.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .colorContrast, label: "Contrast",
                      range: 0...2, default: 1,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.contrast.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .colorVibrance, label: "Vibrance",
                      range: 0...1, default: 0,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.vibrance.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .colorBrightness, label: "Brightness",
                      range: 0...2, default: 1,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.brightness.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .colorGamma, label: "Gamma",
                      range: 0.1...4, default: 1,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.gamma.rawValue)
        try! catalog.registerEngine(
            ParamSpec(key: .colorTonemap, label: "Filmic Tonemap",
                      range: 0...1, default: 0,
                      composition: .replace, persistence: .scene, group: .color),
            atSlot: EngineSlot.tonemap.rawValue)
        // Zoom (plan §6.3): rate + integrator phase feeding ScaleContext.
        try! catalog.registerScaleParams()
        // Camera rig (plan §8.3): orbit/dolly offsets over the scene pose.
        try! catalog.registerCameraParams()
        // swiftlint:enable force_try
        return catalog
    }

    /// Snapshot the catalog into an immutable, Sendable layout, appending a
    /// dynamic arena of `dynamicArenaSlots` unassigned slots after the static
    /// ones. Dynamic registration into the arena (warp-slot fields, external
    /// DE params — recycled via the command mailbox on stack/DE change) is a
    /// later phase; the arena exists in the layout NOW so the GPU-facing slot
    /// count never reshuffles mid-session (ARCHITECTURE.md §3).
    public func freeze(dynamicArenaSlots: Int = 256) -> CatalogLayout {
        precondition(dynamicArenaSlots >= 0)
        let staticCount = nextSlot
        return CatalogLayout(
            entries: entries,
            slotCount: staticCount + dynamicArenaSlots,
            arenaRange: staticCount..<(staticCount + dynamicArenaSlots)
        )
    }
}

// MARK: - CatalogLayout (frozen)

/// Immutable, Sendable snapshot of the catalog. Slot order is the GPU layout.
public struct CatalogLayout: Sendable {
    /// All registered entries, in registration order.
    public let entries: [CatalogEntry]
    /// Total slot count including the dynamic arena.
    public let slotCount: Int
    /// Unassigned slots reserved for dynamic registration.
    public let arenaRange: Range<Int>

    private let indexByKey: [ParamKey: Int]

    init(entries: [CatalogEntry], slotCount: Int, arenaRange: Range<Int>) {
        self.entries = entries
        self.slotCount = slotCount
        self.arenaRange = arenaRange
        var index: [ParamKey: Int] = [:]
        index.reserveCapacity(entries.count)
        for (i, entry) in entries.enumerated() { index[entry.key] = i }
        self.indexByKey = index
    }

    public func entry(for key: ParamKey) -> CatalogEntry? {
        indexByKey[key].map { entries[$0] }
    }

    /// Base slot for a key (vector params start here).
    public func slot(for key: ParamKey) -> Int? {
        entry(for: key)?.slot
    }
}

// MARK: - ArenaAllocator

/// Bump allocator over a layout's dynamic arena. Owned by whoever owns the
/// engine (render-thread confined alongside it); allocation NEVER moves
/// existing slots — the arena is recycled wholesale via `reset()` when its
/// occupant (external DE, warp-stack fields) is replaced. Pair every
/// allocation with `ModulationEngine.registerDynamic`, and every `reset` with
/// `unregisterDynamic`, so spec tables and lane state stay in sync.
public struct ArenaAllocator: Sendable {
    public let range: Range<Int>
    private var cursor: Int

    public init(range: Range<Int>) {
        self.range = range
        self.cursor = range.lowerBound
    }

    /// Slots handed out since init/reset (ascending, contiguous).
    public var allocated: Range<Int> { range.lowerBound..<cursor }

    /// Allocate `count` consecutive slots; nil when the arena is exhausted
    /// (callers degrade — e.g. an external DE renders at declared defaults).
    public mutating func allocate(_ count: Int) -> Range<Int>? {
        guard count >= 0, cursor + count <= range.upperBound else { return nil }
        defer { cursor += count }
        return cursor..<(cursor + count)
    }

    /// Recycle everything allocated since init/reset.
    public mutating func reset() {
        cursor = range.lowerBound
    }
}
