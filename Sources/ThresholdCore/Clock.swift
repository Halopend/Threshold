// Clock.swift — the AppClock abstraction (plan §8.1, Invariant 9).
//
// Invariant 9: NO AMBIENT TIME. Nothing in feature code may call `Date()`,
// `CACurrentMediaTime()`, or `DispatchTime.now()`. Every time-dependent system
// (modulation smoothing, music decay, integrators, animation) takes an
// `AppClock` as a dependency. Even the clock implementations in this file
// never read system time themselves: `WallClock` is *fed* frame timestamps by
// the render loop (`update(now:)`), and `FixedStepClock` is advanced manually
// by the deterministic harness. This is what makes byte-identical captures
// trivial.
//
// Concurrency: clocks are NOT Sendable. They are render-thread confined,
// like the `ModulationEngine` that consumes them (ADR-004).

/// Injected time source for all time-dependent systems.
///
/// - `now`: accumulated app time in seconds. Does not advance while paused.
/// - `delta`: raw (un-scaled) seconds elapsed since the previous frame;
///   `0` while paused. Smoothing uses `delta` directly; integrators scale it
///   by `timeScale` (`phase += rate * delta * timeScale`).
/// - `paused`: when true, smoothing, decay, and integrators must not advance.
/// - `timeScale`: rate multiplier for *content* time (integrator phases,
///   animation). Deliberately not baked into `delta` so that input smoothing
///   feels identical at any time scale.
public protocol AppClock: AnyObject {
    var now: Double { get }
    var delta: Double { get }
    var paused: Bool { get }
    var timeScale: Double { get }
}

/// Deterministic clock for the harness and for tests: every `advance()` is
/// exactly one fixed step. Byte-identical captures depend on this.
public final class FixedStepClock: AppClock {
    public let step: Double
    public private(set) var now: Double
    public private(set) var delta: Double = 0
    public var paused: Bool = false
    public var timeScale: Double

    public init(step: Double = 1.0 / 60.0, startingAt now: Double = 0, timeScale: Double = 1.0) {
        precondition(step >= 0, "FixedStepClock step must be >= 0")
        self.step = step
        self.now = now
        self.timeScale = timeScale
    }

    /// Advance by one fixed step. While paused, `now` freezes and `delta`
    /// becomes 0 (frames still happen; time does not pass).
    public func advance() {
        if paused {
            delta = 0
        } else {
            now += step
            delta = step
        }
    }

    /// Advance by `frames` fixed steps. After the call, `delta` reflects the
    /// LAST single step only (a consumer resolving once sees one frame's dt).
    public func advance(frames: Int) {
        precondition(frames >= 0)
        for _ in 0..<frames { advance() }
    }
}

/// Production clock. The render loop passes each frame's timestamp in
/// (`CAMetalDisplayLink` / Compositor frame time); `WallClock` NEVER reads
/// system time itself — Invariant 9 applies to this file too.
public final class WallClock: AppClock {
    /// Accumulated app time. Pausing freezes it; unpausing resumes without a
    /// jump (paused wall-time spans are simply not accumulated).
    public private(set) var now: Double
    public private(set) var delta: Double = 0
    public var paused: Bool = false
    public var timeScale: Double = 1.0

    private var lastTimestamp: Double?

    public init(startingAt now: Double = 0) {
        self.now = now
    }

    /// Feed the current frame's timestamp (seconds, any monotonic origin).
    /// The first call establishes the baseline and yields `delta == 0`.
    /// Backwards timestamps are treated as `delta == 0`, never negative.
    public func update(now timestamp: Double) {
        let raw: Double
        if let last = lastTimestamp {
            raw = max(0, timestamp - last)
        } else {
            raw = 0
        }
        lastTimestamp = timestamp
        delta = paused ? 0 : raw
        now += delta
    }
}
