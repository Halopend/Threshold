import simd
import Testing
@testable import ThresholdCore

// The ported two-hand grab math (from the old GrabZoomMapping): 1:1 separation
// ratio, shortest-arc twist, and midpoint travel, all relative to the engage
// snapshot.

@Suite("Grab transform")
struct GrabTransformTests {

    @Test func separationRatioIsOneToOne() {
        // Hands 0.2 m apart at engage, pulled to 0.6 m → scaleRatio 3, no twist,
        // no midpoint move.
        let grab = GrabTransform(left: SIMD3(-0.1, 0, 0), right: SIMD3(0.1, 0, 0))
        let r = grab.evaluate(left: SIMD3(-0.3, 0, 0), right: SIMD3(0.3, 0, 0))
        #expect(abs(r.scaleRatio - 3) < 1e-5)
        #expect(simd_length(r.midpointTravel) < 1e-6)
        #expect(simd_length(r.rotation.vector - SIMD4<Float>(0, 0, 0, 1)) < 1e-5)
    }

    @Test func midpointTravelTracksBothHandsMoving() {
        let grab = GrabTransform(left: SIMD3(-0.1, 0, 0), right: SIMD3(0.1, 0, 0))
        // Slide both hands +0.15 in x, +0.05 in y (separation unchanged).
        let r = grab.evaluate(left: SIMD3(0.05, 0.05, 0), right: SIMD3(0.25, 0.05, 0))
        #expect(abs(r.scaleRatio - 1) < 1e-5)
        #expect(simd_length(r.midpointTravel - SIMD3<Float>(0.15, 0.05, 0)) < 1e-5)
    }

    @Test func twistIsTheShortestArcOfTheHandAxis() {
        // Axis starts along +x; rotate hands so the axis points along +y (a 90°
        // turn about +z). Separation preserved.
        let grab = GrabTransform(left: SIMD3(-0.1, 0, 0), right: SIMD3(0.1, 0, 0))
        let r = grab.evaluate(left: SIMD3(0, -0.1, 0), right: SIMD3(0, 0.1, 0))
        // Applying the rotation to the start axis (+x) must land on the current
        // axis (+y).
        let landed = r.rotation.act(SIMD3<Float>(1, 0, 0))
        #expect(simd_length(landed - SIMD3<Float>(0, 1, 0)) < 1e-4)
    }

    @Test func quaternionBetweenAxesHandlesIdentityAndAntiparallel() {
        let x = SIMD3<Float>(1, 0, 0)
        // Identity.
        let same = GrabTransform.quaternionBetweenAxes(from: x, to: x)
        #expect(simd_length(same.act(x) - x) < 1e-5)
        // Anti-parallel: +x → −x, any perpendicular axis, must land on −x.
        let flip = GrabTransform.quaternionBetweenAxes(from: x, to: SIMD3(-1, 0, 0))
        #expect(simd_length(flip.act(x) - SIMD3<Float>(-1, 0, 0)) < 1e-4)
    }
}
