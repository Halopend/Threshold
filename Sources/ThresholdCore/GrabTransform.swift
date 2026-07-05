// GrabTransform.swift — two-hand grab math, ported VERBATIM from the old
// app's GrabZoomMapping (TEMP/MetalRaymarch-main/Threshold/Gestures/
// GrabZoomMapping.swift + GestureController.processTwoPointGrab), the
// reference for the feel.
//
// Captured ONCE when both hands engage (hand midpoint / separation / axis
// plus the DISPLAYED RoomPlacement — displayed, not target, so re-grabbing
// mid-smooth never pops; old GestureController.swift:785). Each frame
// `evaluate` maps the current hand positions through that fixed snapshot
// into an ABSOLUTE placement:
//
//   scaleRatio  = currentHandDistance / startHandDistance
//   newScale    = clamp(startScale × scaleRatio, scaleClamp)
//   effScale    = newScale / startScale          // respects the clamp
//   deltaRot    = shortestArc(startAxis → currentAxis)
//   rotation    = (deltaRot × startRotation).normalized
//   position    = currentMidpoint + deltaRot.act(effScale × (startPos − startMid))
//
// The position formula pins the hologram point under the hand midpoint at
// engage to wherever the midpoint moves; scale and rotation expand/twist
// around that anchor. True 1:1 — no deadzone, no attenuation. A pure
// function of current hands vs the snapshot: jitter never integrates, and
// tracking loss simply ends the gesture with the placement where it was.
//
// Rotation derives ONLY from the inter-hand axis — twisting the pair about
// its own axis (roll) is deliberately not a rotation, matching the old app.
// (The old code's "rotation breakaway"/rebase comments are dead code there;
// do not add them.)

import simd

/// Snapshot of a two-hand grab taken at engage, evaluated each frame into an
/// absolute RoomPlacement.
public struct GrabTransform: Sendable {
    /// Hand midpoint at engage (room meters).
    public let startMidpoint: SIMD3<Float>
    /// Hand separation at engage, clamped ≥ 1 cm (the 1:1 scale denominator).
    public let startDistance: Float
    /// Normalized right→left hand axis at engage (the twist reference).
    public let startAxis: SIMD3<Float>
    /// The DISPLAYED placement at engage.
    public let startPlacement: RoomPlacement

    /// The old app's default per-fractal grab-scale clamp
    /// (FractalTypeDescriptor.swift:181).
    public static let defaultScaleClamp: ClosedRange<Float> = 0.001...500
    /// The old app's Mandelbulb / MandelbulbJulia override
    /// (FractalTypeDescriptor.swift:336, 394).
    public static let mandelbulbScaleClamp: ClosedRange<Float> = 0.0005...2000

    /// Capture at engage. `left`/`right` are each hand's pinch point (the
    /// thumb–index midpoint), `placement` the currently DISPLAYED placement.
    public init(left: SIMD3<Float>, right: SIMD3<Float>, placement: RoomPlacement) {
        self.startMidpoint = (left + right) * 0.5
        self.startDistance = max(simd_length(left - right), 0.01)
        let axis = right - left
        let len = simd_length(axis)
        self.startAxis = len > 1e-4 ? axis / len : SIMD3(1, 0, 0)
        self.startPlacement = placement
    }

    /// Absolute placement for the current hand positions (old
    /// GrabZoomMapping.evaluate + evaluateCore, transcribed exactly —
    /// including the clamp-then-effScale order that keeps the midpoint
    /// pinned when the scale clamp saturates).
    public func evaluate(
        left: SIMD3<Float>, right: SIMD3<Float>,
        scaleClamp: ClosedRange<Float> = defaultScaleClamp
    ) -> RoomPlacement {
        let currentAxis = right - left
        let currentAxisLen = simd_length(currentAxis)
        let currentAxisNorm = currentAxisLen > 1e-4 ? currentAxis / currentAxisLen : startAxis
        let deltaRotation = Self.quaternionBetweenAxes(from: startAxis, to: currentAxisNorm)

        let currentMidpoint = (left + right) * 0.5
        let scaleRatio = simd_length(left - right) / startDistance
        let newScale = simd_clamp(
            startPlacement.scale * scaleRatio,
            scaleClamp.lowerBound, scaleClamp.upperBound)
        let effectiveScaleRatio = newScale / max(startPlacement.scale, 1e-6)
        let scaledOffset = effectiveScaleRatio * (startPlacement.position - startMidpoint)

        return RoomPlacement(
            position: currentMidpoint + deltaRotation.act(scaledOffset),
            rotation: (deltaRotation * startPlacement.rotation).normalized,
            scale: newScale)
    }

    /// Shortest-arc quaternion rotating unit vector `a` to unit vector `b`.
    /// Verbatim from the old `GrabZoomMapping.quaternionBetweenAxes`.
    public static func quaternionBetweenAxes(
        from a: SIMD3<Float>, to b: SIMD3<Float>
    ) -> simd_quatf {
        let dot = simd_clamp(simd_dot(a, b), -1.0, 1.0)
        let cross = simd_cross(a, b)
        let crossLen = simd_length(cross)
        if crossLen > 1e-6 {
            return simd_quatf(angle: acos(dot), axis: cross / crossLen)
        } else if dot < 0 {
            // Anti-parallel: rotate π around any perpendicular axis.
            let perp: SIMD3<Float> = abs(a.x) < 0.9
                ? simd_normalize(simd_cross(a, SIMD3<Float>(1, 0, 0)))
                : simd_normalize(simd_cross(a, SIMD3<Float>(0, 1, 0)))
            return simd_quatf(angle: .pi, axis: perp)
        } else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)  // identity
        }
    }
}
