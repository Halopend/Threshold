// CameraRig.swift — camera as catalog content (plan §8.3: "Camera is a
// parameter group like any other … camera animation, gesture orbit, and
// music-driven camera drift all use lanes").
//
// The rig is an OFFSET over the scene's base pose (CameraDTO): yaw/pitch
// orbit the camera around a target derived from the base pose, dolly scales
// the distance to it. Defaults (0, 0, ×1) reproduce the base pose EXACTLY —
// including roll — so scenes render identically until something writes a
// lane. Desktop drag/scroll write the gesture lane (transient, Invariant 3);
// sliders write user; scenes/animations author the same params.

import Foundation
import simd

// MARK: - Param keys

extension ParamKey {
    /// Orbit offset around the world-up axis through the target, radians.
    public static let cameraOrbitYaw = ParamKey("camera.orbitYaw")
    /// Orbit offset around the camera-right axis through the target, radians.
    public static let cameraOrbitPitch = ParamKey("camera.orbitPitch")
    /// Distance-to-target multiplier (1 = authored distance).
    public static let cameraDolly = ParamKey("camera.dolly")
    /// World-space translation offset applied to the camera (two-hand grab
    /// pan). Zero = no pan.
    public static let cameraPan = ParamKey("camera.pan")
    /// Free rotation offset as a rotation-vector (axis·angle) about the orbit
    /// target (two-hand grab twist). Zero = no rotation. Lives beside the
    /// yaw/pitch orbit because grab produces an arbitrary-axis rotation that the
    /// two orbit angles cannot express.
    public static let cameraTwist = ParamKey("camera.twist")
}

// MARK: - Catalog registration

extension Catalog {
    /// Register the camera rig params. Called by `withEngineDefaults` —
    /// separate so tests can build minimal catalogs without them.
    public func registerCameraParams() throws {
        try register(ParamSpec(
            key: .cameraOrbitYaw, label: "Orbit Yaw",
            range: -25.13...25.13,  // ±4 turns; clamp is the spin stop
            default: 0,
            composition: .additive, smoothing: .continuous,
            persistence: .scene,
            capabilities: [.musicBindable, .gestureBindable, .animatable],
            group: .camera))
        try register(ParamSpec(
            key: .cameraOrbitPitch, label: "Orbit Pitch",
            range: -1.53...1.53,  // just short of the poles
            default: 0,
            composition: .additive, smoothing: .continuous,
            persistence: .scene,
            capabilities: [.musicBindable, .gestureBindable, .animatable],
            group: .camera))
        try register(ParamSpec(
            key: .cameraDolly, label: "Dolly",
            range: 0.05...20, default: 1,
            composition: .multiplicative, smoothing: .continuous,
            persistence: .scene,
            capabilities: [.musicBindable, .gestureBindable, .animatable],
            group: .camera))
        try register(ParamSpec(
            key: .cameraPan, label: "Pan",
            kind: .float3, range: -64...64,
            defaultValue: [0, 0, 0],
            // Instant on every lane: grab/translate need true 1:1 tracking —
            // a 0.15s continuous-smoothing tau (the catalog default) reads as
            // ~150ms of exponential lag behind the hand, killing the direct-
            // manipulation feel. Nothing else consumes this param yet.
            composition: .additive, smoothing: .instant,
            persistence: .scene,
            capabilities: [.musicBindable, .gestureBindable, .animatable],
            group: .camera))
        try register(ParamSpec(
            key: .cameraTwist, label: "Twist",
            kind: .float3, range: -8...8,
            defaultValue: [0, 0, 0],
            // Instant — see cameraPan.
            composition: .additive, smoothing: .instant,
            persistence: .scene,
            capabilities: [.musicBindable, .gestureBindable, .animatable],
            group: .camera))
    }
}

// MARK: - CameraRig

public enum CameraRig {
    /// A world pose: position + orientation quaternion (x, y, z, w),
    /// -Z forward.
    public struct Pose: Sendable, Equatable {
        public let position: SIMD3<Float>
        public let orientation: SIMD4<Float>
    }

    /// Apply resolved rig offsets to the scene's base pose.
    ///
    /// The orbit target sits `|basePosition|` along the base forward ray
    /// (for look-at-origin scenes that IS the origin; for others it keeps
    /// the view direction exact and orbits what the camera looks at).
    /// Yaw rotates about world up through the target; pitch about the
    /// yawed camera-right; dolly scales the distance. Degenerate base
    /// quaternions fall back to identity — same policy as the encoders.
    ///
    /// `pan` (world-space translation) and `twist` (a rotation-vector — axis
    /// scaled by angle) are the two-hand grab's extra degrees of freedom: grab
    /// produces an arbitrary translation + arbitrary-axis rotation that
    /// yaw/pitch/dolly cannot express. Both default to zero, so the
    /// four-argument orbit callers are unchanged.
    ///
    /// `twist` pivots about the WORLD ORIGIN, not the orbit `target` —
    /// deliberately different from yaw/pitch, which orbit the look-at target
    /// derived from the scene's authored base pose. The fractal is always
    /// evaluated relative to world origin (`RaymarchCore.metal`'s `mapScene`
    /// applies `worldP * modelScale` with no other placement offset), so
    /// origin is the only pivot that stays meaningful across repeated
    /// grab/release/pan cycles — `target` is re-derived from the FROZEN base
    /// pose every call and goes stale the moment the camera has moved since
    /// authoring (e.g. after a translate), which would rotate the world
    /// around a disconnected point instead of wherever the camera actually is.
    public static func pose(
        base: CameraDTO, yaw: Float, pitch: Float, dolly: Float,
        pan: SIMD3<Float> = .zero, twist: SIMD3<Float> = .zero
    ) -> Pose {
        let p0 = SIMD3(base.position[0], base.position[1], base.position[2])
        let rawQuat = SIMD4(
            base.orientation[0], base.orientation[1],
            base.orientation[2], base.orientation[3])
        let quatLength = (rawQuat * rawQuat).sum().squareRoot()
        let q0 = quatLength > 1e-6 && quatLength.isFinite
            ? simd_quatf(vector: rawQuat / quatLength)
            : simd_quatf(vector: SIMD4(0, 0, 0, 1))

        // No offsets at all: the base pose (position verbatim; orientation only
        // unit-normalized) — including roll, which a look-at reconstruction
        // would lose.
        if yaw == 0 && pitch == 0 && dolly == 1 && pan == .zero && twist == .zero {
            return Pose(position: p0, orientation: q0.vector)
        }

        let forward = q0.act(SIMD3(0, 0, -1))
        let baseDistance = simd_length(p0)
        let distance = baseDistance > 1e-4 ? baseDistance : 3
        let target = p0 + forward * distance

        let yawRot = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let right = yawRot.act(q0.act(SIMD3(1, 0, 0)))
        let pitchRot = simd_quatf(angle: pitch, axis: simd_normalize(right))
        let rot = pitchRot * yawRot

        let safeDolly = dolly.isFinite && dolly > 1e-4 ? dolly : 1
        var position = target + rot.act(p0 - target) * safeDolly
        var orientation = rot * q0

        // Free twist about the WORLD ORIGIN (grab): rotate both the camera
        // position and its orientation by the rotation-vector `twist`. See the
        // doc comment above for why this pivots at the origin, not `target`.
        let twistAngle = simd_length(twist)
        if twistAngle > 1e-6 && twistAngle.isFinite {
            let tq = simd_quatf(angle: twistAngle, axis: twist / twistAngle)
            position = tq.act(position)
            orientation = tq * orientation
        }
        // Free pan (grab): world-space translation of the camera.
        if pan.x.isFinite && pan.y.isFinite && pan.z.isFinite {
            position += pan
        }
        return Pose(position: position, orientation: simd_normalize(orientation).vector)
    }
}
