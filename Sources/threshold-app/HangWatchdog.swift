// HangWatchdog.swift — main-thread hang detector (observability phase 2).
//
// A sidecar thread pings the main queue every 100ms and measures how long the
// ping takes to land. Anything past `threshold` is a hang the user felt as
// "the controls locked up": one .error line when it clears (with the measured
// duration), so a frozen-feeling session leaves a persisted trail alongside
// the render/session breadcrumbs in ThresholdLog.
//
// Deliberately dumb: no stack capture (Instruments/spindump own that), no
// per-tick logging (a healthy app logs nothing), and the sidecar never touches
// app state — it only observes the latency of an empty main-queue block.

import Dispatch
import Foundation
import ThresholdCore

final class HangWatchdog: @unchecked Sendable {
    private let threshold: TimeInterval
    private let queue = DispatchQueue(label: "com.polinate.threshold.watchdog",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Uptime when the currently-outstanding ping was posted, or nil if it
    /// landed. Guarded by `queue`.
    private var pingPostedAt: TimeInterval?
    /// Whether the outstanding ping has already been reported as a hang (so a
    /// multi-second hang logs once at clear time, not once per tick).
    private var reportedHang = false

    init(threshold: TimeInterval = 0.25) {
        self.threshold = threshold
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        ThresholdLog.session.notice(
            "hang watchdog armed (threshold \(Int(self.threshold * 1000))ms)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        if let posted = pingPostedAt {
            // Previous ping still in flight — the main thread is busy.
            let stalled = ProcessInfo.processInfo.systemUptime - posted
            if stalled >= threshold, !reportedHang {
                reportedHang = true
                ThresholdLog.session.error(
                    "main thread hang in progress (\(Int(stalled * 1000))ms and counting)")
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
                        "main thread hang cleared after \(Int(duration * 1000))ms")
                } else if duration >= self.threshold {
                    ThresholdLog.session.error(
                        "main thread hang: \(Int(duration * 1000))ms")
                }
                self.reportedHang = false
                self.pingPostedAt = nil
            }
        }
    }
}
