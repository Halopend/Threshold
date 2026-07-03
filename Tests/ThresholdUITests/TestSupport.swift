// TestSupport.swift — shared helpers for ThresholdUI tests.
//
// SplitMix64: tiny deterministic PRNG (copied per-target by convention —
// never SystemRandomNumberGenerator; every "random" test reproduces from its
// seed).

@testable import ThresholdCore
import ThresholdRender
@testable import ThresholdUI

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        Float.random(in: range, using: &self)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }
}

// MARK: - Layout / snapshot builders

/// A small catalog: two scalars, a bool, an enum, and a float3 across two
/// groups. Content slots start at 16 (engine-reserved gap below).
func makeTestLayout() -> CatalogLayout {
    let catalog = Catalog()
    // Safe by construction: fresh catalog, distinct keys.
    // swiftlint:disable force_try
    try! catalog.register(ParamSpec(
        key: ParamKey("test.alpha"), label: "Alpha", range: 0...1, default: 0.5,
        group: .shape))
    try! catalog.register(ParamSpec(
        key: ParamKey("test.beta"), label: "Beta", range: -2...4, default: 1,
        curve: .exp(k: 2), group: .shape))
    try! catalog.register(ParamSpec(
        key: ParamKey("test.flag"), label: "Flag", kind: .bool, range: 0...1,
        default: 0, composition: .replace, group: .color))
    try! catalog.register(ParamSpec(
        key: ParamKey("test.mode"), label: "Mode",
        kind: .enumeration(caseCount: 3), range: 0...2, default: 0,
        composition: .replace, group: .color))
    try! catalog.register(ParamSpec(
        key: ParamKey("test.tint"), label: "Tint", kind: .float3, range: 0...1,
        defaultValue: [0.1, 0.2, 0.3], group: .color))
    // swiftlint:enable force_try
    return catalog.freeze(dynamicArenaSlots: 0)
}

func makeSnapshot(
    values: [Float],
    generation: UInt64 = 1,
    frameIndex: UInt64 = 0,
    time: Double = 0,
    gpuMilliseconds: Double = 0,
    totalSteps: UInt64 = 0,
    deKey: String = "mandelbox",
    warpStack: [WarpOpDTO] = [],
    paused: Bool = false,
    palette: Palette = Palette(stops: [])
) -> RenderSnapshot {
    RenderSnapshot(
        resolved: ResolvedParams(values: values, generation: generation),
        frameIndex: frameIndex,
        time: time,
        gpuMilliseconds: gpuMilliseconds,
        totalSteps: totalSteps,
        deKey: deKey,
        warpStack: warpStack,
        paused: paused,
        palette: palette)
}

/// A warp DTO with recognizable payloads for list-edit assertions.
func dto(kind: UInt32, strength: Float) -> WarpOpDTO {
    WarpOpDTO(
        kind: kind, flags: 0, strength: strength,
        a: [Float(kind), 0, 0, 0], b: [0, Float(kind), 0, 0])
}

@MainActor
func makeMirror(
    layout: CatalogLayout = makeTestLayout()
) -> (mirror: ParameterMirror, snapshots: SnapshotSlot, commands: CommandMailbox<SessionCommand>) {
    let snapshots = SnapshotSlot()
    let commands = CommandMailbox<SessionCommand>()
    let mirror = ParameterMirror(layout: layout, snapshots: snapshots, commands: commands)
    return (mirror, snapshots, commands)
}
