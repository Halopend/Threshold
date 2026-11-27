// WorldGrabTests.swift — grab state machine + ingress hygiene (adversarial
// plan Phase 0). Drives the platform-neutral GrabEvent API directly; the
// visionOS SpatialEvent adapter is a thin map over the same entry point.

import Foundation
import simd
import Testing

import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

private typealias Event = WorldGrabSession.GrabEvent

/// Runs `body` with the world-grab toggle ON, restoring the prior default.
private func withGrabEnabled(_ body: (WorldGrabSession) -> Void) {
    let key = WorldGrabSession.enabledKey
    let prior = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(true, forKey: key)
    defer {
        if let prior {
            UserDefaults.standard.set(prior, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    body(WorldGrabSession())
}

// Serialized: every test flips the same UserDefaults enable key.
@Suite("WorldGrab ingress", .serialized)
struct WorldGrabIngressTests {
    @Test("Pausing holds the view, reset stays paused, and resume reanchors")
    func pauseResetResume() {
        withGrabEnabled { grab in
            let start = SIMD3<Float>(0.2, 1, -0.5)
            grab.handle([Event(phase: .active, position: start)])
            grab.handle([Event(phase: .active, position: start + SIMD3(0.1, 0, 0))])
            let held = grab.current()
            grab.setSuppressed(true)
            grab.handle([Event(phase: .active, position: start + SIMD3(0.5, 0, 0))])
            #expect(grab.current() == held)
            #expect(!grab.isGrabbing())
            grab.reset()
            grab.handle([Event(phase: .active, position: start)])
            #expect(!grab.isGrabbing())
            #expect(grab.current().isIdentity)
            grab.setSuppressed(false)
            grab.handle([Event(phase: .active, position: start)])
            #expect(grab.current().isIdentity)
            grab.handle([Event(phase: .active, position: start + SIMD3(0.1, 0, 0))])
            #expect(abs(grab.current().translation.x - 0.1) < 1e-5)
        }
    }

    @Test("A one-hand drag translates by the hand displacement")
    func dragTranslates() {
        withGrabEnabled { grab in
            let start = SIMD3<Float>(0.2, 1.0, -0.5)
            grab.handle([Event(phase: .active, position: start)])
            grab.handle([Event(phase: .active, position: start + SIMD3(0.1, 0, 0))])
            #expect(abs(grab.current().translation.x - 0.1) < 1e-5)
            grab.handle([Event(phase: .ended, position: start)])
            #expect(abs(grab.current().translation.x - 0.1) < 1e-5)  // committed
        }
    }

    @Test("Non-finite active events are dropped, not integrated")
    func nonFiniteDropped() {
        withGrabEnabled { grab in
            let start = SIMD3<Float>(0.2, 1.0, -0.5)
            grab.handle([Event(phase: .active, position: start)])
            grab.handle([Event(phase: .active, position: start + SIMD3(0.1, 0, 0))])
            let before = grab.current()

            // A NaN position mid-drag: must not move the transform, and the
            // transform must stay finite forever after.
            grab.handle([Event(phase: .active, position: SIMD3(.nan, 0, 0))])
            let after = grab.current()
            #expect(after == before)

            let rot = simd_quatf(vector: SIMD4(.nan, 0, 0, 1))
            grab.handle([Event(phase: .active, position: start, rotation: rot)])
            let t = grab.current()
            #expect(t.translation.x.isFinite && t.scale.isFinite)
            #expect(t.rotation.vector.x.isFinite)
        }
    }

    @Test("A dropped-pose frame mid-drag commits instead of teleporting")
    func droppedPoseCommits() {
        withGrabEnabled { grab in
            let start = SIMD3<Float>(0.2, 1.0, -0.5)
            grab.handle([Event(phase: .active, position: start)])
            grab.handle([Event(phase: .active, position: start + SIMD3(0.1, 0, 0))])

            // The adapter drops active events with no pose → the machine sees
            // an empty delivery (a release). The next pose re-engages relative
            // to ITS position: the committed offset never jumps by the
            // hand-to-origin distance (the old (0,0,0) fabrication bug).
            grab.handle([])
            grab.handle([Event(phase: .active, position: start + SIMD3(0.1, 0, 0))])
            grab.handle([Event(phase: .active, position: start + SIMD3(0.2, 0, 0))])
            #expect(abs(grab.current().translation.x - 0.2) < 1e-5)
        }
    }

    @Test("Two-hand scale clamps and the surviving hand stays latched")
    func twoHandScaleAndLatch() {
        withGrabEnabled { grab in
            let l = SIMD3<Float>(-0.1, 1.0, -0.5)
            let r = SIMD3<Float>(0.1, 1.0, -0.5)
            grab.handle([
                Event(phase: .active, position: l),
                Event(phase: .active, position: r),
            ])
            // Separate 0.2 m → 0.8 m: ×4 scale.
            grab.handle([
                Event(phase: .active, position: l - SIMD3(0.3, 0, 0)),
                Event(phase: .active, position: r + SIMD3(0.3, 0, 0)),
            ])
            #expect(abs(grab.current().scale - 4) < 1e-4)

            // One hand releases: the survivor must NOT translate (BorgVR
            // doubleEventIsRunning latch) until full release.
            grab.handle([Event(phase: .active, position: r + SIMD3(0.3, 0, 0))])
            let latched = grab.current()
            grab.handle([Event(phase: .active, position: r + SIMD3(0.6, 0, 0))])
            #expect(grab.current() == latched)

            // Full release clears the latch; a fresh pinch drags again.
            grab.handle([])
            grab.handle([Event(phase: .active, position: r)])
            grab.handle([Event(phase: .active, position: r + SIMD3(0.1, 0, 0))])
            #expect(abs(grab.current().translation.x - latched.translation.x - 0.1) < 1e-4)
        }
    }

    @Test("Toggle off mid-flight resets to identity (escape hatch)")
    func toggleOffResets() {
        let key = WorldGrabSession.enabledKey
        let prior = UserDefaults.standard.object(forKey: key)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let grab = WorldGrabSession()
        UserDefaults.standard.set(true, forKey: key)
        let start = SIMD3<Float>(0.2, 1.0, -0.5)
        grab.handle([Event(phase: .active, position: start)])
        grab.handle([Event(phase: .active, position: start + SIMD3(0.1, 0, 0))])
        #expect(!grab.current().isIdentity)

        UserDefaults.standard.set(false, forKey: key)
        grab.handle([Event(phase: .active, position: start)])
        #expect(grab.current().isIdentity)
    }
}

// MARK: - Render wiring (the grab must actually reach the view math)

@Suite("WorldGrab view folding")
struct WorldGrabViewFoldingTests {
    private var base: ThreshFrameUniforms {
        var u = ThreshFrameUniforms()
        u.camPosFov = SIMD4(0.5, -1, 3, 0.5)
        u.camQuat = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3(0.2, 1, 0.1))).vector
        return u
    }

    private let grab = WorldGrabTransform(
        scale: 2.5,
        rotation: simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3(1, 0.4, -0.3))),
        translation: SIMD3(0.3, -0.2, 0.8))
    private let anchor = SIMD3<Float>(0.1, 1.6, -0.2)
    private let projection = CompositorViewMath.pinholeProjection(fovTan: 0.5, aspect: 1)

    /// Inverse content transform G⁻¹(p) = (1/s)·R⁻¹(p − t).
    private func uncontent(_ p: SIMD3<Float>) -> SIMD3<Float> {
        grab.rotation.inverse.act(p - grab.translation) / grab.scale
    }

    private func eye(at p: SIMD3<Float>, rotation: simd_quatf) -> simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4(p, 1)
        return m
    }

    @Test("An eye in grabbed space sees what the un-grabbed eye saw at G⁻¹(p)")
    func eyeOriginMatchesContentTransform() {
        let room = SIMD3<Float>(0.4, 1.5, -0.9)
        let eyeRot = simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0))
        let grabbed = CompositorViewMath.viewUniforms(
            projection: projection, eyeToRoom: eye(at: room, rotation: eyeRot),
            anchorPosition: anchor, base: base, grab: grab)
        let want = CompositorViewMath.fractalPoint(
            room: uncontent(room), base: base, anchorPosition: anchor)
        let got = SIMD3(grabbed.originScale.x, grabbed.originScale.y, grabbed.originScale.z)
        #expect(simd_length(got - want) < 1e-4, Comment(rawValue: "got \(got), want \(want)"))
        #expect(abs(grabbed.originScale.w - 1 / grab.scale) < 1e-6,
                "content scaled up ⇒ fewer fractal units per room meter")
        let wantOrient = simd_normalize(
            simd_quatf(vector: base.camQuat) * grab.rotation.inverse * eyeRot)
        #expect(abs(abs(simd_dot(grabbed.orient, wantOrient.vector)) - 1) < 1e-5,
                "observer turns by R⁻¹ when content turns by R")
    }

    @Test("Content stays put in the room: two eye positions agree on a grabbed point")
    func grabbedContentIsRoomStable() {
        // The fractal point at room q (via the map) must equal the un-grabbed
        // point at G⁻¹(q) — independent of where the eye stands.
        let q = SIMD3<Float>(-0.3, 1.1, -1.4)
        let viaHands = HandOpStamper.stamp(
            [{
                var op = ThreshWarpOp()
                op.kind = UInt32(ThreshWarpKindHandAttract.rawValue)
                op.flags = WarpFlags.driveRightHand.rawValue
                op.strength = 1
                op.a = SIMD4(0, 0, 0, 0.1)
                return op
            }()],
            right: HandOpStamper.Hand(palm: q), left: .untracked,
            base: base, anchorPosition: anchor, grab: grab)[0].a
        let want = CompositorViewMath.fractalPoint(
            room: uncontent(q), base: base, anchorPosition: anchor)
        #expect(simd_length(SIMD3(viaHands.x, viaHands.y, viaHands.z) - want) < 1e-4,
                "hand effects stay under the hand in a grabbed world")
        #expect(viaHands.w == 0.1, "authored radius survives")
    }

    @Test("Identity grab leaves view uniforms bit-identical")
    func identityIsBitIdentical() {
        let e = eye(at: SIMD3(0.2, 1.7, -0.4), rotation: simd_quatf(angle: 1.1, axis: SIMD3(0, 1, 0)))
        let plain = CompositorViewMath.viewUniforms(
            projection: projection, eyeToRoom: e, anchorPosition: anchor, base: base)
        let grabbed = CompositorViewMath.viewUniforms(
            projection: projection, eyeToRoom: e, anchorPosition: anchor, base: base,
            grab: .identity)
        #expect(plain.originScale == grabbed.originScale)
        #expect(plain.orient == grabbed.orient)
    }
}
