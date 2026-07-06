// GestureGate.swift — the universal engagement state machine (adversarial
// plan Phases 1–2). Every gesture — camera pinch-drag, assignable tap, swipe
// impulse — routes its per-frame *strength* (0…1, or nil when the signal is
// unavailable) through one of these. The gate turns a noisy, droppable
// scalar into a small set of clean edges the caller acts on:
//
//   idle → arming → active → (suspended) → idle
//
// The defenses that live HERE, once, instead of scattered per gesture:
//   • Hysteresis:  engage above `on`, release below `off` (< on) — no flicker
//                  at the rim.
//   • Dwell:       must hold above `on` for `armDwell` seconds before engaging
//                  — a single spurious frame never fires anything.
//   • Grace:       signal loss while active enters `suspended`, holding the
//                  gesture for `graceWindow` seconds so a blink of occlusion
//                  doesn't tear a drag; recovery `resumed`s (caller re-anchors,
//                  never diffing across the gap), expiry `released`s cleanly.
//   • Cooldown:    after release, refuse to re-arm for `cooldown` seconds.
//
// All timing is in SECONDS and advanced by the caller's `dt`, so behavior is
// frame-rate invariant (the old app's frame-counted timers were not). Pure
// value type: fully deterministic, no clock, unit-tested without a device.

import Foundation

public struct GateConfig: Sendable, Equatable {
    /// Strength at/above which arming begins.
    public var on: Float
    /// Strength below which an engaged gesture releases (`off < on` = hysteresis).
    public var off: Float
    /// Seconds strength must stay ≥ `on` before the gate engages.
    public var armDwell: Double
    /// Seconds an engaged gate tolerates a missing signal before releasing.
    public var graceWindow: Double
    /// Seconds after release during which the gate refuses to re-arm.
    public var cooldown: Double

    public init(
        on: Float = 0.7, off: Float = 0.4,
        armDwell: Double = 0.05, graceWindow: Double = 0.2, cooldown: Double = 0
    ) {
        precondition(off <= on, "GateConfig hysteresis requires off <= on")
        self.on = on
        self.off = off
        self.armDwell = armDwell
        self.graceWindow = graceWindow
        self.cooldown = cooldown
    }

    /// Continuous latched gestures (camera drag, tapThumb accumulator): short
    /// dwell, generous grace so an occlusion blink doesn't drop the hold.
    public static let latched = GateConfig(
        on: 0.7, off: 0.4, armDwell: 0.04, graceWindow: 0.2, cooldown: 0.05)

    /// Discrete one-shot gestures (swipe, menu taps): a touch more dwell to
    /// reject brush-bys, plus a cooldown so one motion fires once.
    public static let discrete = GateConfig(
        on: 0.7, off: 0.4, armDwell: 0.06, graceWindow: 0, cooldown: 0.4)
}

public enum GateState: Sendable, Equatable {
    case idle
    case arming
    case active
    case suspended
    case cooling
}

/// The per-frame verdict. `justEngaged`/`justReleased`/`resumed` are one-frame
/// edges; `live` means "active and the signal is present this frame — safe to
/// accumulate"; `suspended` means "holding through a signal gap — freeze".
public struct GateTick: Sendable, Equatable {
    public var state: GateState
    public var engaged: Bool
    public var live: Bool
    public var suspended: Bool
    public var justEngaged: Bool
    public var justReleased: Bool
    public var resumed: Bool
    /// 0…1 fill while arming (for arming visualization); 1 once active.
    public var armingProgress: Float

    static let inactive = GateTick(
        state: .idle, engaged: false, live: false, suspended: false,
        justEngaged: false, justReleased: false, resumed: false, armingProgress: 0)
}

public struct GestureGate: Sendable, Equatable {
    public private(set) var state: GateState = .idle
    private var dwell: Double = 0
    private var graceElapsed: Double = 0
    private var cooldownLeft: Double = 0

    public init() {}

    /// Advance one frame. `strength` is nil when the driving signal is
    /// unavailable (joint lost / below confidence); otherwise 0…1.
    public mutating func update(strength: Float?, dt: Double) -> GateTick {
        // Cooldown always bleeds off, in every state.
        if cooldownLeft > 0 { cooldownLeft = max(0, cooldownLeft - dt) }

        guard let s = strength else { return signalLost(dt: dt) }

        switch state {
        case .cooling:
            // Ignore strength until the cooldown expires; then behave as idle.
            if cooldownLeft > 0 {
                var t = GateTick.inactive
                t.state = .cooling
                return t
            }
            state = .idle
            return updateIdle(s)

        case .idle:
            return updateIdle(s)

        case .arming:
            if s < config.off {
                state = .idle
                dwell = 0
                return .inactive
            }
            dwell += dt
            if dwell >= config.armDwell {
                state = .active
                var t = GateTick.inactive
                t.state = .active
                t.engaged = true
                t.live = true
                t.justEngaged = true
                t.armingProgress = 1
                return t
            }
            return (GateTick(
                    state: .arming, engaged: false, live: false, suspended: false,
                    justEngaged: false, justReleased: false, resumed: false,
                    armingProgress: Float(min(1, dwell / max(config.armDwell, 1e-9)))))

        case .active:
            if s < config.off { return release() }
            var t = GateTick.inactive
            t.state = .active
            t.engaged = true
            t.live = true
            t.armingProgress = 1
            return t

        case .suspended:
            // Signal is back. Resume if still holding, else release.
            graceElapsed = 0
            if s >= config.off {
                state = .active
                var t = GateTick.inactive
                t.state = .active
                t.engaged = true
                t.live = true
                t.resumed = true
                t.armingProgress = 1
                return t
            }
            return release()
        }
    }

    /// Force the gate back to idle (scene load / binding edit / UI suppression).
    /// Not a release edge — the caller drops state without committing.
    public mutating func reset() {
        state = .idle
        dwell = 0
        graceElapsed = 0
        cooldownLeft = 0
    }

    // MARK: Config (per-gate, set at construction via `configured`)

    private var config: GateConfig = .latched

    public init(_ config: GateConfig) {
        self.config = config
    }

    // MARK: Helpers

    private mutating func updateIdle(_ s: Float) -> GateTick {
        guard cooldownLeft <= 0 else { return .inactive }
        if s >= config.on {
            state = .arming
            dwell = 0
            // Zero-dwell configs engage on the same frame they arm.
            if config.armDwell <= 0 {
                state = .active
                var t = GateTick.inactive
                t.state = .active
                t.engaged = true
                t.live = true
                t.justEngaged = true
                t.armingProgress = 1
                return t
            }
            return (GateTick(
                    state: .arming, engaged: false, live: false, suspended: false,
                    justEngaged: false, justReleased: false, resumed: false,
                    armingProgress: 0))
        }
        return .inactive
    }

    private mutating func signalLost(dt: Double) -> GateTick {
        switch state {
        case .active, .suspended:
            state = .suspended
            graceElapsed += dt
            if graceElapsed > config.graceWindow { return release() }
            var t = GateTick.inactive
            t.state = .suspended
            t.engaged = true
            t.suspended = true
            t.armingProgress = 1
            return t
        case .arming:
            // Lost mid-arm: never engaged, so just drop it.
            state = .idle
            dwell = 0
            return .inactive
        case .idle, .cooling:
            return .inactive
        }
    }

    private mutating func release() -> GateTick {
        state = .cooling
        dwell = 0
        graceElapsed = 0
        cooldownLeft = config.cooldown
        var t = GateTick.inactive
        t.state = .cooling
        t.justReleased = true
        return t
    }

}
