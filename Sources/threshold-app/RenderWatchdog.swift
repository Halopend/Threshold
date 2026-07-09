// RenderWatchdog.swift — render-progress stall detector.

import Dispatch
import Foundation
import ThresholdCore
import ThresholdRender

final class RenderWatchdog: @unchecked Sendable {
    private let session: InteractiveSession
    private let threshold: TimeInterval
    private let queue = DispatchQueue(label: "com.polinate.threshold.render-watchdog",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastFrame: UInt64?
    private var lastAdvancedAt = ProcessInfo.processInfo.systemUptime
    private var reported = false

    init(session: InteractiveSession, threshold: TimeInterval = 1.0) {
        self.session = session
        self.threshold = threshold
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        ThresholdLog.session.notice(
            "render watchdog armed (threshold \(Int(self.threshold * 1000))ms)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = session.snapshots.latest
        let frame = snapshot?.frameIndex
        if frame != lastFrame {
            if reported {
                let frozenMs = Int((now - lastAdvancedAt) * 1000)
                ThresholdLog.session.error(
                    """
                    render stall cleared after \(frozenMs)ms; \
                    \(self.diagnostics(snapshot), privacy: .public)
                    """)
            }
            lastFrame = frame
            lastAdvancedAt = now
            reported = false
            return
        }

        let stalled = now - lastAdvancedAt
        guard stalled >= threshold, !reported else { return }
        reported = true
        ThresholdLog.session.error(
            """
            render stall in progress (\(Int(stalled * 1000))ms); \
            \(self.diagnostics(snapshot), privacy: .public)
            """)
    }

    private func diagnostics(_ snapshot: RenderSnapshot?) -> String {
        let frame = snapshot?.frameIndex.description ?? "nil"
        let gpu = snapshot.map { String(format: "%.2f", $0.gpuMilliseconds) } ?? "nil"
        let de = snapshot?.deKey ?? "nil"
        let pipeline = snapshot?.diagnostics.pipeline.rawValue ?? "nil"
        let pending = snapshot?.diagnostics.specializationPending == true ? " pending" : ""
        return "frame=\(frame) gpuMs=\(gpu) de=\(de) pipeline=\(pipeline)\(pending) "
            + "commands=\(session.commands.pendingCount) lanes=\(session.laneMailbox.pendingCount)"
    }
}
