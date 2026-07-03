// QualityGovernor.swift — the fps-holding quality governor (ADR-003,
// plan §6.4). It emits one 0…1 factor per frame; the session maps it to a
// RESOLUTION scale only (renderScale = √factor, so factor ≈ the pixel-cost
// fraction). Resolution is the one lever that never changes the fractal
// itself — each platform applies it through its native mechanism
// (visionOS: compositor renderQuality; Mac/iOS: MetalFX temporal upscale).
//
// Deliberately NOT a lever anymore: iterations/maxSteps system-lane writes.
// Measured 2026-07-03: reducing iterations visibly changes the DE (the
// mandelbulb's surface detail/threshold jumps), which reads as the fractal
// morphing under load — and the discontinuous jumps cost more than they
// saved. Resolution softens; it never reshapes.
//
// Pure controller — no time source, no engine reference: the caller feeds
// the previous completed frame's GPU milliseconds and maps the returned
// factor. AIMD shape (multiplicative decrease, additive recovery) so it
// backs off fast on a heavy view and creeps back without oscillating.

public struct QualityGovernorConfig: Sendable, Equatable {
    /// GPU frame budget. Over it, quality drops; comfortably under it,
    /// quality recovers.
    public var targetMilliseconds: Double
    /// The lowest resolution scale the governor may reach (per axis). Past
    /// it, the honest outcome is a lower frame rate, not a soup of pixels.
    /// Platform shells pick this by upscaler quality: MetalFX temporal
    /// reconstructs well down to ~0.35; the visionOS compositor upscaler is
    /// tuned around milder scales (0.5).
    public var minRenderScale: Float

    public init(targetMilliseconds: Double = 8.0, minRenderScale: Float = 0.5) {
        self.targetMilliseconds = targetMilliseconds
        self.minRenderScale = minRenderScale
    }

    /// The shipping default for the current platform (single definition —
    /// every shell arms the governor with this unless profiling overrides).
    /// Vision Pro: 90 fps is an 11.1 ms budget; aim under it to leave the
    /// compositor present/reproject headroom. Mac: 120 Hz-friendly 8 ms.
    public static var platformDefault: QualityGovernorConfig {
        #if os(visionOS)
        QualityGovernorConfig(targetMilliseconds: 10.0, minRenderScale: 0.5)
        #else
        QualityGovernorConfig(targetMilliseconds: 8.0, minRenderScale: 0.35)
        #endif
    }
}

public struct QualityGovernor: Sendable, Equatable {
    public private(set) var factor: Float = 1

    public init() {}

    /// One frame: feed the previous completed frame's GPU duration, get the
    /// factor (≈ pixel-cost fraction; the session maps it to √factor render
    /// scale). `gpuMilliseconds <= 0` (no completed frame yet) holds the
    /// current factor.
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
        let floor = config.minRenderScale * config.minRenderScale
        factor = min(max(factor, floor), 1)
        return factor
    }

    public mutating func reset() {
        factor = 1
    }
}
