// HandTracker.swift — visionOS hand input (plan §8): the thin ARKit adapter.
// Owns the HandTrackingProvider lifecycle and, per frame, maps each
// HandAnchor onto a platform-free `HandFrame`, then steps the shared
// `HandGestureEngine` (which owns ALL detection, signal publishing, and
// gesture-lane writes — and is unit-tested off-device through the same
// HandFrame seam this adapter feeds).
//
// `update(sessionTime:)` is called by the CompositorSession render loop via
// its `onFrame` hook — the tracker is render-thread confined after `start()`.

#if os(visionOS)

import ARKit
import Foundation
import os
import Synchronization
import ThresholdCore

public final class HandTracker: @unchecked Sendable {
    private let engine: HandGestureEngine
    private struct Tracking: @unchecked Sendable {
        let session = ARKitSession()
        let provider = HandTrackingProvider()
    }
    private let tracking = Mutex<Tracking?>(nil)
    @MainActor private var trackingTask: Task<Void, Never>?
    /// Previous frame's session time, for the engine's dt (render-thread
    /// confined, like the rest of `update`).
    private var lastTime: Double?
    private let resetRequested = Atomic<Bool>(false)

    public init(layout: CatalogLayout, mailbox: LaneMailbox, signals: SignalTable) {
        engine = HandGestureEngine(layout: layout, mailbox: mailbox, signals: signals)
    }

    /// Install the active fractal's gesture bindings (call on fractal switch and
    /// whenever the user edits a binding). Thread-safe.
    public func setBindings(_ table: GestureBindingTable) {
        engine.setBindings(table)
    }

    /// Suppress skeleton drives while the user is in UI panels. Thread-safe.
    public func setUISuppressed(_ on: Bool) {
        engine.setUISuppressed(on)
    }

    /// Per-source arming progress for the arming visualization. Thread-safe.
    public func armingSnapshot() -> [GestureSource: Float] {
        engine.armingSnapshot()
    }

    /// Drop in-flight gesture state without committing (scene load).
    public func reset() {
        resetRequested.store(true, ordering: .releasing)
    }

    /// Request authorization + start the provider. Hand tracking denied is
    /// non-fatal: signals stay unpublished and the gesture lane stays quiet.
    @MainActor public func start() {
        stop()
        // The Simulator has no hand tracking, and running an unsupported
        // provider makes ARKit RAISE an NSException (not throw) — the catch
        // below never sees it and the app dies. Same non-fatal contract as a
        // denial: quiet gesture lane.
        guard HandTrackingProvider.isSupported else {
            ThresholdLog.hands.notice(
                "hand tracking unsupported here (Simulator?) — gesture lane stays quiet")
            return
        }
        // ARKit rejects stopped providers; every immersive opening gets fresh ones.
        let current = Tracking()
        tracking.withLock { $0 = current }
        reset()
        trackingTask = Task {
            defer { if Task.isCancelled { current.session.stop() } }
            do {
                try Task.checkCancellation()
                try await current.session.run([current.provider])
                ThresholdLog.hands.notice("hand tracking running")
            } catch {
                ThresholdLog.hands.error(
                    """
                    hand tracking unavailable — gesture lane stays quiet: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
    }

    @MainActor public func stop() {
        trackingTask?.cancel()
        trackingTask = nil
        let previous = tracking.withLock { value in
            let previous = value
            value = nil
            return previous
        }
        previous?.session.stop()
        reset()
        ThresholdLog.hands.notice("hand tracking stopped")
    }

    /// Per-frame poll: map ARKit anchors to HandFrames and step the engine.
    /// `sessionTime` is the render loop's frame time (session clock); `dt` is
    /// derived from the previous frame (frame-rate-invariant gates need it).
    /// `grabActive` = a two-hand world grab owns motion this frame, so
    /// skeleton drives are suppressed (cross-stack arbiter).
    public func update(sessionTime: Double, grabActive: Bool = false) {
        if resetRequested.exchange(false, ordering: .acquiringAndReleasing) {
            engine.reset()
            lastTime = nil
        }
        let dt = lastTime.map { max(sessionTime - $0, 1e-4) } ?? (1.0 / 90.0)
        lastTime = sessionTime
        let provider = tracking.withLock { $0?.provider }
        let anchors = provider?.latestAnchors
        engine.update(
            left: Self.handFrame(anchors?.leftHand),
            right: Self.handFrame(anchors?.rightHand),
            sessionTime: sessionTime, dt: dt, grabActive: grabActive)
    }

    // MARK: ARKit → HandFrame

    /// nil when the hand is absent/untracked; per-joint confidence is
    /// ARKit's binary isTracked (1/0 — untracked joints are simply omitted).
    /// Non-finite joint values are HandFrame's problem: its gated
    /// `position(_:)` drops them at the seam.
    static func handFrame(_ anchor: HandAnchor?) -> HandFrame? {
        guard let anchor, anchor.isTracked,
              let skeleton = anchor.handSkeleton
        else { return nil }

        let originFromAnchor = anchor.originFromAnchorTransform
        var frame = HandFrame()
        frame.set(
            .wrist,
            position: SIMD3(
                originFromAnchor.columns.3.x,
                originFromAnchor.columns.3.y,
                originFromAnchor.columns.3.z))

        let joints: [(HandFrame.Joint, HandSkeleton.JointName)] = [
            (.thumbTip, .thumbTip),
            (.indexTip, .indexFingerTip),
            (.middleTip, .middleFingerTip),
            (.ringTip, .ringFingerTip),
            (.littleTip, .littleFingerTip),
            (.palmCenter, .middleFingerMetacarpal),
            (.forearm, .forearmArm),
        ]
        for (target, name) in joints {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { continue }
            let m = originFromAnchor * joint.anchorFromJointTransform
            frame.set(target, position: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z))
        }
        return frame
    }
}

#endif  // os(visionOS)
