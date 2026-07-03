// QualityGovernor.swift — the fps-holding quality governor (ADR-003,
// plan §6.4): the first REGISTERED system-lane writer. It emits one 0…1
// factor per frame; the session writes it to the quality-class params
// (engine.maxSteps, engine.iterations — declared `.multiplicative` exactly
// so this composes as `user × system`: the user's slider is a CEILING they
// can lower past but not raise above the governor).
//
// Pure controller — no time source, no engine reference: the caller feeds
// the previous completed frame's GPU milliseconds and writes the returned
// factor. AIMD shape (multiplicative decrease, additive recovery) so it
// backs off fast on a heavy view and creeps back without oscillating.

public struct QualityGovernorConfig: Sendable, Equatable {
    /// GPU frame budget. Over it, quality drops; comfortably under it,
    /// quality recovers.
    public var targetMilliseconds: Double
    /// The governor never drops quality below this factor — past it, the
    /// honest outcome is a lower frame rate, not an unrecognizable image.
    public var floor: Float

    public init(targetMilliseconds: Double = 8.0, floor: Float = 0.25) {
        self.targetMilliseconds = targetMilliseconds
        self.floor = floor
    }
}

public struct QualityGovernor: Sendable, Equatable {
    public private(set) var factor: Float = 1

    public init() {}

    /// One frame: feed the previous completed frame's GPU duration, get the
    /// factor to write. `gpuMilliseconds <= 0` (no completed frame yet)
    /// holds the current factor.
    public mutating func update(
        gpuMilliseconds: Double, config: QualityGovernorConfig
    ) -> Float {
        guard gpuMilliseconds > 0, gpuMilliseconds.isFinite,
              config.targetMilliseconds > 0
        else { return factor }

        if gpuMilliseconds > config.targetMilliseconds * 1.05 {
            // Multiplicative decrease, proportional to the overshoot but
            // never more than 10% per frame (one bad frame ≠ freefall).
            let ratio = Float(config.targetMilliseconds / gpuMilliseconds)
            factor *= max(0.9, ratio)
        } else if gpuMilliseconds < config.targetMilliseconds * 0.75 {
            // Additive recovery: ~0.25 of headroom per second at 60 fps.
            factor += 0.004
        }
        factor = min(max(factor, config.floor), 1)
        return factor
    }

    public mutating func reset() {
        factor = 1
    }
}
