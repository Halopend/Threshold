// TestSupport.swift — shared helpers for ThresholdCore tests.
//
// SplitMix64: tiny deterministic PRNG for property-style tests. We never use
// SystemRandomNumberGenerator — every "random" test is reproducible from its
// seed.

@testable import ThresholdCore

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

    mutating func bool(probability: Double = 0.5) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }
}

// MARK: - Catalog/engine builders

/// A scalar spec with test-friendly defaults (instant smoothing everywhere
/// unless overridden — smoothing behavior has its own dedicated tests).
func spec(
    _ key: String,
    range: ClosedRange<Float> = -100...100,
    default def: Float = 0,
    composition: Composition = .additive,
    smoothing: Smoothing = .instant,
    kind: ParamKind = .float,
    integratorRateKey: ParamKey? = nil
) -> ParamSpec {
    if kind.slotWidth == 1 {
        return ParamSpec(
            key: ParamKey(key), label: key, kind: kind, range: range, default: def,
            composition: composition, smoothing: smoothing,
            integratorRateKey: integratorRateKey)
    }
    return ParamSpec(
        key: ParamKey(key), label: key, kind: kind, range: range,
        defaultValue: [Float](repeating: def, count: kind.slotWidth),
        composition: composition, smoothing: smoothing,
        integratorRateKey: integratorRateKey)
}

/// Build an engine over the given specs (registered densely from slot 16).
func makeEngine(
    _ specs: [ParamSpec],
    clock: FixedStepClock,
    arenaSlots: Int = 0
) throws -> ModulationEngine {
    let catalog = Catalog()
    for s in specs { try catalog.register(s) }
    return ModulationEngine(layout: catalog.freeze(dynamicArenaSlots: arenaSlots), clock: clock)
}
