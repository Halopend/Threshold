// LFO.swift — the low-frequency-oscillator data model + pure evaluation
// (music-independent procedural modulation). LFOs are DATA, like bindings and
// animation tracks: this file is the vocabulary and the math; LFOEngine.swift
// is the render-thread machine that evaluates specs and PUBLISHES them as
// `lfo.*` signals; scenes persist them.
//
// The core design idea (see docs/plan): an LFO is a SIGNAL SOURCE, not a new
// lane concept. An `LFOEngine` evaluates each spec from the session clock and
// publishes it into the `SignalTable` under an `lfo.*` `SignalID`; an ordinary
// `Binding` then routes it to any parameter through the existing
// `SignalMapping` (input range → curve → output range → deadzone) × scale, on
// the transient lanes. "Music reactivity" and "LFO animation" are literally the
// same mechanism with a different signal source (Binding.swift doc).
//
// Everything here is a Sendable value type and evaluation is a PURE function of
// (spec, time) — determinism for the harness (Invariant 9) comes for free: the
// engine evaluates off `AppClock.now`, never wall time.

import Foundation

// MARK: - LFOWave

/// A unit oscillator shape. Each waveform is defined over a normalized phase in
/// TURNS (one cycle = phase advancing by 1) and returns a value in roughly
/// −1…1. Range-fitting into parameter units is deliberately NOT done here — the
/// downstream `SignalMapping` owns that (`inputLo/inputHi → curve →
/// outputLo/outputHi`), exactly as it does for `audio.rms` and the other raw
/// signals. All shapes are phase-aligned with `sine` (they pass through 0 rising
/// at phase 0), so components of a combo reinforce rather than fight.
public enum LFOWave: String, Codable, Sendable, Hashable, CaseIterable {
    /// `sin(2π·phase)`.
    case sine
    /// Linear rise/fall, same zero-crossings as sine.
    case triangle
    /// Rising ramp −1→1 over each cycle (a falling reset at the cycle boundary;
    /// wraps seamlessly onto a mod-1 target like the palette phase offset).
    case saw
    /// Hard −1/1 gate, positive for the first half-cycle.
    case square
    /// Deterministic value-noise: smoothed random walk that changes at the
    /// component's rate. Reproducible across runs (seeded, no wall clock).
    case noise

    /// Sample the waveform at `phase` turns (any real; wrapped internally).
    /// `seed` decorrelates `noise` across components; ignored by the periodic
    /// shapes.
    public func sample(phase: Float, seed: UInt64) -> Float {
        switch self {
        case .sine:
            return sinf(2 * .pi * phase)
        case .triangle:
            // 0 → 1 → 0 → −1 → 0 over one cycle, in phase with sine.
            let f = LFOWave.frac(phase + 0.25)
            return 1 - 4 * abs(f - 0.5)
        case .saw:
            return 2 * LFOWave.frac(phase) - 1
        case .square:
            return LFOWave.frac(phase) < 0.5 ? 1 : -1
        case .noise:
            // Value noise: hash the integer lattice, smoothstep-interpolate the
            // fractional part. Continuous (no clicks), deterministic, period-free.
            let n = phase.rounded(.down)
            guard n.isFinite else { return 0 }
            let i = Int64(n)
            let f = phase - n
            let a = LFOWave.hashUnit(seed &+ UInt64(bitPattern: i))
            let b = LFOWave.hashUnit(seed &+ UInt64(bitPattern: i &+ 1))
            let s = f * f * (3 - 2 * f)  // smoothstep
            return a + (b - a) * s
        }
    }

    /// Fractional part in [0, 1), correct for negative inputs.
    private static func frac(_ x: Float) -> Float {
        guard x.isFinite else { return 0 }
        let r = x - x.rounded(.down)
        return r
    }

    /// A stable hash of `n` in −1…1 (integer → pseudo-random value). SplitMix64
    /// finalizer — no state, no allocation, identical on every platform.
    private static func hashUnit(_ n: UInt64) -> Float {
        var z = n &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        // Top 24 bits → [0,1) → −1…1 (24 bits is exact in Float).
        let unit = Float(z >> 40) / Float(1 << 24)
        return unit * 2 - 1
    }
}

// MARK: - LFOComponent

/// One oscillator in a combo. The published LFO value is the amplitude-weighted
/// sum of its components plus a DC `bias` (see `LFOSpec.value(at:seed:)`).
public struct LFOComponent: Codable, Sendable, Equatable, Hashable {
    public var wave: LFOWave
    /// Cycles per second. 0 = frozen (a constant equal to the shape's value at
    /// `phase`). Negative rates run the shape backwards.
    public var rateHz: Float
    /// Start offset in TURNS (0…1 = one cycle); shifts this component in time.
    public var phase: Float
    /// Contribution to the sum. A single `sine` component at amplitude 1 spans
    /// −1…1 before the binding's input range fits it.
    public var amplitude: Float

    public init(wave: LFOWave = .sine, rateHz: Float = 0.5, phase: Float = 0, amplitude: Float = 1) {
        self.wave = wave
        self.rateHz = rateHz
        self.phase = phase
        self.amplitude = amplitude
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown waveform names from a newer writer degrade to sine rather
        // than failing the whole scene (forward compatibility, like the
        // animation/track codecs).
        wave = (try? c.decodeIfPresent(LFOWave.self, forKey: .wave)) ?? .sine
        rateHz = try c.decodeIfPresent(Float.self, forKey: .rateHz) ?? 0.5
        phase = try c.decodeIfPresent(Float.self, forKey: .phase) ?? 0
        amplitude = try c.decodeIfPresent(Float.self, forKey: .amplitude) ?? 1
    }
}

// MARK: - LFOSpec

/// One named oscillator that publishes into a fixed `lfo.*` signal slot. A spec
/// is a COMBO: multiple `LFOComponent`s summed ("run various waveforms through
/// them and add them together"), plus a DC `bias`. Bindings reference the
/// spec's `slot` — that indirection is why the LFO bank names its slots.
public struct LFOSpec: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    /// Which `lfo.*` `SignalID` this spec publishes into (e.g. `.lfoA`). Must be
    /// a registered LFO slot or the published value is dropped (SignalTable
    /// fixed-capacity contract).
    public var slot: SignalID
    /// Human label for the bank UI; not load-bearing.
    public var name: String
    /// Oscillators summed to form the output.
    public var components: [LFOComponent]
    /// DC offset added after the component sum (shifts the whole waveform).
    public var bias: Float
    /// When false the engine skips this spec (and its slot reads stale — bound
    /// params fall back to their non-LFO value via the binding's staleness path).
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        slot: SignalID,
        name: String = "",
        components: [LFOComponent] = [LFOComponent()],
        bias: Float = 0,
        enabled: Bool = true
    ) {
        self.id = id
        self.slot = slot
        self.name = name
        self.components = components
        self.bias = bias
        self.enabled = enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        slot = try c.decode(SignalID.self, forKey: .slot)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        components = try c.decodeIfPresent([LFOComponent].self, forKey: .components) ?? []
        bias = try c.decodeIfPresent(Float.self, forKey: .bias) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Evaluate the combo at absolute session time `t` (seconds). Pure. `seed`
    /// (derive from the slot) decorrelates any `noise` components across specs;
    /// each component additionally offsets the seed by its index so two noise
    /// components in one spec don't move in lockstep. A non-finite result is
    /// clamped to 0 so a bad spec can never poison the signal table.
    public func value(at t: Double, seed: UInt64) -> Float {
        let time = Float(t)
        var sum = bias
        for (i, comp) in components.enumerated() {
            let ph = comp.rateHz * time + comp.phase
            sum += comp.amplitude * comp.wave.sample(phase: ph, seed: seed &+ UInt64(i))
        }
        return sum.isFinite ? sum : 0
    }
}
