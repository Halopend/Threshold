// HandTracker.swift — visionOS hand input (plan §8): an ARKit
// HandTrackingProvider whose per-frame poll publishes the hand.* signal
// namespace AND drives the camera rig from two hardwired gestures, ported from
// the old app's GestureController (which "worked relatively well"):
//
//   • RIGHT-HAND index↔thumb pinch + drag → TRANSLATE (move the camera in XYZ,
//     following the hand). Old app: `.core(.translate)`.
//   • TWO-HAND index↔thumb pinch → GRAB: hand-separation ratio scales, and the
//     two-hand axis twist rotates, the environment 1:1 (GrabTransform, the port
//     of GrabZoomMapping). Midpoint travel pans to keep the grab grounded.
//
// UNIT MODEL (the part the first attempt at this got wrong): the old app is a
// "hologram in the room" — real ARKit head tracking IS the camera, untouched
// by gestures; gestures move the FRACTAL's own position/rotation/scale
// directly (RendererGameState's modelMatrix), so hand-meters and the object's
// placement share one coordinate frame and "grab two points, bring them
// together" is trivially 1:1. This engine is camera-centric instead (fractal
// fixed at the world origin, `scale.zoom`/`modelScale` controls how much
// detail a unit of world-space distance covers), so the SAME feel requires:
//   • Rotation + translation invert cleanly onto the camera (moving the
//     object by +D under a fixed camera ≡ moving the camera by −D under a
//     fixed object) — these drive `camera.twist` / `camera.pan`.
//   • Scale does NOT invert onto any camera-position lever — a camera-distance
//     "dolly" is a perspective illusion, not a change in how much fractal
//     detail is visible (RaymarchCore.metal: `ro`/`camPosFov` and `modelScale`
//     are independent terms). Scale must drive `scale.zoom` directly, via its
//     rate (`scale.zoomSpeed`) — see `publishZoomRate` below.
//   • Hand-meters must be converted to world-units by the CURRENT zoom depth
//     (`× exp2(zoomOctaves)`) before combining with camera position, or a
//     real hand movement becomes imperceptible when zoomed in and wildly
//     oversized when zoomed out — this is why `snapshots` is threaded in.
//
// Two outputs, two channels (Invariant 13/14):
//   • SIGNALS: pinch strength + joint positions per hand (session-clock
//     stamped) so music-style bindings can map hands onto any bindable param.
//   • GESTURE LANE: the camera writes above, plus the (currently unbound)
//     assignable drive layer (tapThumb/tapPalm/fist/swipe → GestureLaneResolver)
//     that the Gestures editor targets.
//
// `update(sessionTime:)` is called by the CompositorSession render loop via its
// `onFrame` hook — the tracker is render-thread confined after `start()`.

#if os(visionOS)

import ARKit
import Foundation
import os
import simd
import ThresholdCore
import ThresholdRender

public final class HandTracker: @unchecked Sendable {
    // MARK: Tuning (ported from the old app's GestureDefaults)

    /// Two-hand pinch engage / release strengths (hysteresis).
    static let grabActivate: Float = 0.7
    static let grabRelease: Float = 0.3
    /// Single-hand translate pinch engage / release.
    static let translateActivate: Float = 0.7
    static let translateRelease: Float = 0.3
    /// Hand-separation guards for the two-hand grab (meters).
    static let maxStartHandDistance: Float = 0.35
    static let maxActiveHandDistance: Float = 0.75
    /// Frames the left hand must be continuously tracked before a two-hand grab
    /// can START (≈0.33 s at 90 Hz) — kills false triggers as it enters the FOV.
    static let leftStabilityFrames = 30
    /// Grab-end lockout (frames) so the release doesn't immediately start a
    /// single-hand translate (≈0.15 s at 90 Hz).
    static let grabEndCooldownFrames = 14
    /// Translate: hand delta is amplified ×3 and capped at 0.30 m/frame (old app).
    static let translateMultiplier: Float = 3.0
    static let translateMaxStep: Float = 0.30

    /// Pinch strength (0…1) at/above which a tapThumb drag is engaged
    /// (assignable layer).
    static let tapThumbEngage: Float = 0.6
    /// Finger travel (m) that maps to a full ±1 normalized drive. ~15 cm.
    static let dragMetersToUnit: Float = 1.0 / 0.15
    /// Hand speed (m/s) that maps to a full ±1 swipe drive.
    static let swipeMetersPerSecToUnit: Float = 1.0 / 1.5

    // MARK: Wiring

    private let signals: SignalTable
    private let mailbox: LaneMailbox
    private let layout: CatalogLayout
    /// Read each frame for the live `scale.zoom` value — the hand-meters →
    /// world-units conversion needs the CURRENT zoom depth, not a cached one
    /// (see the file-header unit-model note).
    private let snapshots: SnapshotSlot
    /// float3 base slots (the param occupies slot, slot+1, slot+2).
    private let panSlot: Int?
    private let twistSlot: Int?
    private let zoomSlot: Int?
    private let zoomSpeedSlot: Int?

    // MARK: Binding-driven detection (the assignable gesture layer)

    private let bindings = OSAllocatedUnfairLock<GestureBindingTable>(initialState: .init())
    private var frameDrives: [GestureSource: GestureDrive] = [:]
    private var frameTable = GestureBindingTable()
    private var committedDrag: [GestureSource: SIMD3<Float>] = [:]
    private var dragEngage: [GestureSource: SIMD3<Float>] = [:]
    private var lastWrist: [Bool: SIMD3<Float>] = [:]
    private var lastWristTime: [Bool: Double] = [:]
    /// Momentary sources (palm/fist/swipe) that produced a drive last frame; a
    /// source that stops being detected is actively released to base (the
    /// mailbox is latest-value-wins and never auto-zeroes). tapThumb is excluded
    /// (its committedDrag persists so a set value holds).
    private var lastMomentary: Set<GestureSource> = []

    private let arSession = ARKitSession()
    private let provider = HandTrackingProvider()

    // MARK: Camera state (render-thread confined after start)

    /// Per-hand pose captured this frame, for the two-hand grab + translate.
    private struct HandFrame {
        var isTracked = false
        var palm: SIMD3<Float>?
        /// index↔thumb pinch strength (0…1).
        var indexPinch: Float = 0
        /// Pinch point (thumb–index midpoint) and whether it's valid.
        var pinchPos: SIMD3<Float> = .zero
        var pinchPosValid = false
        static let untracked = HandFrame()
    }
    private var handFrames: [Bool: HandFrame] = [:]

    /// The cumulative gesture-driven "object placement" — grab and translate
    /// BOTH update this, exactly mirroring the old app's `settings.position`/
    /// `worldRotation` (a real hand-meters, room-space quantity that persists
    /// indefinitely across gestures). Starts at zero/identity: no offset from
    /// the authored view. Published each frame as the INVERSE onto
    /// `camera.pan`/`camera.twist` (see `publishObjectPlacement`) — the fractal
    /// is fixed at the world origin in this engine, so "the object moved by
    /// (objPositionMeters, objRotation)" is achieved by moving the camera
    /// oppositely (file-header unit-model note).
    private var objPositionMeters: SIMD3<Float> = .zero
    private var objRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // Two-hand grab.
    private var grabbing = false
    private var grab: GrabTransform?
    private var grabStartObjPositionMeters: SIMD3<Float> = .zero
    private var grabStartObjRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var grabStartMidpointMeters: SIMD3<Float> = .zero
    /// The total `scale.zoom` octave delta the dead-beat controller (below)
    /// has actually driven the integrator through since this grab engaged —
    /// tracked separately from `objPositionMeters`'s scale term so the
    /// zoomSpeed rate injection can be computed independently of position.
    private var appliedOctavesSinceEngage: Float = 0
    private var grabCooldown = 0
    private var leftStableFrames = 0

    // Right-hand translate.
    private var translating = false
    private var translatePrevPalm: SIMD3<Float>?

    /// Session-clock time of the previous `update()` call — for the dead-beat
    /// zoomSpeed controller's `dt` (distinct from the per-hand swipe-velocity
    /// timestamps, which are keyed per-hand and reset on tracking loss).
    private var lastUpdateTime: Double?

    public init(
        layout: CatalogLayout, mailbox: LaneMailbox, signals: SignalTable,
        snapshots: SnapshotSlot
    ) {
        self.signals = signals
        self.mailbox = mailbox
        self.layout = layout
        self.snapshots = snapshots
        self.panSlot = layout.slot(for: .cameraPan)
        self.twistSlot = layout.slot(for: .cameraTwist)
        self.zoomSlot = layout.slot(for: .scaleZoom)
        self.zoomSpeedSlot = layout.slot(for: .scaleZoomSpeed)
    }

    /// The live `scale.zoom` value (octaves) from the most recently resolved
    /// frame — 0 (no zoom) until the first snapshot lands. One frame stale at
    /// most (a read for unit conversion, not a write-path value), which is
    /// imperceptible.
    private var currentZoomOctaves: Float {
        zoomSlot.flatMap { snapshots.latest?.resolved.values[$0] } ?? 0
    }

    /// Install the active fractal's gesture bindings (call on fractal switch and
    /// whenever the user edits a binding). Thread-safe.
    public func setBindings(_ table: GestureBindingTable) {
        bindings.withLock { $0 = table }
    }

    /// Request authorization + start the provider. Hand tracking denied is
    /// non-fatal: signals stay unpublished and the gesture lane stays quiet.
    public func start() {
        Task { [arSession, provider] in
            do {
                try await arSession.run([provider])
            } catch {
                print("hand tracking unavailable: \(error)")
            }
        }
    }

    public func stop() {
        arSession.stop()
    }

    /// Per-frame poll: publish hand signals and gesture-lane writes.
    public func update(sessionTime: Double) {
        let anchors = provider.latestAnchors
        frameTable = bindings.withLock { $0 }
        frameDrives.removeAll(keepingCapacity: true)
        handFrames.removeAll(keepingCapacity: true)

        updateHand(
            anchors.leftHand, isRight: false, time: sessionTime,
            pinchSignal: .handLeftPinch, positionSignal: .handLeftPosition,
            palmSignal: .handLeftPalm, forearmSignal: .handLeftForearm)
        updateHand(
            anchors.rightHand, isRight: true, time: sessionTime,
            pinchSignal: .handRightPinch, positionSignal: .handRightPosition,
            palmSignal: .handRightPalm, forearmSignal: .handRightForearm)

        // Release momentary sources (palm/fist/swipe) dropped this frame.
        let detectedMomentary = Set(frameDrives.keys.filter(Self.isMomentary))
        for source in lastMomentary where !detectedMomentary.contains(source) {
            frameDrives[source] = source.arity == .scalar ? .scalar(0) : .vector(.zero)
        }
        lastMomentary = detectedMomentary

        // Assignable layer (currently unbound by default → no writes).
        for write in GestureLaneResolver.resolve(
            drives: frameDrives, table: frameTable, layout: layout) {
            mailbox.publish(write)
        }

        // Hardwired camera gestures: two-hand grab + right-hand translate.
        let dt = lastUpdateTime.map { max(0, sessionTime - $0) } ?? 0
        lastUpdateTime = sessionTime
        updateCameraGestures(dt: dt)
    }

    private static func isMomentary(_ source: GestureSource) -> Bool {
        switch source {
        case .tapPalm, .fist, .swipe: return true
        case .tapThumb: return false
        }
    }

    // MARK: Per-hand (signals + assignable drives + HandFrame capture)

    private func updateHand(
        _ anchor: HandAnchor?, isRight: Bool, time: Double,
        pinchSignal: SignalID, positionSignal: SignalID,
        palmSignal: SignalID, forearmSignal: SignalID
    ) {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else {
            handFrames[isRight] = .untracked
            return
        }

        let originFromAnchor = anchor.originFromAnchorTransform
        func worldJoint(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            let m = originFromAnchor * joint.anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        let wrist = SIMD3(
            originFromAnchor.columns.3.x,
            originFromAnchor.columns.3.y,
            originFromAnchor.columns.3.z)
        signals.publish(id: positionSignal, value: SIMD4(wrist, 0), confidence: 1, timestamp: time)
        let palmCenter = worldJoint(.middleFingerMetacarpal)
        if let palmCenter {
            signals.publish(id: palmSignal, value: SIMD4(palmCenter, 0), confidence: 1, timestamp: time)
        }
        if let forearm = worldJoint(.forearmArm) {
            signals.publish(id: forearmSignal, value: SIMD4(forearm, 0), confidence: 1, timestamp: time)
        }

        // Base HandFrame (pinch filled below if the tips resolve).
        var frame = HandFrame(isTracked: true, palm: palmCenter)

        guard let thumb = worldJoint(.thumbTip),
              let index = worldJoint(.indexFingerTip) else {
            handFrames[isRight] = frame
            return
        }
        let indexPinch = HandGeometry.pinchStrength(thumb: thumb, finger: index)
        frame.indexPinch = indexPinch
        frame.pinchPos = (thumb + index) * 0.5
        frame.pinchPosValid = true
        handFrames[isRight] = frame

        // Pinch signal (continuous, bindable): 1 at touching, ~0 by 6 cm.
        let gap = simd_distance(thumb, index)
        let strength = max(0, min(1, 1 - (gap - 0.015) / 0.045))
        signals.publish(id: pinchSignal, value: SIMD4(strength, 0, 0, 0), confidence: 1, timestamp: time)

        // ── Assignable gesture drives (fed to GestureLaneResolver) ──────────
        let handEnum: GestureHand = isRight ? .right : .left
        let fingerJoints: [(GestureFinger, HandSkeleton.JointName)] = [
            (.index, .indexFingerTip), (.middle, .middleFingerTip),
            (.ring, .ringFingerTip), (.pinky, .littleFingerTip),
        ]
        var fingertips: [SIMD3<Float>] = []
        for (finger, jointName) in fingerJoints {
            guard let tip = worldJoint(jointName) else { continue }
            fingertips.append(tip)
            let src = GestureSource.tapThumb(hand: handEnum, finger: finger)
            let pinch = HandGeometry.pinchStrength(thumb: thumb, finger: tip)
            if pinch >= Self.tapThumbEngage {
                if dragEngage[src] == nil { dragEngage[src] = tip }
                let delta = (tip - dragEngage[src]!) * Self.dragMetersToUnit
                frameDrives[src] = .vector((committedDrag[src] ?? .zero) + delta)
            } else {
                if let engage = dragEngage[src] {
                    committedDrag[src, default: .zero] += (tip - engage) * Self.dragMetersToUnit
                    dragEngage[src] = nil
                }
                frameDrives[src] = .vector(committedDrag[src] ?? .zero)
            }
            if let palmCenter {
                let th = HandGeometry.palmThresholds(for: finger)
                frameDrives[.tapPalm(hand: handEnum, finger: finger)] =
                    .scalar(HandGeometry.palmTouchStrength(
                        fingerTip: tip, palm: palmCenter, touch: th.touch, away: th.away))
            }
        }
        if let palmCenter, fingertips.count == 4 {
            frameDrives[.fist(hand: handEnum)] =
                .scalar(HandGeometry.fistClosure(fingerTips: fingertips, palm: palmCenter))
        }
        if let last = lastWrist[isRight], let lastT = lastWristTime[isRight], time > lastT {
            let velocity = (wrist - last) / Float(time - lastT)
            frameDrives[.swipe(hand: handEnum)] = .vector(velocity * Self.swipeMetersPerSecToUnit)
        }
        lastWrist[isRight] = wrist
        lastWristTime[isRight] = time
    }

    // MARK: Hardwired camera gestures

    private func updateCameraGestures(dt: Double) {
        let left = handFrames[false] ?? .untracked
        let right = handFrames[true] ?? .untracked

        // Left-hand stability gate + grab-end cooldown.
        leftStableFrames = left.isTracked
            ? min(leftStableFrames + 1, Self.leftStabilityFrames + 1) : 0
        if grabCooldown > 0 { grabCooldown -= 1 }

        let bothValid = left.isTracked && right.isTracked
            && left.pinchPosValid && right.pinchPosValid
        let separation = simd_distance(left.pinchPos, right.pinchPos)

        // ── TWO-HAND GRAB ───────────────────────────────────────────────────
        // Ported verbatim from the old app's GrabZoomMapping (GrabTransform is
        // its pure math). The old app applied this DIRECTLY to the fractal's
        // own position/rotation/scale (a "hologram in the room" — real head
        // tracking is the camera, untouched by gestures). This engine is
        // camera-centric instead, so `objPositionMeters`/`objRotation` play
        // the SAME "object placement" role, updated with the SAME formula,
        // and are published INVERTED onto camera.pan/camera.twist
        // (`publishObjectPlacement`) — see the file header for why.
        var zoomRate: Float = 0
        if grabbing {
            let held = bothValid
                && left.indexPinch >= Self.grabRelease
                && right.indexPinch >= Self.grabRelease
                && separation <= Self.maxActiveHandDistance
            if held, let grab {
                let d = grab.evaluate(left: left.pinchPos, right: right.pinchPos)
                let effScale = max(d.scaleRatio, 1e-6)
                let currentMidpointMeters = (left.pinchPos + right.pinchPos) * 0.5
                objRotation = (d.rotation * grabStartObjRotation).normalized
                objPositionMeters = currentMidpointMeters
                    + d.rotation.act(effScale * (grabStartObjPositionMeters - grabStartMidpointMeters))
                publishObjectPlacement()

                // Scale drives scale.zoom's RATE (not any camera-distance
                // lever — see file header): a dead-beat controller publishes
                // exactly the rate needed this frame so the integrator lands
                // on log2(effScale) (relative to grab engage) with zero lag.
                let targetOctavesSinceEngage = log2(effScale)
                if dt > 0 {
                    let neededDelta = targetOctavesSinceEngage - appliedOctavesSinceEngage
                    zoomRate = Float(Double(neededDelta) / dt)
                    appliedOctavesSinceEngage += zoomRate * Float(dt)
                }
            } else {
                grabbing = false
                grab = nil
                grabCooldown = Self.grabEndCooldownFrames
            }
        } else if leftStableFrames >= Self.leftStabilityFrames && bothValid
            && left.indexPinch >= Self.grabActivate
            && right.indexPinch >= Self.grabActivate
            && separation <= Self.maxStartHandDistance {
            grabbing = true
            grab = GrabTransform(left: left.pinchPos, right: right.pinchPos)
            grabStartObjPositionMeters = objPositionMeters
            grabStartObjRotation = objRotation
            grabStartMidpointMeters = (left.pinchPos + right.pinchPos) * 0.5
            appliedOctavesSinceEngage = 0
        }
        // Every non-grabbing frame publishes rate 0 explicitly — the gesture
        // lane never auto-zeroes a stale write, so a rate left at its last
        // nonzero value would drift the zoom forever after release.
        publishZoomRate(zoomRate)

        // ── RIGHT-HAND INDEX-PINCH TRANSLATE ────────────────────────────────
        // Suppressed while grabbing (both hands) or during the grab-end lockout.
        guard !grabbing, grabCooldown == 0 else {
            translating = false
            translatePrevPalm = nil
            return
        }
        let point = right.palm ?? (right.pinchPosValid ? right.pinchPos : nil)
        if translating {
            if right.isTracked, right.indexPinch >= Self.translateRelease, let point {
                if let prev = translatePrevPalm {
                    let raw = point - prev
                    let len = simd_length(raw)
                    if len > 0 {
                        // Amplify ×3, cap the per-frame step (old app translate).
                        // A plain room-space delta, matching old app's
                        // `settings.targetPosition += inputDelta` — NOT
                        // rotated by objRotation (translate moves the object
                        // in room space regardless of its current twist).
                        let scaled = raw / len * min(len * Self.translateMultiplier, Self.translateMaxStep)
                        objPositionMeters += scaled
                        publishObjectPlacement()
                    }
                }
                translatePrevPalm = point
            } else {
                translating = false
                translatePrevPalm = nil
            }
        } else if right.isTracked, right.indexPinch >= Self.translateActivate, let point {
            translating = true
            translatePrevPalm = point
        }
    }

    // MARK: Publishing

    /// Publish the current `objPositionMeters`/`objRotation` (the cumulative
    /// gesture-driven object placement, in real hand-meters) onto
    /// `camera.pan`/`camera.twist`, INVERTED (moving the object by (P,R) ≡
    /// moving the camera by (P,R)⁻¹, since the fractal is fixed at the world
    /// origin) and converted from hand-meters to world-units by the CURRENT
    /// zoom depth (`× exp2(zoomOctaves)` — see file header). Composition
    /// order matches `CameraRig.pose`: rotate the orbited position by
    /// `invRot`, THEN add pan — so `pan` here must already be
    /// `-invRot.act(objPositionMeters)`, not the raw meters value.
    private func publishObjectPlacement() {
        let invRot = objRotation.inverse
        let worldUnitsPerMeter = exp2(currentZoomOctaves)
        let panWorldUnits = -invRot.act(objPositionMeters) * worldUnitsPerMeter

        if let s = panSlot {
            mailbox.publish(LaneWrite(lane: .gesture, slot: s, value: panWorldUnits.x))
            mailbox.publish(LaneWrite(lane: .gesture, slot: s + 1, value: panWorldUnits.y))
            mailbox.publish(LaneWrite(lane: .gesture, slot: s + 2, value: panWorldUnits.z))
        }
        if let s = twistSlot {
            let rv = Self.rotationVector(invRot)
            mailbox.publish(LaneWrite(lane: .gesture, slot: s, value: rv.x))
            mailbox.publish(LaneWrite(lane: .gesture, slot: s + 1, value: rv.y))
            mailbox.publish(LaneWrite(lane: .gesture, slot: s + 2, value: rv.z))
        }
    }

    private func publishZoomRate(_ rate: Float) {
        guard let s = zoomSpeedSlot else { return }
        mailbox.publish(LaneWrite(lane: .gesture, slot: s, value: rate))
    }

    /// A unit quaternion → rotation-vector (axis · angle), shortest arc. Matches
    /// `CameraRig`'s `camera.twist` interpretation.
    private static func rotationVector(_ q: simd_quatf) -> SIMD3<Float> {
        var v = q.vector
        if v.w < 0 { v = -v }                       // shorter arc
        let w = max(-1, min(1, v.w))
        let angle = 2 * acos(w)
        let s = (1 - w * w).squareRoot()
        if !angle.isFinite || s < 1e-6 { return .zero }
        return SIMD3(v.x, v.y, v.z) / s * angle
    }
}

#endif  // os(visionOS)
