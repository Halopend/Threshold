// WorldGrabTests.swift — grab state machine + ingress hygiene (adversarial
// plan Phase 0). Drives the platform-neutral GrabEvent API directly; the
// visionOS SpatialEvent adapter is a thin map over the same entry point.

import Foundation
import simd
import Testing

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
