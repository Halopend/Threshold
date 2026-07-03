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
/// User-tunable gesture feel, persisted in UserDefaults (device-local UI
/// state, not scene content). Read fresh per gesture event — UserDefaults
/// caches in-process, so this costs nothing and needs no plumbing between
/// the Settings panel and the shells' CameraInteraction instance.
public struct CameraTuning: Sendable {
    public var orbitScale: Float
    public var dollyScale: Float
    public var invertScroll: Bool

    public static let orbitScaleKey = "threshold.input.orbitScale"
    public static let dollyScaleKey = "threshold.input.dollyScale"
    public static let invertScrollKey = "threshold.input.invertScroll"

    public static func load(from defaults: UserDefaults = .standard) -> CameraTuning {
        func scale(_ key: String) -> Float {
            let raw = defaults.object(forKey: key) as? Double ?? 1
            return Float(min(max(raw, 0.25), 4))
        }
        return CameraTuning(
            orbitScale: scale(orbitScaleKey),
            dollyScale: scale(dollyScaleKey),
            invertScroll: defaults.bool(forKey: invertScrollKey))
    }
}

@MainActor
public final class CameraInteraction {
    /// Radians of orbit per point of drag (before the user's orbitScale).
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

    private var orbitPerPoint: Float {
        Self.radiansPerPoint * CameraTuning.load().orbitScale
    }

    public func dragChanged(translation: CGSize) {
        publishOrbit(
            yaw: yaw + Float(translation.width) * orbitPerPoint,
            pitch: pitch + Float(translation.height) * orbitPerPoint)
    }

    public func dragEnded(translation: CGSize) {
        // Pin committed offsets to the param ranges (same reasoning as the
        // dolly accumulator: no dead travel past the clamp).
        yaw = min(max(yaw + Float(translation.width) * orbitPerPoint, -25.13), 25.13)
        pitch = min(max(pitch + Float(translation.height) * orbitPerPoint, -1.53), 1.53)
        publishOrbit(yaw: yaw, pitch: pitch)
    }

    // MARK: Keyboard nudges (committed immediately, like scroll)

    /// Orbit by a fixed step (keyboard navigation). Radians, pre-tuning.
    public func nudgeOrbit(yawDelta: Float, pitchDelta: Float) {
        let scale = CameraTuning.load().orbitScale
        yaw = min(max(yaw + yawDelta * scale, -25.13), 25.13)
        pitch = min(max(pitch + pitchDelta * scale, -1.53), 1.53)
        publishOrbit(yaw: yaw, pitch: pitch)
    }

    /// Dolly by a fixed log step (keyboard navigation): negative = in.
    public func nudgeDolly(logStep: Float) {
        let scale = CameraTuning.load().dollyScale
        logDolly = min(max(logDolly + logStep * scale, -3), 3)
        publishDolly(logDolly)
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
        let tuning = CameraTuning.load()
        let step = Float(deltaY) * Self.dollyPerScrollPoint * tuning.dollyScale
        logDolly = min(max(logDolly + (tuning.invertScroll ? -step : step), -3), 3)
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
