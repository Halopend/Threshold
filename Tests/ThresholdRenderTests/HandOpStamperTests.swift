// HandOpStamperTests.swift — the spatial hand path's CPU math (plan §4.3):
// drive-flagged ops stamp from hand joints through the SAME room→fractal
// mapping as the eyes; unflagged ops pass through; lost tracking zeroes the
// effect instead of freezing a stale pose.

import Foundation
import simd
import Testing
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("Hand op stamping")
struct HandOpStamperTests {

    private var base: ThreshFrameUniforms {
        var u = ThreshFrameUniforms()
        u.camPosFov = SIMD4(0, 0, 3, 0.5)
        // Session camera yawed 180° — the stamp must compose through it.
        u.camQuat = simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)).vector
        return u
    }

    private func attract(flags: WarpFlags) -> ThreshWarpOp {
        var op = ThreshWarpOp()
        op.kind = UInt32(ThreshWarpKindHandAttract.rawValue)
        op.flags = flags.rawValue
        op.strength = 0.7
        op.a = SIMD4(9, 9, 9, 0.15)  // stale center; authored radius
        op.b = SIMD4(1, 0.08, 0.5, 0.05)
        return op
    }

    private func carve(flags: WarpFlags) -> ThreshWarpOp {
        var op = ThreshWarpOp()
        op.kind = UInt32(ThreshWarpKindForearmCarve.rawValue)
        op.flags = flags.rawValue
        op.strength = 0.9
        op.a = SIMD4(9, 9, 9, 0.06)
        op.b = SIMD4(9, 9, 9, 0.04)
        return op
    }

    @Test func attractStampsThePalmThroughTheEyeMapping() {
        let anchor = SIMD3<Float>(0, 1.6, 0)
        let palm = anchor + SIMD3<Float>(0, 0, -1)  // one meter room-forward
        let right = HandOpStamper.Hand(palm: palm)

        let stamped = HandOpStamper.stamp(
            [attract(flags: .driveRightHand)],
            right: right, left: .untracked,
            base: base, anchorPosition: anchor)

        // Where the eye mapping puts that room point (yaw 180: −z → +z).
        let expected = CompositorViewMath.fractalPoint(
            room: palm, base: base, anchorPosition: anchor)
        #expect(abs(expected.z - 4) < 1e-5, "sanity: the mapping itself composes the yaw")
        let a = stamped[0].a
        #expect(simd_length(SIMD3(a.x, a.y, a.z) - expected) < 1e-6)
        #expect(a.w == 0.15, "authored radius survives the stamp")
        #expect(stamped[0].strength == 0.7)
    }

    @Test func carveStampsBothCapsuleEndsAndKeepsAuthoredScalars() {
        let wrist = SIMD3<Float>(0.2, 1.4, -0.4)
        let forearm = SIMD3<Float>(0.3, 1.3, -0.1)
        let left = HandOpStamper.Hand(wrist: wrist, forearm: forearm)

        let stamped = HandOpStamper.stamp(
            [carve(flags: .driveLeftHand)],
            right: .untracked, left: left,
            base: base, anchorPosition: .zero)

        let a = stamped[0].a, b = stamped[0].b
        let wantA = CompositorViewMath.fractalPoint(room: wrist, base: base, anchorPosition: .zero)
        let wantB = CompositorViewMath.fractalPoint(room: forearm, base: base, anchorPosition: .zero)
        #expect(simd_length(SIMD3(a.x, a.y, a.z) - wantA) < 1e-6)
        #expect(simd_length(SIMD3(b.x, b.y, b.z) - wantB) < 1e-6)
        #expect(a.w == 0.06 && b.w == 0.04, "authored radius/blend survive")
    }

    @Test func lostTrackingZeroesTheEffectForTheFrame() {
        let stamped = HandOpStamper.stamp(
            [attract(flags: .driveRightHand), carve(flags: .driveLeftHand)],
            right: .untracked, left: .untracked,
            base: base, anchorPosition: .zero)
        #expect(stamped[0].strength == 0, "no palm → attract vanishes")
        #expect(stamped[1].strength == 0, "no forearm → carve vanishes")
        #expect(stamped[0].a.x == 9, "stale geometry left alone (strength gates it)")
    }

    @Test func unflaggedOpsPassThroughUntouched() {
        let slider = attract(flags: [])  // the mandated non-hand control path
        let stamped = HandOpStamper.stamp(
            [slider],
            right: HandOpStamper.Hand(palm: SIMD3(1, 2, 3)), left: .untracked,
            base: base, anchorPosition: .zero)
        #expect(stamped[0].a == slider.a && stamped[0].strength == slider.strength)
    }
}
