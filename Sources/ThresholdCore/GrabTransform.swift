// GrabTransform.swift — two-hand grab math, ported from the old app's
// GrabZoomMapping (TEMP/MetalRaymarch-main/Threshold/Gestures/GrabZoomMapping.swift),
// which "worked relatively well" and is the reference for the feel.
//
// Pure and platform-free so it unit-tests on any host; the visionOS HandTracker
// feeds it hand pinch points and maps its output onto the camera rig.
//
// The original mapped the gesture onto a FRACTAL transform (position / rotation
// / detailScale) — it moved the fractal. The rebuild is camera-centric (the
// fractal sits at the origin and the CAMERA moves), so this exposes the raw
// per-frame deltas — separation ratio, shortest-arc twist, midpoint travel —
// captured against an engage snapshot, and the caller applies them to the
// camera (as the inverse: scaling/rotating the environment ≡ moving the camera
// oppositely). The 1:1 scale-tracking and shortest-arc twist are preserved
// verbatim; only the application target changes.

import simd

/// Snapshot of a two-hand grab taken when both hands engage, evaluated each
/// frame into camera-agnostic deltas.
public struct GrabTransform: Sendable {
    /// Hand midpoint at engage.
    public let startMidpoint: SIMD3<Float>
    /// Hand separation at engage, clamped ≥ 1 cm (the 1:1 scale denominator).
    public let startDistance: Float
    /// Normalized right→left hand axis at engage (the twist reference).
    public let startAxis: SIMD3<Float>

    /// Capture at engage. `left`/`right` are each hand's pinch point (the
    /// thumb–index midpoint).
    public init(left: SIMD3<Float>, right: SIMD3<Float>) {
        self.startMidpoint = (left + right) * 0.5
        self.startDistance = max(simd_length(left - right), 0.01)
        let axis = right - left
        let len = simd_length(axis)
        self.startAxis = len > 1e-4 ? axis / len : SIMD3(1, 0, 0)
    }

    /// Per-frame grab deltas relative to the engage snapshot:
    /// - `scaleRatio`: currentSeparation / startSeparation (1 = unchanged; > 1 =
    ///   hands pulled apart, i.e. the environment scales up / zoom in). True
    ///   1:1 tracking — no deadzone, no attenuation (the old app's signature).
    /// - `rotation`: shortest-arc rotation of the two-hand axis since engage.
    /// - `midpointTravel`: how far the hand midpoint has moved since engage.
    public func evaluate(left: SIMD3<Float>, right: SIMD3<Float>)
        -> (scaleRatio: Float, rotation: simd_quatf, midpointTravel: SIMD3<Float>) {
        let axis = right - left
        let len = simd_length(axis)
        let currentAxis = len > 1e-4 ? axis / len : startAxis
        let rotation = Self.quaternionBetweenAxes(from: startAxis, to: currentAxis)
        let scaleRatio = simd_length(left - right) / startDistance
        let midpointTravel = (left + right) * 0.5 - startMidpoint
        return (scaleRatio, rotation, midpointTravel)
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
