// RoomPlacement.swift — the gesture-driven "hologram in the room" transform
// (the old app's settings.position / worldRotation / detailScale, ported as
// one value). G maps hologram-local room coordinates to actual room
// coordinates: G(x) = position + rotation.act(scale · x). Gestures move the
// hologram by mutating G; the renderer applies it by mapping every room-space
// viewer (eyes, hand geometry) through G⁻¹ before the room→fractal map
// (CompositorViewMath), which is exactly equivalent — and keeps hand-meters,
// eye-meters, and hologram-meters in ONE coordinate frame, the property that
// made the old app's grab trivially 1:1 (no zoom-dependent unit conversion
// anywhere).
//
// Pure and platform-free so every consumer (grab math, view math, smoothing)
// unit-tests on any host.

import simd

/// A room-space similarity transform: where the hologram sits in the
/// physical room. Identity = the authored view, untouched.
public struct RoomPlacement: Sendable, Equatable {
    /// Hologram origin in room meters.
    public var position: SIMD3<Float>
    /// Hologram orientation (unit quaternion).
    public var rotation: simd_quatf
    /// Hologram scale (1 = authored size). Clamped by the grab's per-DE
    /// scale clamp; never zero.
    public var scale: Float

    public init(
        position: SIMD3<Float> = .zero,
        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        scale: Float = 1
    ) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = RoomPlacement()

    /// Exact-identity check — the view math takes a fast path that is
    /// bit-identical to the placement-free map (mirrors CameraRig.pose's
    /// zero-offset fast path).
    public var isIdentity: Bool {
        position == .zero && scale == 1
            && rotation.vector == SIMD4<Float>(0, 0, 0, 1)
    }

    /// All components finite — a guard against NaN/Inf poisoning the
    /// smoothing state irrecoverably.
    public var isFinite: Bool {
        position.x.isFinite && position.y.isFinite && position.z.isFinite
            && scale.isFinite
            && rotation.vector.x.isFinite && rotation.vector.y.isFinite
            && rotation.vector.z.isFinite && rotation.vector.w.isFinite
    }

    /// Hologram-local → room: `position + rotation.act(scale · x)`.
    public func map(_ local: SIMD3<Float>) -> SIMD3<Float> {
        position + rotation.act(scale * local)
    }

    /// Room → hologram-local: `rotation⁻¹.act((x − position) / scale)`.
    /// This is what viewers (eyes, hands) map through: moving the hologram
    /// by G ≡ moving every viewer by G⁻¹.
    public func inverseMap(_ room: SIMD3<Float>) -> SIMD3<Float> {
        rotation.inverse.act((room - position) / max(scale, 1e-6))
    }
}
