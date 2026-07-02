// Binding.swift — the signal→lane binding data model (plan §4.2, §4.2.1).
// Bindings are DATA: scenes persist them, the binding UI edits them, and the
// render-thread BindingEngine (Bindings+Engine.swift) executes them. Music
// reactivity and hand reactivity are literally this one mechanism with
// different signal sources.

import Foundation

// MARK: - Policy

public enum BindingPolicy: String, Codable, Sendable, CaseIterable {
    /// Lane value decays/clears when the signal goes stale (release-to-rest).
    case momentary
    /// Lane value holds after the signal ends, until re-grabbed or cleared.
    case latched
}

// MARK: - Mapping

/// Response curve applied to the normalized (0…1) signal value. The current
/// app's curve vocabulary (plan §12.6): Linear / Exponential / Smooth /
/// Step / Pulse. ("Wave" and "Follow" from §4.2.1 need beat phase and
/// drift-state respectively — they arrive with the beat clock, not here.)
public enum MappingCurve: Codable, Sendable, Equatable, Hashable {
    case linear
    /// `t^k` — k > 1 emphasizes peaks, k < 1 emphasizes quiet detail.
    case exponential(k: Float)
    /// smoothstep(t) — softened response at both ends.
    case smooth
    /// Quantize into `count` levels (count >= 2).
    case step(count: Int)
    /// 0/1 gate at `threshold`.
    case pulse(threshold: Float)

    /// Apply the curve to a normalized input. Input is clamped to 0…1;
    /// output is in 0…1.
    public func apply(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear:
            return x
        case .exponential(let k):
            let kk = k.isFinite && k > 0 ? k : 1
            return powf(x, kk)
        case .smooth:
            return x * x * (3 - 2 * x)
        case .step(let count):
            let n = Float(max(count, 2))
            return (n - 1 == 0) ? x : (x * n).rounded(.down).clamped(to: 0...(n - 1)) / (n - 1)
        case .pulse(let threshold):
            return x >= threshold ? 1 : 0
        }
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Signal domain → lane write mapping.
public struct SignalMapping: Codable, Sendable, Equatable, Hashable {
    /// Raw signal values at/below `lowerBound` map to 0, at/above
    /// `upperBound` map to 1 (then the curve applies).
    public var inputLo: Float
    public var inputHi: Float
    /// Curve output 0…1 lerps into this lane-write range.
    public var outputLo: Float
    public var outputHi: Float
    public var curve: MappingCurve
    /// Raw input magnitudes below this are treated as 0 (noise floor).
    public var deadzone: Float

    public init(
        inputLo: Float = 0, inputHi: Float = 1,
        outputLo: Float = 0, outputHi: Float = 1,
        curve: MappingCurve = .linear, deadzone: Float = 0
    ) {
        self.inputLo = inputLo
        self.inputHi = inputHi
        self.outputLo = outputLo
        self.outputHi = outputHi
        self.curve = curve
        self.deadzone = deadzone
    }

    /// Raw signal value → lane write value.
    public func apply(_ raw: Float) -> Float {
        guard raw.isFinite else { return outputLo }
        let gated = abs(raw) < deadzone ? 0 : raw
        let span = inputHi - inputLo
        let t = span > 1e-9 ? (gated - inputLo) / span : 0
        let shaped = curve.apply(t)
        return outputLo + (outputHi - outputLo) * shaped
    }
}

// MARK: - Binding

public struct Binding: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var signal: SignalID
    public var param: ParamKey
    /// Vector component offset (0 for scalars).
    public var component: Int
    /// Only the transient lanes are bindable (plan §4.2): .gesture or .music.
    /// Enforced by the BindingEngine at apply time.
    public var lane: Lane
    public var mapping: SignalMapping
    public var policy: BindingPolicy
    /// User-tunable strength multiplier on the mapped value.
    public var scale: Float

    public init(
        id: UUID = UUID(),
        signal: SignalID,
        param: ParamKey,
        component: Int = 0,
        lane: Lane,
        mapping: SignalMapping = SignalMapping(),
        policy: BindingPolicy = .momentary,
        scale: Float = 1
    ) {
        self.id = id
        self.signal = signal
        self.param = param
        self.component = component
        self.lane = lane
        self.mapping = mapping
        self.policy = policy
        self.scale = scale
    }
}
