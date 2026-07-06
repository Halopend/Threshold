// HandGestureEngine.swift — the platform-free half of hand input (plan §8,
// adversarial plan Phase 0): consumes `HandFrame` snapshots and produces the
// hand.* signals plus gesture-lane writes. The visionOS `HandTracker` is now
// a thin ARKit→HandFrame adapter; tests and the replay harness drive this
// engine directly with recorded or synthesized frames — every threshold and
// state machine below is exercisable in `swift test` on any platform.
//
// Behavior is the HandTracker logic moved verbatim (camera pinch-drags with
// hysteresis, assignable tapThumb/tapPalm/swipe/fist drives through
// GestureLaneResolver); joint reads go through `HandFrame.position(_:)`,
// which gates confidence and non-finite values at the seam.

import Foundation
import os
import simd
import ThresholdCore

/// Render-thread confined after start (same contract as HandTracker, which
/// owns it); `setBindings` is the one cross-thread entry and locks.
public final class HandGestureEngine: @unchecked Sendable {
    // MARK: Tuning

    /// Thumb–index distance (meters) treated as a full pinch.
    static let pinchOnDistance: Float = 0.015
    /// Release distance (hysteresis so a pinch does not flicker at the rim).
    static let pinchOffDistance: Float = 0.035
    /// Orbit radians per meter of pinched right-hand travel.
    static let radiansPerMeter: Float = 2.5
    /// log-dolly per meter of pinched left-hand push/pull (push away = in).
    static let logDollyPerMeter: Float = 3.0
    /// Pinch strength (0…1) at/above which a tapThumb drag is engaged.
    static let tapThumbEngage: Float = 0.6
    /// Finger travel (m) that maps to a full ±1 normalized drive. ~15 cm.
    static let dragMetersToUnit: Float = 1.0 / 0.15
    /// Hand speed (m/s) that maps to a full ±1 swipe drive.
    static let swipeMetersPerSecToUnit: Float = 1.0 / 1.5

    // MARK: Wiring

    private let signals: SignalTable
    private let mailbox: LaneMailbox
    private let layout: CatalogLayout
    private let yawSlot: Int?
    private let pitchSlot: Int?
    private let dollySlot: Int?

    // MARK: Binding-driven detection (the assignable gesture layer)

    private let bindings = OSAllocatedUnfairLock<GestureBindingTable>(initialState: .init())
    private var frameDrives: [GestureSource: GestureDrive] = [:]
    private var frameTable = GestureBindingTable()
    private var committedDrag: [GestureSource: SIMD3<Float>] = [:]
    private var dragEngage: [GestureSource: SIMD3<Float>] = [:]
    private var lastWrist: [Bool: SIMD3<Float>] = [:]
    private var lastWristTime: [Bool: Double] = [:]

    // MARK: Camera drag state

    private struct Drag {
        var start: SIMD3<Float>
        var committedA: Float  // yaw (right) / logDolly (left)
        var committedB: Float  // pitch (right) / unused (left)
    }

    private var rightDrag: Drag?
    private var leftDrag: Drag?
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

    /// Per-frame step: publish hand signals and gesture-lane writes for one
    /// pair of hand snapshots (nil = hand not tracked this frame).
    public func update(left: HandFrame?, right: HandFrame?, sessionTime: Double) {
        // Snapshot the bindings once per frame: camera gating and the resolve
        // pass see the same table.
        frameTable = bindings.withLock { $0 }
        frameDrives.removeAll(keepingCapacity: true)

        updateHand(
            left, isRight: false, time: sessionTime,
            pinchSignal: .handLeftPinch, positionSignal: .handLeftPosition,
            palmSignal: .handLeftPalm, forearmSignal: .handLeftForearm)
        updateHand(
            right, isRight: true, time: sessionTime,
            pinchSignal: .handRightPinch, positionSignal: .handRightPosition,
            palmSignal: .handRightPalm, forearmSignal: .handRightForearm)

        // Map this frame's drives through the bindings onto the gesture lane.
        for write in GestureLaneResolver.resolve(
            drives: frameDrives, table: frameTable, layout: layout) {
            mailbox.publish(write)
        }
    }

    /// True when an assignable binding claims this source, so the hardwired
    /// camera control on the same finger must yield to it.
    private func bindingClaims(_ source: GestureSource) -> Bool {
        frameTable.binding(for: source) != nil
    }

    // MARK: Per-hand

    private func updateHand(
        _ frame: HandFrame?, isRight: Bool, time: Double,
        pinchSignal: SignalID, positionSignal: SignalID,
        palmSignal: SignalID, forearmSignal: SignalID
    ) {
        guard let frame, let wrist = frame.position(.wrist) else {
            // Lost tracking mid-pinch: end the drag at its last committed
            // offsets (nothing jumps when the hand re-appears).
            if isRight { rightDrag = nil } else { leftDrag = nil }
            return
        }

        signals.publish(
            id: positionSignal,
            value: SIMD4(wrist, 0), confidence: 1, timestamp: time)
        // Geometry for the hand-driven warp ops (plan §4.3): palm center for
        // the attract sphere, forearm point for the carve capsule's far end.
        let palmCenter = frame.position(.palmCenter)
        if let palm = palmCenter {
            signals.publish(
                id: palmSignal, value: SIMD4(palm, 0), confidence: 1, timestamp: time)
        }
        if let forearm = frame.position(.forearm) {
            signals.publish(
                id: forearmSignal, value: SIMD4(forearm, 0), confidence: 1, timestamp: time)
        }

        guard let thumb = frame.position(.thumbTip),
              let index = frame.position(.indexTip)
        else { return }
        let gap = simd_distance(thumb, index)
        // 1 at touching, fading to 0 by ~6 cm — a continuous, bindable value.
        let strength = max(0, min(1, 1 - (gap - Self.pinchOnDistance) / 0.045))
        signals.publish(
            id: pinchSignal,
            value: SIMD4(strength, 0, 0, 0), confidence: 1, timestamp: time)

        // ── Assignable gesture drives (fed to GestureLaneResolver) ──────────
        let handEnum: GestureHand = isRight ? .right : .left
        let fingerJoints: [(GestureFinger, HandFrame.Joint)] = [
            (.index, .indexTip), (.middle, .middleTip),
            (.ring, .ringTip), (.pinky, .littleTip),
        ]
        var fingertips: [SIMD3<Float>] = []
        for (finger, jointName) in fingerJoints {
            guard let tip = frame.position(jointName) else { continue }
            fingertips.append(tip)
            // tapThumb: while pinched, accumulate the finger's normalized 3D
            // displacement; commit on release so the bound param holds.
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
            // tapPalm: finger-to-palm touch strength (the palm drop-points).
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
        // swipe: wrist velocity (m/s) normalized to a ±1 per-axis drive.
        if let last = lastWrist[isRight], let lastT = lastWristTime[isRight], time > lastT {
            let velocity = (wrist - last) / Float(time - lastT)
            frameDrives[.swipe(hand: handEnum)] = .vector(velocity * Self.swipeMetersPerSecToUnit)
        }
        lastWrist[isRight] = wrist
        lastWristTime[isRight] = time

        // Latched pinch-drag with hysteresis (plan §8.3 gesture semantics).
        // Camera control on the index finger yields when a binding claims it.
        let midpoint = (thumb + index) * 0.5
        if bindingClaims(.tapThumb(hand: handEnum, finger: .index)) {
            if isRight { rightDrag = nil } else { leftDrag = nil }
        } else if isRight {
            rightDrag = drag(
                rightDrag, gap: gap, at: midpoint,
                committedA: yaw, committedB: pitch
            ) { [self] delta, drag in
                // Hand right = orbit right, hand up = orbit up.
                let newYaw = drag.committedA + delta.x * Self.radiansPerMeter
                let newPitch = drag.committedB - delta.y * Self.radiansPerMeter
                publish(yawSlot, newYaw)
                publish(pitchSlot, newPitch)
                return (newYaw, newPitch)
            } onEnd: { [self] a, b in
                yaw = min(max(a, -25.13), 25.13)
                pitch = min(max(b, -1.53), 1.53)
                publish(yawSlot, yaw)
                publish(pitchSlot, pitch)
            }
        } else {
            leftDrag = drag(
                leftDrag, gap: gap, at: midpoint,
                committedA: logDolly, committedB: 0
            ) { [self] delta, drag in
                // Push away (−z toward the content) = dolly IN (factor < 1).
                let newLog = drag.committedA + delta.z * Self.logDollyPerMeter
                if let dollySlot {
                    mailbox.publish(LaneWrite(
                        lane: .gesture, slot: dollySlot, value: exp(newLog)))
                }
                return (newLog, 0)
            } onEnd: { [self] a, _ in
                logDolly = min(max(a, -3), 3)
                if let dollySlot {
                    mailbox.publish(LaneWrite(
                        lane: .gesture, slot: dollySlot, value: exp(logDolly)))
                }
            }
        }
    }

    /// Shared latched-drag state machine: begins below the ON distance, ends
    /// above the OFF distance, calls `onMove` with the room-space delta while
    /// held and `onEnd` with the final values on release.
    private func drag(
        _ current: Drag?, gap: Float, at position: SIMD3<Float>,
        committedA: Float, committedB: Float,
        onMove: (SIMD3<Float>, Drag) -> (Float, Float),
        onEnd: (Float, Float) -> Void
    ) -> Drag? {
        if let drag = current {
            if gap > Self.pinchOffDistance {
                let (a, b) = onMove(position - drag.start, drag)
                onEnd(a, b)
                return nil
            }
            _ = onMove(position - drag.start, drag)
            return drag
        }
        if gap < Self.pinchOnDistance {
            return Drag(start: position, committedA: committedA, committedB: committedB)
        }
        return nil
    }

    private func publish(_ slot: Int?, _ value: Float) {
        guard let slot else { return }
        mailbox.publish(LaneWrite(lane: .gesture, slot: slot, value: value))
    }
}
