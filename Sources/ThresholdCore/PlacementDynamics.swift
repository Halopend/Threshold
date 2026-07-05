// PlacementDynamics.swift — target/displayed smoothing for RoomPlacement,
// porting the old app's TWO gesture smoothing regimes (they are deliberately
// different; RenderSettings.swift:3846-3883 vs 3251-3257):
//
// • GRAB — `applyDetailState`: an adaptive one-pole applied per hand update.
//   motionMag = |Δpos| + 0.5·|Δ log scale|; t ramps 0.30 → 0.55 over
//   motionMag 0.001 → 0.02 (grab passes responsiveness = 1.0, so the ramp IS
//   the factor; the old responsiveness knob is dropped). Position lerps,
//   rotation slerps, scale lerps in log space (doubling and halving feel
//   symmetric). Writes target = displayed and kills the spring velocity so
//   the settle regime never fights the grab. The old factor was per-call at
//   a hardwired ~90 Hz; this engine can legitimately run onFrame at 45 Hz
//   (half-rate mode), so the factor is dt-corrected: tEff = 1−(1−t)^(90·dt).
//
// • SETTLE — everything else (translate accumulation, scene-apply reset):
//   displayed glides to target via the old renderer's critically-damped
//   smoothDamp (smoothTime 0.35 s = GestureDefaults.gestureSmoothing,
//   maxSpeed 12 m/s) on position; rotation/scale converge on a matching
//   exponential (τ = 0.35 s). The old app smoothDamped only position here
//   (translate never changes rotation/scale); the rotation/scale exponential
//   exists for the eased scene-apply reset (the old app eased into preset
//   placement via its scene transition rather than snapping).
//
// Pure and platform-free; unit-tested on any host.

import simd

/// Target + displayed placement pair with the old app's smoothing dynamics.
public struct PlacementDynamics: Sendable, Equatable {
    /// Where gestures say the hologram should be (raw, unsmoothed).
    public private(set) var target: RoomPlacement
    /// What the renderer shows this frame.
    public private(set) var displayed: RoomPlacement
    /// smoothDamp velocity for the settle regime's position spring.
    private var velocity: SIMD3<Float> = .zero

    // Grab one-pole (old applyDetailState constants, responsiveness = 1).
    static let grabTBase: Float = 0.30
    static let grabTMax: Float = 0.55
    static let grabRampStart: Float = 0.001
    static let grabRampEnd: Float = 0.02
    /// The hand-update cadence the old per-call factor was tuned at.
    static let referenceHz: Float = 90

    // Settle spring (old GestureDefaults.gestureSmoothing + maxPositionSpeed).
    static let settleSmoothTime: Float = 0.35
    static let settleMaxSpeed: Float = 12

    public init(placement: RoomPlacement = .identity) {
        self.target = placement
        self.displayed = placement
    }

    // MARK: Grab regime

    /// Apply an absolute grab evaluation: adaptive one-pole toward `new`,
    /// then target = displayed, velocity = 0 (old applyDetailState).
    public mutating func applyGrab(_ new: RoomPlacement, dt: Float) {
        // Defense in depth: never let a non-finite evaluation (or a
        // previously-poisoned displayed value) enter the one-pole — NaN
        // there is unrecoverable. Drop the frame / re-arm from the target.
        guard new.isFinite else { return }
        if !displayed.isFinite { displayed = target.isFinite ? target : .identity }
        let motionMag = simd_length(new.position - displayed.position)
            + 0.5 * abs(log(max(new.scale, 1e-6)) - log(max(displayed.scale, 1e-6)))
        let rampT = simd_clamp(
            (motionMag - Self.grabRampStart) / (Self.grabRampEnd - Self.grabRampStart),
            0, 1)
        let t = Self.grabTBase + (Self.grabTMax - Self.grabTBase) * rampT
        // dt-correct the per-call factor to the 90 Hz reference cadence.
        let steps = max(dt, 0) * Self.referenceHz
        let tEff = 1 - pow(1 - t, steps)

        displayed.position += (new.position - displayed.position) * tEff
        displayed.rotation = normalizedSlerp(displayed.rotation, new.rotation, tEff)
        displayed.scale = exp(
            log(max(displayed.scale, 1e-6))
                + (log(max(new.scale, 1e-6)) - log(max(displayed.scale, 1e-6))) * tEff)
        target = displayed
        velocity = .zero
    }

    // MARK: Settle regime

    /// Move the target (translate accumulation). Displayed follows via
    /// `settle`.
    public mutating func translate(by delta: SIMD3<Float>) {
        target.position += delta
    }

    /// Ease everything back to the authored view (scene apply / reset button).
    public mutating func reset() {
        target = .identity
    }

    /// Adopt a placement outright, no easing (initial state only).
    public mutating func snap(to placement: RoomPlacement) {
        target = placement
        displayed = placement
        velocity = .zero
    }

    /// Per-frame convergence displayed → target (no-op while a grab is
    /// active, since the grab keeps target == displayed).
    public mutating func settle(dt: Float) {
        guard dt > 0 else { return }
        if displayed == target, velocity == .zero { return }

        displayed.position = Self.smoothDamp(
            current: displayed.position, target: target.position,
            velocity: &velocity,
            smoothTime: Self.settleSmoothTime, maxSpeed: Self.settleMaxSpeed,
            dt: dt)

        // Exponential convergence for rotation/scale (τ = settleSmoothTime).
        let alpha = 1 - exp(-dt / Self.settleSmoothTime)
        displayed.rotation = normalizedSlerp(displayed.rotation, target.rotation, alpha)
        displayed.scale = exp(
            log(max(displayed.scale, 1e-6))
                + (log(max(target.scale, 1e-6)) - log(max(displayed.scale, 1e-6))) * alpha)

        // Land exactly once close — avoids denormal creep and lets the
        // settle fast-path re-arm.
        if simd_length(displayed.position - target.position) < 1e-5,
            simd_length(velocity) < 1e-5,
            abs(displayed.scale - target.scale) < 1e-6,
            simd_length(displayed.rotation.vector - target.rotation.vector) < 1e-5 {
            displayed = target
            velocity = .zero
        }
    }

    // MARK: Helpers

    /// Critically-damped spring toward `target` (the classic smoothDamp),
    /// with the old renderer's max-speed clamp.
    static func smoothDamp(
        current: SIMD3<Float>, target: SIMD3<Float>,
        velocity: inout SIMD3<Float>,
        smoothTime: Float, maxSpeed: Float, dt: Float
    ) -> SIMD3<Float> {
        let omega = 2 / max(smoothTime, 1e-4)
        let x = omega * dt
        let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)

        var change = current - target
        let maxChange = maxSpeed * smoothTime
        let changeLen = simd_length(change)
        if changeLen > maxChange { change *= maxChange / changeLen }
        let clampedTarget = current - change

        let temp = (velocity + omega * change) * dt
        velocity = (velocity - omega * temp) * decay
        return clampedTarget + (change + temp) * decay
    }

    /// slerp + renormalize, taking the short way around.
    private func normalizedSlerp(
        _ a: simd_quatf, _ b: simd_quatf, _ t: Float
    ) -> simd_quatf {
        var to = b
        if simd_dot(a.vector, b.vector) < 0 { to = simd_quatf(vector: -b.vector) }
        let out = simd_slerp(a, to, t)
        let len = simd_length(out.vector)
        return len > 1e-6 ? simd_quatf(vector: out.vector / len) : a
    }
}
