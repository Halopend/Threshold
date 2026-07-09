// MainThreadHangWatchdog.swift — shared main-thread responsiveness detector.

import Dispatch
import Foundation

public final class MainThreadHangWatchdog: @unchecked Sendable {
    private let threshold: TimeInterval
    private let queue = DispatchQueue(
        label: "com.pupppower.threshold.rebuild.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pingPostedAt: TimeInterval?
    private var reportedHang = false

    public init(threshold: TimeInterval = 0.25) {
        self.threshold = threshold
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        ThresholdLog.diagnostics.notice(
            "main-thread watchdog armed (threshold \(Int(self.threshold * 1_000))ms)")
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        if let posted = pingPostedAt {
            let stalled = ProcessInfo.processInfo.systemUptime - posted
            if stalled >= threshold, !reportedHang {
                reportedHang = true
                ThresholdLog.session.error(
                    "main thread hang in progress (\(Int(stalled * 1_000))ms and counting)")
                DiagnosticBreadcrumbs.record(
                    category: "hang", message: "main_thread_hang_started",
                    metadata: ["durationMs": String(Int(stalled * 1_000))])
            }
            return
        }

        let posted = ProcessInfo.processInfo.systemUptime
        pingPostedAt = posted
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let landed = ProcessInfo.processInfo.systemUptime
            self.queue.async {
                let duration = landed - posted
                if self.reportedHang {
                    ThresholdLog.session.error(
                        "main thread hang cleared after \(Int(duration * 1_000))ms")
                    DiagnosticBreadcrumbs.record(
                        category: "hang", message: "main_thread_hang_cleared",
                        metadata: ["durationMs": String(Int(duration * 1_000))])
                } else if duration >= self.threshold {
                    ThresholdLog.session.error(
                        "main thread hang: \(Int(duration * 1_000))ms")
                    DiagnosticBreadcrumbs.record(
                        category: "hang", message: "main_thread_hang",
                        metadata: ["durationMs": String(Int(duration * 1_000))])
                }
                self.reportedHang = false
                self.pingPostedAt = nil
            }
        }
    }
}
