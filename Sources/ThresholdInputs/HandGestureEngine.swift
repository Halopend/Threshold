// HandGestureEngine.swift — the platform-free half of hand input (plan §8,
// adversarial plan Phases 1–4): consumes `HandFrame` snapshots and produces
// the hand.* signals plus gesture-lane writes. The visionOS `HandTracker` is
// a thin ARKit→HandFrame adapter; tests and the replay harness drive this
// engine directly with recorded or synthesized frames.
//
// Robustness layers, bottom to top:
//   1. Filter (Phase 3): each joint runs a One-Euro filter and a plausibility
//      gate before geometry — a teleporting joint is dropped, not tracked.
//   2. Arbitration (Phase 1): per hand, per frame — entry-stability gate,
//      pose exclusivity (a fist suppresses individual taps and swipe; a live
//      pinch suppresses swipe), winner-takes-all across fingers with a lead
//      gap so a sympathetically-coupled finger can't co-fire.
//   3. Engagement (Phase 2): every gesture routes its strength through a
//      `GestureGate` — hysteresis + dwell + grace/suspension + cooldown, all
//      in seconds. Continuous gestures anchor on engage/resume, accumulate
//      only while live, hold while suspended, and COMMIT ONLY ON RELEASE
//      (the monotone-release property that kills the ratchet bug).
//   4. Suppression (Phase 4): a two-hand world grab or an active UI panel
//      suppresses skeleton drives (the cross-stack arbiter); an arming
//      snapshot is published for the UI.

import Foundation
import os
import simd
import ThresholdCore

/// Render-thread confined after start (same contract as HandTracker, which
/// owns it); `setBindings` / `setUISuppressed` / `armingSnapshot` are the
/// cross-thread entries and lock.
public final class HandGestureEngine: @unchecked Sendable {
    // MARK: Tuning

    /// Orbit radians per meter of pinched right-hand travel.
    static let radiansPerMeter: Float = 2.5
    /// log-dolly per meter of pinched left-hand push/pull (push away = in).
    static let logDollyPerMeter: Float = 3.0
    /// Finger travel (m) that maps to a full ±1 normalized drive. ~15 cm.
    static let dragMetersToUnit: Float = 1.0 / 0.15
    /// Hand speed (m/s) that maps to a full ±1 swipe drive.
    static let swipeMetersPerSecToUnit: Float = 1.0 / 1.5

    /// A hand must be continuously tracked this long before ANY of its
    /// gestures may arm (the old app's 30-frame gate, now time-based).
    static let stabilityWindow: Double = 0.15
    /// A finger claims a tapThumb drag only if its pinch leads the runner-up
    /// by this much (anatomical-coupling defense).
    static let leadGap: Float = 0.15
    /// Fist closure at/above which the hand is a fist: individual taps and
    /// swipe are suppressed (pose exclusivity).
    static let fistPose: Float = 0.6
    /// Swipe requires an OPEN hand: every finger pinch below this…
    static let swipeOpenMax: Float = 0.3
    /// …and wrist speed at/above this (m/s). Below it, incidental hand motion
    /// produces NO swipe drive (the ungated-swipe false-trigger fix).
    static let swipeSpeedFloor: Float = 0.5

    // MARK: Wiring

    private let signals: SignalTable
    private let mailbox: LaneMailbox
    private let layout: CatalogLayout
    private let yawSlot: Int?
    private let pitchSlot: Int?
    private let dollySlot: Int?

    private let bindings = OSAllocatedUnfairLock<GestureBindingTable>(initialState: .init())
    private let uiSuppressed = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let arming = OSAllocatedUnfairLock<[GestureSource: Float]>(initialState: [:])

    private var frameDrives: [GestureSource: GestureDrive] = [:]
    private var frameTable = GestureBindingTable()
    private var frameArming: [GestureSource: Float] = [:]

    // MARK: Per-hand state (render-thread confined after start)

    private var left = HandState()
    private var right = HandState()
    // Committed camera offsets (between gestures); in-flight adds on top.
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var logDolly: Float = 0

    public init(layout: CatalogLayout, mailbox: LaneMailbox, signals: SignalTable) {
        self.signals = signals
        self.mailbox = mailbox
        self.layout = layout
        self.yawSlot = layout.slot(for: .cameraOrbitYaw)
        self.pitchSlot = layout.slot(for: .cameraOrbitPitch)
        self.dollySlot = layout.slot(for: .cameraDolly)
    }

    /// Install the active fractal's gesture bindings. Thread-safe.
    public func setBindings(_ table: GestureBindingTable) {
        bindings.withLock { $0 = table }
    }

    /// UI panels engaged: suppress ALL skeleton drives + camera control until
    /// cleared (parameter gestures must not fire while the user is in menus).
    public func setUISuppressed(_ on: Bool) {
        uiSuppressed.withLock { $0 = on }
    }

    /// Per-source arming progress (0…1) for the UI's arming visualization.
    /// Thread-safe snapshot; empty when nothing is arming/active.
    public func armingSnapshot() -> [GestureSource: Float] {
        arming.withLock { $0 }
    }

    /// Drop all in-flight gesture state without committing (scene load).
    public func reset() {
        left = HandState()
        right = HandState()
        yaw = 0; pitch = 0; logDolly = 0
        arming.withLock { $0 = [:] }
    }

    /// Per-frame step. `grabActive` = a two-hand world grab owns the motion
    /// this frame (cross-stack arbiter): skeleton drives are suppressed so the
    /// grab and the pinch-drives can't both move things off one gesture.
    public func update(
        left leftFrame: HandFrame?, right rightFrame: HandFrame?,
        sessionTime: Double, dt: Double, grabActive: Bool = false
    ) {
        frameTable = bindings.withLock { $0 }
        frameDrives.removeAll(keepingCapacity: true)
        frameArming.removeAll(keepingCapacity: true)
        let suppress = grabActive || uiSuppressed.withLock { $0 }

        updateHand(
            leftFrame, state: &left, isRight: false, time: sessionTime, dt: dt,
            suppress: suppress,
            pinchSignal: .handLeftPinch, positionSignal: .handLeftPosition,
            palmSignal: .handLeftPalm, forearmSignal: .handLeftForearm)
        updateHand(
            rightFrame, state: &right, isRight: true, time: sessionTime, dt: dt,
            suppress: suppress,
            pinchSignal: .handRightPinch, positionSignal: .handRightPosition,
            palmSignal: .handRightPalm, forearmSignal: .handRightForearm)

        for write in GestureLaneResolver.resolve(
            drives: frameDrives, table: frameTable, layout: layout) {
            mailbox.publish(write)
        }
        arming.withLock { $0 = frameArming }
    }

    /// Legacy 3-arg entry (assumes 90 Hz). Prefer the `dt:` form.
    public func update(left: HandFrame?, right: HandFrame?, sessionTime: Double) {
        update(left: left, right: right, sessionTime: sessionTime, dt: 1.0 / 90.0)
    }

    private func bindingClaims(_ source: GestureSource) -> Bool {
        frameTable.binding(for: source) != nil
    }

    // MARK: Per-hand

    private func updateHand(
        _ rawFrame: HandFrame?, state: inout HandState, isRight: Bool,
        time: Double, dt: Double, suppress: Bool,
        pinchSignal: SignalID, positionSignal: SignalID,
        palmSignal: SignalID, forearmSignal: SignalID
    ) {
        // Phase 3: filter joints (One-Euro + plausibility) before anything.
        guard let frame = state.filter.apply(rawFrame, dt: dt),
              let wrist = frame.position(.wrist)
        else {
            // Not tracked: entry-stability resets, but engaged gates ride
            // their own grace (fed nil below only if we reach detection — we
            // don't, so tick them to release cleanly here).
            state.trackedTime = 0
            releaseAllGates(&state, isRight: isRight, dt: dt)
            return
        }
        state.trackedTime += dt
        let stable = state.trackedTime >= Self.stabilityWindow

        // Signals are RAW and always published (bindable regardless of gating).
        signals.publish(
            id: positionSignal, value: SIMD4(wrist, 0), confidence: 1, timestamp: time)
        let palmCenter = frame.position(.palmCenter)
        if let palm = palmCenter {
            signals.publish(id: palmSignal, value: SIMD4(palm, 0), confidence: 1, timestamp: time)
        }
        if let forearm = frame.position(.forearm) {
            signals.publish(id: forearmSignal, value: SIMD4(forearm, 0), confidence: 1, timestamp: time)
        }
        let thumb = frame.position(.thumbTip)
        let index = frame.position(.indexTip)
        if let thumb, let index {
            let strength = HandGeometry.pinchStrength(thumb: thumb, finger: index)
            signals.publish(
                id: pinchSignal, value: SIMD4(strength, 0, 0, 0), confidence: 1, timestamp: time)
        }

        let handEnum: GestureHand = isRight ? .right : .left

        // Suppressed (grab / UI) or not yet stable: no drives, no camera —
        // but let engaged gates release cleanly so nothing sticks.
        guard !suppress else {
            releaseAllGates(&state, isRight: isRight, dt: dt)
            state.lastWrist = wrist
            state.lastWristTime = time
            return
        }

        let fingerJoints: [(GestureFinger, HandFrame.Joint)] = [
            (.index, .indexTip), (.middle, .middleTip),
            (.ring, .ringTip), (.pinky, .littleTip),
        ]
        var pinchByFinger: [GestureFinger: Float] = [:]
        var tipByFinger: [GestureFinger: SIMD3<Float>] = [:]
        var fingertips: [SIMD3<Float>] = []
        for (finger, jointName) in fingerJoints {
            guard let tip = frame.position(jointName) else { continue }
            tipByFinger[finger] = tip
            fingertips.append(tip)
            if let thumb {
                pinchByFinger[finger] = HandGeometry.pinchStrength(thumb: thumb, finger: tip)
            }
        }
        let fist = (palmCenter != nil && fingertips.count == 4)
            ? HandGeometry.fistClosure(fingerTips: fingertips, palm: palmCenter!)
            : 0
        let fisted = fist >= Self.fistPose

        // ── FIST (pose-exclusive: only when the hand is genuinely a fist) ──
        let fistSrc = GestureSource.fist(hand: handEnum)
        let fistTick = state.fistGate.update(
            strength: (palmCenter != nil && fingertips.count == 4) ? fist : nil, dt: dt)
        emitArming(fistSrc, fistTick)
        if fistTick.engaged { frameDrives[fistSrc] = .scalar(stable ? fist : 0) }

        // ── WINNER-TAKES-ALL across tapThumb fingers (lead-gap gated) ──────
        let winner = tapThumbWinner(
            pinchByFinger, locked: state.lockedFinger, fisted: fisted, stable: stable)
        state.lockedFinger = winner

        for (finger, jointName) in fingerJoints {
            let tip = tipByFinger[finger]
            let src = GestureSource.tapThumb(hand: handEnum, finger: finger)
            // Feed the gate this finger's pinch ONLY if it's the winner and
            // the joint is present; a missing joint feeds nil (→ suspension),
            // a non-winner feeds 0 (→ stays idle, never arms).
            let strength: Float?
            if tip == nil { strength = nil }
            else if finger == winner { strength = pinchByFinger[finger] ?? 0 }
            else { strength = 0 }
            let tick = state.tapThumbTick(finger, strength: strength, dt: dt)
            emitArming(src, tick)
            accumulateTapThumb(
                src: src, finger: finger, tick: tick, tip: tip, state: &state)
            _ = jointName
        }

        // ── TAP-PALM (pose-exclusive, per-finger gated, continuous value) ──
        if let palmCenter, !fisted {
            for finger in GestureFinger.allCases {
                guard let tip = tipByFinger[finger] else {
                    _ = state.tapPalmTick(finger, strength: nil, dt: dt)
                    continue
                }
                let th = HandGeometry.palmThresholds(for: finger)
                let raw = HandGeometry.palmTouchStrength(
                    fingerTip: tip, palm: palmCenter, touch: th.touch, away: th.away)
                let src = GestureSource.tapPalm(hand: handEnum, finger: finger)
                let tick = state.tapPalmTick(finger, strength: stable ? raw : 0, dt: dt)
                emitArming(src, tick)
                if tick.live { state.tapPalmLast[finger] = raw }
                if tick.engaged {
                    frameDrives[src] = .scalar(state.tapPalmLast[finger] ?? raw)
                }
            }
        } else {
            for finger in GestureFinger.allCases {
                _ = state.tapPalmTick(finger, strength: fisted ? 0 : nil, dt: dt)
            }
        }

        // ── SWIPE (gated event: open hand + speed floor, else NOTHING) ─────
        if let last = state.lastWrist, let lastT = state.lastWristTime, time > lastT {
            let velocity = (wrist - last) / Float(time - lastT)
            let speed = simd_length(velocity)
            // Vacuous safety: with no pinch readings (thumb missing) we cannot
            // assert the hand is open, so we do NOT swipe.
            let openHand = !pinchByFinger.isEmpty
                && pinchByFinger.values.allSatisfy { $0 < Self.swipeOpenMax }
            if stable && !fisted && openHand && speed >= Self.swipeSpeedFloor {
                frameDrives[.swipe(hand: handEnum)] =
                    .vector(velocity * Self.swipeMetersPerSecToUnit)
            }
        }
        state.lastWrist = wrist
        state.lastWristTime = time

        // ── CAMERA pinch-drag (index pinch; yields to a binding claim) ─────
        updateCamera(
            state: &state, isRight: isRight, stable: stable, dt: dt,
            thumb: thumb, index: index, handEnum: handEnum)
    }

    // MARK: tapThumb winner selection (lead gap + lock)

    private func tapThumbWinner(
        _ pinch: [GestureFinger: Float], locked: GestureFinger?,
        fisted: Bool, stable: Bool
    ) -> GestureFinger? {
        guard stable, !fisted else { return nil }
        // A locked finger keeps the claim until it drops below the release
        // hysteresis (the gate's `off`), regardless of coupling on others.
        if let locked, (pinch[locked] ?? 0) >= GateConfig.latched.off {
            return locked
        }
        let sorted = pinch.sorted { $0.value > $1.value }
        guard let top = sorted.first, top.value >= GateConfig.latched.on else { return nil }
        let runnerUp = sorted.count > 1 ? sorted[1].value : 0
        // Ambiguous (two coupled fingers both high, neither leading): block.
        return (top.value - runnerUp) >= Self.leadGap ? top.key : nil
    }

    // MARK: tapThumb accumulation (anchor / accumulate / hold / commit)

    /// Incremental accumulation: each live frame folds the step since the last
    /// frame into `committed`, then re-anchors to the current tip. This is
    /// suspension-safe by construction — a resume re-anchors to the current
    /// position, so the first post-gap step is zero (no jump) and no
    /// accumulated displacement is ever lost. `committed` changes ONLY while
    /// live, so a clean release leaves it fixed (monotone-release / no ratchet).
    private func accumulateTapThumb(
        src: GestureSource, finger: GestureFinger, tick: GateTick,
        tip: SIMD3<Float>?, state: inout HandState
    ) {
        var committed = state.tapThumbCommitted[finger] ?? .zero
        if tick.justEngaged || tick.resumed {
            state.tapThumbAnchor[finger] = tip
        }
        if tick.live, let tip, let anchor = state.tapThumbAnchor[finger] {
            committed += (tip - anchor) * Self.dragMetersToUnit
            state.tapThumbCommitted[finger] = committed
            state.tapThumbAnchor[finger] = tip
        }
        // Hold the committed value whenever the source has ever engaged, so a
        // bound param keeps its adjusted position (the lane is not folded to
        // base). Emit nothing while it's still zero → the lane stays identity.
        if committed != .zero || tick.engaged {
            frameDrives[src] = .vector(committed)
        }
        if tick.justReleased { state.tapThumbAnchor[finger] = nil }
    }

    // MARK: Camera

    private func updateCamera(
        state: inout HandState, isRight: Bool, stable: Bool, dt: Double,
        thumb: SIMD3<Float>?, index: SIMD3<Float>?, handEnum: GestureHand
    ) {
        // The index finger yields to an assignable binding on the same source.
        if bindingClaims(.tapThumb(hand: handEnum, finger: .index)) {
            _ = state.cameraGate.update(strength: 0, dt: dt)
            state.cameraAnchor = nil
            return
        }
        let strength: Float?
        let midpoint: SIMD3<Float>?
        if let thumb, let index {
            strength = stable ? HandGeometry.pinchStrength(thumb: thumb, finger: index) : 0
            midpoint = (thumb + index) * 0.5
        } else {
            strength = nil
            midpoint = nil
        }
        let tick = state.cameraGate.update(strength: strength, dt: dt)
        if tick.justEngaged || tick.resumed { state.cameraAnchor = midpoint }

        // Incremental (suspension-safe): fold the per-frame step into the
        // committed pose, re-anchor, publish. Resume re-anchors → no jump;
        // a held suspension leaves the pose put.
        if tick.live, let midpoint, let anchor = state.cameraAnchor {
            let delta = midpoint - anchor
            state.cameraAnchor = midpoint
            if isRight {
                yaw = min(max(yaw + delta.x * Self.radiansPerMeter, -25.13), 25.13)
                pitch = min(max(pitch - delta.y * Self.radiansPerMeter, -1.53), 1.53)
                publish(yawSlot, yaw); publish(pitchSlot, pitch)
            } else {
                logDolly = min(max(logDolly + delta.z * Self.logDollyPerMeter, -3), 3)
                if let dollySlot {
                    mailbox.publish(LaneWrite(lane: .gesture, slot: dollySlot, value: exp(logDolly)))
                }
            }
        } else if tick.justReleased {
            state.cameraAnchor = nil  // committed pose already holds the value
        }
    }

    // MARK: Helpers

    /// Tick every gate with a missing signal so an engaged one rides its grace
    /// window and releases cleanly; commit tapThumb/camera on the release edge.
    private func releaseAllGates(_ state: inout HandState, isRight: Bool, dt: Double) {
        for finger in GestureFinger.allCases {
            let src = GestureSource.tapThumb(hand: isRight ? .right : .left, finger: finger)
            let tick = state.tapThumbTick(finger, strength: nil, dt: dt)
            accumulateTapThumb(src: src, finger: finger, tick: tick, tip: nil, state: &state)
            _ = state.tapPalmTick(finger, strength: nil, dt: dt)
        }
        _ = state.fistGate.update(strength: nil, dt: dt)
        let cam = state.cameraGate.update(strength: nil, dt: dt)
        if cam.justReleased {
            // Grace expired mid-drag: keep the last committed pose (no jump).
            if isRight { publish(yawSlot, yaw); publish(pitchSlot, pitch) }
            else if let dollySlot {
                mailbox.publish(LaneWrite(lane: .gesture, slot: dollySlot, value: exp(logDolly)))
            }
            state.cameraAnchor = nil
        }
        state.lockedFinger = nil
    }

    private func emitArming(_ src: GestureSource, _ tick: GateTick) {
        if tick.armingProgress > 0 { frameArming[src] = tick.armingProgress }
    }

    private func publish(_ slot: Int?, _ value: Float) {
        guard let slot else { return }
        mailbox.publish(LaneWrite(lane: .gesture, slot: slot, value: value))
    }
}

// MARK: - Per-hand state

private struct HandState {
    var filter = HandFrameFilter()
    var trackedTime: Double = 0
    var lockedFinger: GestureFinger?

    var tapThumbGates: [GestureFinger: GestureGate] = [:]
    var tapThumbCommitted: [GestureFinger: SIMD3<Float>] = [:]
    /// Last-frame fingertip (the incremental accumulator's moving anchor).
    var tapThumbAnchor: [GestureFinger: SIMD3<Float>] = [:]

    var tapPalmGates: [GestureFinger: GestureGate] = [:]
    var tapPalmLast: [GestureFinger: Float] = [:]

    var fistGate = GestureGate(.latched)
    var cameraGate = GestureGate(.latched)
    var cameraAnchor: SIMD3<Float>?

    var lastWrist: SIMD3<Float>?
    var lastWristTime: Double?

    /// Tick a per-finger gate IN PLACE (GestureGate is a value type, so a
    /// returning accessor would mutate a throwaway copy) and return its tick.
    mutating func tapThumbTick(_ f: GestureFinger, strength: Float?, dt: Double) -> GateTick {
        var g = tapThumbGates[f] ?? GestureGate(.latched)
        let t = g.update(strength: strength, dt: dt)
        tapThumbGates[f] = g
        return t
    }

    mutating func tapPalmTick(_ f: GestureFinger, strength: Float?, dt: Double) -> GateTick {
        var g = tapPalmGates[f] ?? GestureGate(.latched)
        let t = g.update(strength: strength, dt: dt)
        tapPalmGates[f] = g
        return t
    }
}
