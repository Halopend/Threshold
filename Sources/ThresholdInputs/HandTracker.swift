// HandTracker.swift — visionOS hand input (plan §8): an ARKit
// HandTrackingProvider whose per-frame poll publishes the hand.* signal
// namespace AND drives the gesture RoomPlacement from two hardwired
// gestures, ported from the old app's GestureController:
//
//   • TWO-HAND index↔thumb pinch → GRAB: the engage snapshot (GrabTransform)
//     is evaluated each frame into an ABSOLUTE placement — 1:1 separation
//     scaling, shortest-arc twist, midpoint-pinned position — and applied
//     through the old adaptive one-pole (PlacementDynamics.applyGrab).
//   • RIGHT-HAND index↔thumb pinch + drag → TRANSLATE: room-space palm
//     deltas (×3, capped 0.30 m/step, zoom-compensated) accumulate into the
//     placement target; a 0.35 s critically-damped spring glides after it.
//
// UNIT MODEL (the fix for the first two attempts at this): the old app is a
// "hologram in the room" — real ARKit head tracking IS the camera, untouched
// by gestures; gestures move the FRACTAL's own placement, so hand-meters and
// the object's placement share one coordinate frame and "grab two points,
// bring them together" is trivially 1:1. This engine reproduces that model
// EXACTLY with RoomPlacement (G): gestures write G in room meters, and the
// renderer maps every room-space viewer (eyes, hand-op geometry) through G⁻¹
// ahead of the room→fractal map (CompositorViewMath.viewUniforms), which is
// equivalent to moving the hologram by G. NO unit conversion happens here —
// no exp2(zoom) factors, no camera-lane inversion, no zoom-rate controller;
// those were the jump machines this file used to be.
//
// Two outputs, two channels (Invariant 13/14):
//   • SIGNALS: pinch strength + joint positions per hand (session-clock
//     stamped) so music-style bindings can map hands onto any bindable param.
//   • GESTURE LANE: the (currently unbound) assignable drive layer
//     (tapThumb/tapPalm/fist/swipe → GestureLaneResolver) that the Gestures
//     editor targets. The camera placement does NOT ride lanes — it flows to
//     the renderer through CompositorSession.placement (same render thread,
//     same frame).
//
// `update(sessionTime:)` is called by the CompositorSession render loop via
// its `onFrame` hook — the tracker is render-thread confined after `start()`.
// Cross-thread control (bindings, per-fractal tuning, scene-apply reset, UI
// suppression) lands through one lock and is consumed at the top of update().

#if os(visionOS)

import ARKit
import Foundation
import os
import simd
import ThresholdCore

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
    /// Seconds the left hand must be continuously tracked before a two-hand
    /// grab can START (old app: 30 frames @90 Hz) — kills false triggers as
    /// it enters the FOV. Seconds-based so half-rate rendering (45 Hz
    /// onFrame) doesn't double the wait.
    static let leftStabilitySeconds: Double = 30.0 / 90.0
    /// Grab-end lockout so the release doesn't immediately start a
    /// single-hand translate (old app: 0.15 s).
    static let grabEndCooldownSeconds: Double = 0.15
    /// Translate: hand delta is amplified ×3 and capped at 0.30 m/step, then
    /// scaled by sensitivity × zoom compensation (old app order).
    static let translateMultiplier: Float = 3.0
    static let translateMaxStep: Float = 0.30
    static let translationSensitivity: Float = 1.0
    /// Translate activation requires the index pinch to lead the other
    /// fingers by this margin (anatomical-coupling guard, old app).
    static let translateLeadGap: Float = 0.15
    /// A left-hand pinch at/above this while the right activates reads as a
    /// two-hand grab attempt — translate activation is blocked (old app's
    /// other-hand guard, which kept grab starts from stealing a translate).
    static let otherHandPinchGuard: Float = 0.55

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

    // MARK: Cross-thread control (written by the app, consumed per frame)

    /// Per-fractal grab tuning (old FractalTypeDescriptor overrides).
    struct GrabTuning: Sendable {
        var scaleClamp: ClosedRange<Float> = GrabTransform.defaultScaleClamp
        /// Upper clamp of the translate zoom compensation (mandelbulb 1.5).
        var maxZoomComp: Float = 2.0
    }

    private struct Control: Sendable {
        var bindings = GestureBindingTable()
        var tuning = GrabTuning()
        var pendingReset = false
        /// True while the user is interacting with a control window — all
        /// placement gestures are suppressed (old app's
        /// suppressParameterGestures; without it every window pinch-drag
        /// also drags the hologram in mixed immersion).
        var uiSuppressed = false
    }
    private let control = OSAllocatedUnfairLock<Control>(initialState: .init())

    // MARK: Binding-driven detection (the assignable gesture layer)

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

    // MARK: Placement state (render-thread confined after start)

    /// Per-hand pose captured this frame, for the two-hand grab + translate.
    private struct HandFrame {
        var isTracked = false
        var palm: SIMD3<Float>?
        /// index↔thumb pinch strength (0…1).
        var indexPinch: Float = 0
        /// Other-finger pinches for the translate lead-gap guard.
        var middlePinch: Float = 0
        var ringPinch: Float = 0
        /// Pinch point (thumb–index midpoint) and whether it's valid.
        var pinchPos: SIMD3<Float> = .zero
        var pinchPosValid = false
        static let untracked = HandFrame()
    }
    private var handFrames: [Bool: HandFrame] = [:]

    /// The gesture placement (target + displayed with the old app's two
    /// smoothing regimes). Displayed is what CompositorSession renders.
    private var placementDynamics = PlacementDynamics()
    /// Tuning copied from `control` at the top of update().
    private var frameTuning = GrabTuning()

    // Two-hand grab.
    private var grab: GrabTransform?
    private var grabCooldown: Double = 0
    private var leftStableTime: Double = 0

    // Right-hand translate.
    private enum TranslatePoint { case palm, pinch }
    private var translating = false
    private var translatePrev: SIMD3<Float>?
    private var translatePrevSource: TranslatePoint?

    /// Session-clock time of the previous `update()` call.
    private var lastUpdateTime: Double?

    public init(layout: CatalogLayout, mailbox: LaneMailbox, signals: SignalTable) {
        self.signals = signals
        self.mailbox = mailbox
        self.layout = layout
    }

    // MARK: Public control surface (thread-safe)

    /// Install the active fractal's gesture bindings (call on fractal switch
    /// and whenever the user edits a binding).
    public func setBindings(_ table: GestureBindingTable) {
        control.withLock { $0.bindings = table }
    }

    /// Install the active fractal's grab tuning (old app per-fractal
    /// overrides: the mandelbulb family gets a wider scale clamp and a
    /// tighter translate zoom-comp ceiling).
    public func setFractal(deKey: String) {
        let isMandelbulb = deKey.lowercased().contains("mandelbulb")
        let tuning = GrabTuning(
            scaleClamp: isMandelbulb
                ? GrabTransform.mandelbulbScaleClamp
                : GrabTransform.defaultScaleClamp,
            maxZoomComp: isMandelbulb ? 1.5 : 2.0)
        control.withLock { $0.tuning = tuning }
    }

    /// Ease the placement back to the authored view. Called on scene apply
    /// (the old app re-anchored placement on every preset load) and from a
    /// future reset control. Consumed on the render thread next frame.
    public func requestPlacementReset() {
        control.withLock { $0.pendingReset = true }
    }

    /// Suppress placement gestures while the user works a control window
    /// (old app: suppressParameterGestures). Active gestures end immediately
    /// (no cooldown — the old app's suppression exit path).
    public func setUISuppressed(_ suppressed: Bool) {
        control.withLock { $0.uiSuppressed = suppressed }
    }

    /// The placement to render this frame. Render-thread only (the
    /// CompositorSession.placement hook, called right after update()).
    public func currentPlacement() -> RoomPlacement {
        placementDynamics.displayed
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

    // MARK: Per-frame update (render thread)

    /// Per-frame poll: publish hand signals, assignable gesture-lane writes,
    /// and step the placement gestures.
    public func update(sessionTime: Double) {
        let anchors = provider.latestAnchors
        let controlState = control.withLock { state -> Control in
            let copy = state
            state.pendingReset = false
            return copy
        }
        frameTable = controlState.bindings
        frameTuning = controlState.tuning
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

        // Placement gestures: two-hand grab + right-hand translate.
        let dt = lastUpdateTime.map { max(0, sessionTime - $0) } ?? 0
        lastUpdateTime = sessionTime

        if controlState.pendingReset {
            endGrab(cooldown: false)
            endTranslate()
            placementDynamics.reset()
        }
        if controlState.uiSuppressed {
            // Old app quirk: suppression kills gestures with NO cooldown.
            endGrab(cooldown: false)
            endTranslate()
        } else {
            updatePlacementGestures(dt: dt)
        }
        // Glide displayed → target (translate spring / reset easing). A
        // no-op during a grab: applyGrab keeps target == displayed.
        placementDynamics.settle(dt: Float(dt))
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
            let p = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            // ARKit can emit a NaN/Inf joint transform while still flagging
            // isTracked (tracking-quality drops, rapid motion, low light).
            // Route a non-finite joint through the untracked path — a single
            // NaN reaching the placement poisons it permanently (the settle
            // landing test never re-arms against NaN).
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
            return p
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
            let pinch = HandGeometry.pinchStrength(thumb: thumb, finger: tip)
            // Feed the translate lead-gap guard (old app digits 2/3).
            if finger == .middle { frame.middlePinch = pinch }
            if finger == .ring { frame.ringPinch = pinch }
            let src = GestureSource.tapThumb(hand: handEnum, finger: finger)
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

        handFrames[isRight] = frame
    }

    // MARK: Placement gestures (old GestureController state machines)

    private func updatePlacementGestures(dt: Double) {
        let left = handFrames[false] ?? .untracked
        let right = handFrames[true] ?? .untracked

        // Left-hand stability gate (activation only) + grab-end cooldown,
        // both wall-clock (seconds) so render cadence doesn't change them.
        leftStableTime = left.isTracked ? leftStableTime + dt : 0
        grabCooldown = max(0, grabCooldown - dt)

        let bothValid = left.isTracked && right.isTracked
            && left.pinchPosValid && right.pinchPosValid
        let separation = simd_distance(left.pinchPos, right.pinchPos)

        // ── TWO-HAND GRAB ───────────────────────────────────────────────────
        // Anchor-based absolute evaluation (GrabTransform), applied through
        // the old adaptive one-pole. Tracking loss / release ends the gesture
        // instantly and the placement stays exactly where it was — nothing
        // integrates, nothing springs back (the old app's load-bearing
        // no-jump property).
        if let activeGrab = grab {
            let held = bothValid
                && left.indexPinch >= Self.grabRelease
                && right.indexPinch >= Self.grabRelease
                && separation <= Self.maxActiveHandDistance
            if held {
                let evaluated = activeGrab.evaluate(
                    left: left.pinchPos, right: right.pinchPos,
                    scaleClamp: frameTuning.scaleClamp)
                placementDynamics.applyGrab(evaluated, dt: Float(dt))
            } else {
                endGrab(cooldown: true)
            }
        } else if leftStableTime >= Self.leftStabilitySeconds && bothValid
            && left.indexPinch >= Self.grabActivate
            && right.indexPinch >= Self.grabActivate
            && separation <= Self.maxStartHandDistance {
            // Snapshot against the DISPLAYED placement (old app: captured the
            // displayed values, not targets — re-grabbing mid-smooth never
            // pops).
            grab = GrabTransform(
                left: left.pinchPos, right: right.pinchPos,
                placement: placementDynamics.displayed)
        }

        // ── RIGHT-HAND INDEX-PINCH TRANSLATE ────────────────────────────────
        // Suppressed while grabbing (both hands) or during the grab-end
        // lockout.
        guard grab == nil, grabCooldown == 0 else {
            endTranslate()
            return
        }

        // Reference point: palm preferred, pinch midpoint fallback — but
        // deltas are only taken between SAME-source samples. The old code
        // could difference a palm sample against a pinch sample (~6-10 cm
        // apart) when the metacarpal joint flickered, injecting ×3-amplified
        // teleports; on a source switch we re-anchor instead.
        let point: (SIMD3<Float>, TranslatePoint)? = right.palm.map { ($0, .palm) }
            ?? (right.pinchPosValid ? (right.pinchPos, .pinch) : nil)

        if translating {
            if right.isTracked, right.indexPinch >= Self.translateRelease,
                let (current, source) = point {
                if let prev = translatePrev, translatePrevSource == source {
                    let raw = current - prev
                    let len = simd_length(raw)
                    if len > 0 {
                        // Old app order: cap the amplified step FIRST, then
                        // sensitivity × zoom compensation. Zoom comp reads
                        // the DISPLAYED grab scale: zoomed-in holograms move
                        // in finer steps (clamped 0.5…maxZoomComp; the
                        // mandelbulb family caps at 1.5).
                        let scaled = raw / len * min(len * Self.translateMultiplier, Self.translateMaxStep)
                        let zoomComp = simd_clamp(
                            1 / pow(max(placementDynamics.displayed.scale, 0.01), 0.3),
                            0.5, frameTuning.maxZoomComp)
                        placementDynamics.translate(
                            by: scaled * Self.translationSensitivity * zoomComp)
                    }
                }
                translatePrev = current
                translatePrevSource = source
            } else {
                endTranslate()
            }
        } else if right.isTracked, right.indexPinch >= Self.translateActivate,
            let (current, source) = point,
            // Lead gap: the index pinch must outpace middle/ring (anatomical
            // coupling drives neighbors to ~60-70% on an index pinch).
            right.indexPinch - max(right.middlePinch, right.ringPinch) >= Self.translateLeadGap,
            // Other-hand guard: a left pinch at grab strength means a
            // two-hand grab is forming — don't let translate steal it.
            !(left.isTracked && left.indexPinch >= Self.otherHandPinchGuard) {
            translating = true
            translatePrev = current
            translatePrevSource = source
        }
    }

    private func endGrab(cooldown: Bool) {
        guard grab != nil else { return }
        grab = nil
        if cooldown { grabCooldown = Self.grabEndCooldownSeconds }
    }

    private func endTranslate() {
        translating = false
        translatePrev = nil
        translatePrevSource = nil
    }
}

#endif  // os(visionOS)
