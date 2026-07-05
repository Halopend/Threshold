// CameraRigTests.swift — camera-as-catalog-content (plan §8.3): the offset
// rig over the scene's base pose.

import Foundation
import simd
import Testing
import ThresholdCore

@Suite("Camera rig")
struct CameraRigTests {
    /// A base pose with ROLL (30° about the view axis) looking at the origin
    /// from +Z — the rig must preserve it exactly at identity offsets.
    private var rolledBase: CameraDTO {
        let roll = simd_quatf(angle: .pi / 6, axis: SIMD3(0, 0, -1))
        return CameraDTO(
            position: [0, 0, 3],
            orientation: [roll.vector.x, roll.vector.y, roll.vector.z, roll.vector.w],
            fovYRadians: .pi / 3)
    }

    @Test func identityOffsetsReproduceTheBasePoseExactly() {
        let pose = CameraRig.pose(base: rolledBase, yaw: 0, pitch: 0, dolly: 1)
        #expect(pose.position == SIMD3(0, 0, 3))
        // Roll survives (a look-at reconstruction would lose it); the only
        // permitted difference is the unit-normalization rounding.
        let base = rolledBase
        let expected = SIMD4(
            base.orientation[0], base.orientation[1],
            base.orientation[2], base.orientation[3])
        #expect(simd_length(pose.orientation - expected) < 1e-6)
    }

    @Test func halfTurnYawOrbitsToTheOppositeSide() {
        let base = CameraDTO(position: [0, 0, 3], orientation: [0, 0, 0, 1],
                             fovYRadians: .pi / 3)
        let pose = CameraRig.pose(base: base, yaw: .pi, pitch: 0, dolly: 1)
        // Looking at origin from +Z, a π yaw lands at −Z, same distance.
        #expect(abs(pose.position.x) < 1e-5)
        #expect(abs(pose.position.y) < 1e-5)
        #expect(abs(pose.position.z + 3) < 1e-5)
        // Still looking at the target: forward points from position to origin.
        let q = simd_quatf(vector: pose.orientation)
        let forward = q.act(SIMD3(0, 0, -1))
        #expect(simd_length(forward - SIMD3(0, 0, 1)) < 1e-5)
    }

    @Test func dollyScalesDistanceToTargetOnly() {
        let base = CameraDTO(position: [0, 0, 4], orientation: [0, 0, 0, 1],
                             fovYRadians: .pi / 3)
        let pose = CameraRig.pose(base: base, yaw: 0, pitch: 0, dolly: 0.5)
        #expect(simd_length(pose.position - SIMD3<Float>(0, 0, 2)) < 1e-5)
        // Orientation unchanged by pure dolly.
        #expect(simd_length(pose.orientation - SIMD4<Float>(0, 0, 0, 1)) < 1e-5)
    }

    @Test func pitchOrbitsVertically() {
        let base = CameraDTO(position: [0, 0, 3], orientation: [0, 0, 0, 1],
                             fovYRadians: .pi / 3)
        let pose = CameraRig.pose(base: base, yaw: 0, pitch: .pi / 2, dolly: 1)
        // From +Z, pitching by π/2 about camera-right (+X) lands... on ±Y at
        // the same distance from the origin target.
        #expect(abs(simd_length(pose.position) - 3) < 1e-4)
        #expect(abs(abs(pose.position.y) - 3) < 1e-4)
    }

    @Test func degenerateQuaternionFallsBackToIdentity() {
        let base = CameraDTO(position: [0, 0, 3], orientation: [0, 0, 0, 0],
                             fovYRadians: .pi / 3)
        let pose = CameraRig.pose(base: base, yaw: 0, pitch: 0, dolly: 1)
        #expect(pose.orientation == SIMD4(0, 0, 0, 1))
    }

    // MARK: - Two-hand grab DOF (pan + twist)

    @Test func panTranslatesTheCameraInWorldSpace() {
        let base = CameraDTO(position: [0, 0, 3], orientation: [0, 0, 0, 1],
                             fovYRadians: .pi / 3)
        let pose = CameraRig.pose(
            base: base, yaw: 0, pitch: 0, dolly: 1,
            pan: SIMD3(1, 2, -0.5))
        #expect(simd_length(pose.position - SIMD3<Float>(1, 2, 2.5)) < 1e-5)
        // Pure pan does not rotate.
        #expect(simd_length(pose.orientation - SIMD4<Float>(0, 0, 0, 1)) < 1e-5)
    }

    @Test func twistRotatesAboutTheWorldOrigin() {
        // This base pose looks straight at the origin (position (0,0,3),
        // forward -Z), so its orbit `target` COINCIDES with the origin —
        // insufficient on its own to distinguish "pivots at target" from
        // "pivots at origin". See `twistPivotsAtOriginNotAtAnOffTargetPoint`
        // below for the case that actually tells them apart.
        let base = CameraDTO(position: [0, 0, 3], orientation: [0, 0, 0, 1],
                             fovYRadians: .pi / 3)
        // Rotation-vector of magnitude π about world-up: swings the camera from
        // +Z to −Z about the origin (like a π yaw), same distance.
        let pose = CameraRig.pose(
            base: base, yaw: 0, pitch: 0, dolly: 1,
            twist: SIMD3(0, .pi, 0))
        #expect(abs(pose.position.x) < 1e-4)
        #expect(abs(pose.position.y) < 1e-4)
        #expect(abs(pose.position.z + 3) < 1e-4)
        // Still framing the origin: forward points back toward +Z.
        let q = simd_quatf(vector: pose.orientation)
        let forward = q.act(SIMD3(0, 0, -1))
        #expect(simd_length(forward - SIMD3(0, 0, 1)) < 1e-4)
    }

    @Test func twistPivotsAtOriginNotAtAnOffTargetPoint() {
        // A base pose that does NOT look through the origin: positioned at
        // (5, 0, 0), facing +X (away from the origin), so `target` (derived
        // from base position + forward*distance) sits at (10, 0, 0) — nowhere
        // near the origin. If twist pivoted at `target` (the old, stale-pivot
        // behavior), the camera would swing around (10,0,0); pivoting at the
        // world origin, it must swing around (0,0,0) instead.
        let facingPlusX = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let base = CameraDTO(
            position: [5, 0, 0],
            orientation: [facingPlusX.vector.x, facingPlusX.vector.y,
                          facingPlusX.vector.z, facingPlusX.vector.w],
            fovYRadians: .pi / 3)
        // Half-turn twist about world-up: a point at (5,0,0) rotated π about
        // the ORIGIN lands at (-5,0,0); about `target` (10,0,0) it would land
        // at (15,0,0) instead.
        let pose = CameraRig.pose(
            base: base, yaw: 0, pitch: 0, dolly: 1,
            twist: SIMD3(0, .pi, 0))
        #expect(simd_length(pose.position - SIMD3<Float>(-5, 0, 0)) < 1e-4,
                "twist must pivot at the world origin, not the stale orbit target")
    }

    @Test func zeroPanAndTwistLeaveTheOrbitPoseUnchanged() {
        let base = CameraDTO(position: [0, 0, 3], orientation: [0, 0, 0, 1],
                             fovYRadians: .pi / 3)
        let orbit = CameraRig.pose(base: base, yaw: 0.4, pitch: 0.2, dolly: 0.8)
        let withZero = CameraRig.pose(
            base: base, yaw: 0.4, pitch: 0.2, dolly: 0.8,
            pan: .zero, twist: .zero)
        #expect(simd_length(orbit.position - withZero.position) < 1e-6)
        #expect(simd_length(orbit.orientation - withZero.orientation) < 1e-6)
    }

    @Test func engineDefaultsRegisterPanAndTwist() {
        let layout = Catalog.withEngineDefaults().freeze()
        for key in [ParamKey.cameraPan, .cameraTwist] {
            let entry = try! #require(layout.entry(for: key))
            #expect(entry.spec.group == .camera)
            #expect(entry.spec.kind == .float3)
            #expect(entry.spec.capabilities.contains(.gestureBindable))
        }
    }

    @Test func engineDefaultsRegisterTheRig() {
        let layout = Catalog.withEngineDefaults().freeze()
        for key in [ParamKey.cameraOrbitYaw, .cameraOrbitPitch, .cameraDolly] {
            let entry = try! #require(layout.entry(for: key))
            #expect(entry.spec.group == .camera)
            #expect(entry.spec.persistence == .scene,
                    "camera params are scene content (plan §8.3)")
            #expect(entry.spec.capabilities.contains(.gestureBindable))
        }
        #expect(layout.entry(for: .cameraDolly)?.spec.composition == .multiplicative)
    }
}
