// CameraInteraction.swift — desktop/touch camera control (plan §8.3:
// "Desktop orbit/zoom writes the gesture lane"). Pure lane-write plumbing:
// drags and pinches accumulate offsets and publish LATCHED gesture-lane
// values on the camera rig params through the session's lane mailbox — no
// camera math here (CameraRig owns the pose; the resolver owns clamping and
// gesture smoothing).

import Foundation
import SwiftUI
import ThresholdCore

/// Translates view gestures into gesture-lane writes on the camera rig.
/// Values are latched (they persist after the gesture ends — the binding
/// policy for direct camera control); an explicit reset clears the lane
/// state back to the authored pose.
@MainActor
public final class CameraInteraction {
    /// Radians of orbit per point of drag.
    public static let radiansPerPoint: Float = 0.008
    /// log-dolly per point of scroll (positive scroll = dolly in).
    public static let dollyPerScrollPoint: Float = -0.002

    private let mailbox: LaneMailbox
    private let yawSlot: Int?
    private let pitchSlot: Int?
    private let dollySlot: Int?

    // Committed offsets (between gestures); in-flight gestures add on top.
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var logDolly: Float = 0

    public init(layout: CatalogLayout, mailbox: LaneMailbox) {
        self.mailbox = mailbox
        self.yawSlot = layout.slot(for: .cameraOrbitYaw)
        self.pitchSlot = layout.slot(for: .cameraOrbitPitch)
        self.dollySlot = layout.slot(for: .cameraDolly)
    }

    // MARK: Orbit (drag)

    public func dragChanged(translation: CGSize) {
        publishOrbit(
            yaw: yaw + Float(translation.width) * Self.radiansPerPoint,
            pitch: pitch + Float(translation.height) * Self.radiansPerPoint)
    }

    public func dragEnded(translation: CGSize) {
        // Pin committed offsets to the param ranges (same reasoning as the
        // dolly accumulator: no dead travel past the clamp).
        yaw = min(max(yaw + Float(translation.width) * Self.radiansPerPoint, -25.13), 25.13)
        pitch = min(max(pitch + Float(translation.height) * Self.radiansPerPoint, -1.53), 1.53)
        publishOrbit(yaw: yaw, pitch: pitch)
    }

    // MARK: Dolly (pinch / scroll)

    /// Pinch: magnification > 1 (fingers apart) dollies IN (factor < 1).
    public func magnifyChanged(_ magnification: CGFloat) {
        guard magnification > 0 else { return }
        publishDolly(logDolly - Float(log(Double(magnification))))
    }

    public func magnifyEnded(_ magnification: CGFloat) {
        guard magnification > 0 else { return }
        // Pin the accumulator to the param's range (log(0.05...20) ≈ ±3) so
        // an over-scrolled gesture reverses immediately instead of unwinding
        // dead travel — the resolver clamps anyway; this is interaction feel.
        logDolly = min(max(logDolly - Float(log(Double(magnification))), -3), 3)
        publishDolly(logDolly)
    }

    /// Scroll wheel / two-finger scroll (macOS): immediate committed dolly.
    public func scroll(deltaY: CGFloat) {
        logDolly = min(max(logDolly + Float(deltaY) * Self.dollyPerScrollPoint, -3), 3)
        publishDolly(logDolly)
    }

    /// Clear all interaction state — back to the authored pose.
    public func reset() {
        yaw = 0
        pitch = 0
        logDolly = 0
        if let yawSlot { mailbox.publish(LaneWrite(lane: .gesture, slot: yawSlot, value: 0)) }
        if let pitchSlot { mailbox.publish(LaneWrite(lane: .gesture, slot: pitchSlot, value: 0)) }
        if let dollySlot { mailbox.publish(LaneWrite(lane: .gesture, slot: dollySlot, value: 1)) }
    }

    // MARK: Publishing

    private func publishOrbit(yaw: Float, pitch: Float) {
        if let yawSlot {
            mailbox.publish(LaneWrite(lane: .gesture, slot: yawSlot, value: yaw))
        }
        if let pitchSlot {
            mailbox.publish(LaneWrite(lane: .gesture, slot: pitchSlot, value: pitch))
        }
    }

    private func publishDolly(_ logValue: Float) {
        guard let dollySlot else { return }
        mailbox.publish(LaneWrite(lane: .gesture, slot: dollySlot, value: exp(logValue)))
    }
}
