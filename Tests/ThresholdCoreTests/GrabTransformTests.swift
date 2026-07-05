import Foundation
import simd
import Testing
@testable import ThresholdCore

// The two-hand grab math, ported from the old app's GrabZoomMapping: an
// engage snapshot (hands + DISPLAYED placement) evaluated per frame into an
// ABSOLUTE RoomPlacement — 1:1 separation-ratio scaling, shortest-arc twist
// of the inter-hand axis, and a midpoint-pinned position pivot.

@Suite("Grab transform")
struct GrabTransformTests {

    private let identityQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    @Test func separationRatioScalesOneToOne() {
        // Hands 0.2 m apart at engage, pulled to 0.6 m → scale ×3, no twist,
        // midpoint unchanged.
        let grab = GrabTransform(
            left: SIMD3(-0.1, 0, 0), right: SIMD3(0.1, 0, 0),
            placement: .identity)
        let p = grab.evaluate(left: SIMD3(-0.3, 0, 0), right: SIMD3(0.3, 0, 0))
        #expect(abs(p.scale - 3) < 1e-5)
        #expect(simd_length(p.rotation.vector - identityQuat.vector) < 1e-5)
        // Placement position moves so the point under the midpoint stays put:
        // with startPosition == 0 and midpoint == 0, position stays 0.
        #expect(simd_length(p.position) < 1e-5)
    }

    @Test func midpointGroundingPinsTheGrabbedPoint() {
        // The hologram-local point under the hand midpoint at engage must map
        // to the CURRENT midpoint after any hand move/scale/twist — the old
        // app's load-bearing invariant.
        let start = RoomPlacement(
            position: SIMD3(0.3, 1.1, -0.4),
            rotation: simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 0))),
            scale: 1.8)
        let l0 = SIMD3<Float>(-0.12, 1.0, -0.5)
        let r0 = SIMD3<Float>(0.16, 1.05, -0.45)
        let grab = GrabTransform(left: l0, right: r0, placement: start)
        let grabbedLocal = start.inverseMap((l0 + r0) * 0.5)

        // Move, twist, and spread the hands arbitrarily.
        let l1 = SIMD3<Float>(-0.05, 1.3, -0.7)
        let r1 = SIMD3<Float>(0.4, 1.15, -0.35)
        let p = grab.evaluate(left: l1, right: r1)
        let pinned = p.map(grabbedLocal)
        let currentMid = (l1 + r1) * 0.5
        #expect(simd_length(pinned - currentMid) < 1e-4)
    }

    @Test func twistFollowsTheHandAxisShortestArc() {
        // Axis starts along +x; hands rotate so it points along +y (90° about
        // +z). The evaluated rotation must send the start axis to the new one.
        let grab = GrabTransform(
            left: SIMD3(-0.1, 0, 0), right: SIMD3(0.1, 0, 0),
            placement: .identity)
        let p = grab.evaluate(left: SIMD3(0, -0.1, 0), right: SIMD3(0, 0.1, 0))
        let landed = p.rotation.act(SIMD3<Float>(1, 0, 0))
        #expect(simd_length(landed - SIMD3<Float>(0, 1, 0)) < 1e-4)
    }

    @Test func rollAboutTheHandAxisIsNotARotation() {
        // Rotating the hand PAIR about its own axis leaves the axis unchanged
        // → no rotation (old app: shortest-arc between axes only, no roll).
        let grab = GrabTransform(
            left: SIMD3(-0.1, 1.0, -0.3), right: SIMD3(0.1, 1.0, -0.3),
            placement: .identity)
        // Same axis, same separation, same midpoint.
        let p = grab.evaluate(left: SIMD3(-0.1, 1.0, -0.3), right: SIMD3(0.1, 1.0, -0.3))
        #expect(simd_length(p.rotation.vector - identityQuat.vector) < 1e-5)
    }

    @Test func scaleClampKeepsThePositionPivotConsistent() {
        // When the clamp saturates, effScale must use the CLAMPED scale (old
        // clamp-then-effScale order) so the position pivot stays consistent.
        let start = RoomPlacement(position: SIMD3(1, 0, 0), rotation: .init(ix: 0, iy: 0, iz: 0, r: 1), scale: 400)
        let grab = GrabTransform(
            left: SIMD3(-0.1, 0, 0), right: SIMD3(0.1, 0, 0), placement: start)
        // ×3 separation would give scale 1200 — clamped to 500.
        let p = grab.evaluate(left: SIMD3(-0.3, 0, 0), right: SIMD3(0.3, 0, 0))
        #expect(abs(p.scale - 500) < 1e-3)
        let effScale = p.scale / start.scale  // 1.25, NOT 3
        // startMidpoint = 0 → position = mid + effScale·(startPos − 0).
        #expect(simd_length(p.position - SIMD3<Float>(effScale, 0, 0) * start.position.x) < 1e-4)
    }

    @Test func mandelbulbClampIsWider() {
        #expect(GrabTransform.mandelbulbScaleClamp.lowerBound < GrabTransform.defaultScaleClamp.lowerBound)
        #expect(GrabTransform.mandelbulbScaleClamp.upperBound > GrabTransform.defaultScaleClamp.upperBound)
    }

    @Test func degenerateStartSeparationIsFloored() {
        // Hands at (nearly) the same point: startDistance floors at 1 cm so
        // the ratio cannot explode.
        let grab = GrabTransform(
            left: SIMD3(0, 0, 0), right: SIMD3(1e-6, 0, 0), placement: .identity)
        #expect(grab.startDistance >= 0.01)
        let p = grab.evaluate(left: SIMD3(-0.05, 0, 0), right: SIMD3(0.05, 0, 0))
        #expect(p.scale <= 10.0 + 1e-4)  // 0.1 m / 0.01 m floor
    }

    @Test func quaternionBetweenAxesHandlesIdentityAndAntiparallel() {
        let x = SIMD3<Float>(1, 0, 0)
        let same = GrabTransform.quaternionBetweenAxes(from: x, to: x)
        #expect(simd_length(same.act(x) - x) < 1e-5)
        let flip = GrabTransform.quaternionBetweenAxes(from: x, to: SIMD3(-1, 0, 0))
        #expect(simd_length(flip.act(x) - SIMD3<Float>(-1, 0, 0)) < 1e-4)
    }
}

@Suite("Room placement")
struct RoomPlacementTests {

    @Test func inverseMapInvertsMap() {
        let g = RoomPlacement(
            position: SIMD3(0.4, -0.2, 1.3),
            rotation: simd_quatf(angle: 1.1, axis: simd_normalize(SIMD3(0, 1, 1))),
            scale: 2.5)
        let x = SIMD3<Float>(0.3, 0.9, -0.6)
        #expect(simd_length(g.inverseMap(g.map(x)) - x) < 1e-5)
        #expect(simd_length(g.map(g.inverseMap(x)) - x) < 1e-5)
    }

    @Test func identityIsExact() {
        let g = RoomPlacement.identity
        #expect(g.isIdentity)
        let x = SIMD3<Float>(0.1, 2.0, -3.5)
        // Bit-exact passthrough (division by 1, rotation by exact identity).
        #expect(g.inverseMap(x) == x)
        #expect(g.map(x) == x)
    }
}

@Suite("Placement dynamics")
struct PlacementDynamicsTests {

    @Test func grabWritesTargetEqualsDisplayed() {
        var dyn = PlacementDynamics()
        let new = RoomPlacement(position: SIMD3(0.5, 0, 0), rotation: .init(ix: 0, iy: 0, iz: 0, r: 1), scale: 2)
        dyn.applyGrab(new, dt: 1 / 90)
        #expect(dyn.target == dyn.displayed)
        // One-pole: moved toward new but not all the way (t ≤ 0.55).
        #expect(dyn.displayed.position.x > 0)
        #expect(dyn.displayed.position.x < 0.5)
    }

    @Test func grabConvergesToTheEvaluation() {
        var dyn = PlacementDynamics()
        let new = RoomPlacement(position: SIMD3(0.2, 0.1, -0.3), rotation: .init(ix: 0, iy: 0, iz: 0, r: 1), scale: 3)
        for _ in 0..<120 { dyn.applyGrab(new, dt: 1 / 90) }
        #expect(simd_length(dyn.displayed.position - new.position) < 1e-3)
        #expect(abs(dyn.displayed.scale - new.scale) < 1e-3)
    }

    @Test func grabSmoothingIsCadenceIndependent() {
        // Two 1/180 s steps ≈ one 1/90 s step (dt-corrected one-pole) for a
        // fixed absolute target.
        let new = RoomPlacement(position: SIMD3(0.05, 0, 0), rotation: .init(ix: 0, iy: 0, iz: 0, r: 1), scale: 1)

        var full = PlacementDynamics()
        full.applyGrab(new, dt: 1 / 90)

        var halves = PlacementDynamics()
        halves.applyGrab(new, dt: 1 / 180)
        halves.applyGrab(new, dt: 1 / 180)

        // The ramp factor differs slightly between sub-steps (motionMag
        // shrinks), so allow a loose bound — the point is the 45 Hz feel
        // stays in the same ballpark rather than halving.
        let diff = abs(full.displayed.position.x - halves.displayed.position.x)
        #expect(diff < 0.25 * abs(full.displayed.position.x))
    }

    @Test func settleGlidesToTargetWithoutOvershoot() {
        var dyn = PlacementDynamics()
        dyn.translate(by: SIMD3(0.3, 0, 0))
        var maxX: Float = 0
        for _ in 0..<400 {
            dyn.settle(dt: 1 / 90)
            maxX = max(maxX, dyn.displayed.position.x)
        }
        #expect(simd_length(dyn.displayed.position - SIMD3<Float>(0.3, 0, 0)) < 1e-3)
        #expect(maxX <= 0.3 + 1e-3)  // critically damped: no overshoot
    }

    @Test func resetEasesBackToIdentity() {
        var dyn = PlacementDynamics()
        dyn.snap(to: RoomPlacement(
            position: SIMD3(1, 2, 3),
            rotation: simd_quatf(angle: 1, axis: SIMD3(0, 1, 0)),
            scale: 5))
        dyn.reset()
        // Eased, not snapped.
        dyn.settle(dt: 1 / 90)
        #expect(!dyn.displayed.isIdentity)
        for _ in 0..<2000 { dyn.settle(dt: 1 / 90) }
        #expect(simd_length(dyn.displayed.position) < 1e-3)
        #expect(abs(dyn.displayed.scale - 1) < 1e-3)
        #expect(dyn.displayed.rotation.vector.w > 0.9999)
    }

    @Test func settleLandsExactly() {
        var dyn = PlacementDynamics()
        dyn.translate(by: SIMD3(0.01, 0, 0))
        for _ in 0..<2000 { dyn.settle(dt: 1 / 90) }
        #expect(dyn.displayed == dyn.target)
    }

    @Test func nonFiniteGrabIsRejected() {
        // A NaN evaluation (poisoned ARKit joint) must not enter the
        // one-pole — displayed stays finite so the placement can recover.
        var dyn = PlacementDynamics()
        let nan = RoomPlacement(position: SIMD3(.nan, 0, 0))
        dyn.applyGrab(nan, dt: 1 / 90)
        #expect(dyn.displayed.isFinite)
        // A subsequent good grab still tracks.
        let good = RoomPlacement(position: SIMD3(0.2, 0, 0))
        for _ in 0..<120 { dyn.applyGrab(good, dt: 1 / 90) }
        #expect(simd_length(dyn.displayed.position - good.position) < 1e-3)
    }
}
