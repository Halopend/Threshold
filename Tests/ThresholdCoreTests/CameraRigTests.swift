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
