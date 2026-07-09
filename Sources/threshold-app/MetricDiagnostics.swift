// MetricDiagnostics.swift — app-level crash/hang capture and lifecycle glue.

import Foundation
import os
import ThresholdCore

#if canImport(MetricKit)
import MetricKit
#endif

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

final class AppDiagnostics: NSObject, @unchecked Sendable {
    static let shared = AppDiagnostics()

    private let lock = NSLock()
    private var started = false
    private var terminationObserver: NSObjectProtocol?

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let identity = ThresholdBuildIdentity.current
        DiagnosticBreadcrumbs.beginSession(identity: identity)
        ThresholdLog.diagnostics.notice(
            "\(identity.summary, privacy: .public)")
        ThresholdLog.diagnostics.notice(
            "diagnostic switches: \(DiagnosticSwitches.summary, privacy: .public)")
        ThresholdLog.diagnostics.notice(
            "diagnostic files: \(DiagnosticBreadcrumbs.directoryURL.path, privacy: .public)")

        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif

        #if os(macOS)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { _ in
            DiagnosticBreadcrumbs.record(
                category: "lifecycle", message: "application_will_terminate")
            DiagnosticBreadcrumbs.markCleanExit()
        }
        #elseif canImport(UIKit)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { _ in
            DiagnosticBreadcrumbs.record(
                category: "lifecycle", message: "application_will_terminate")
            DiagnosticBreadcrumbs.markCleanExit()
        }
        #endif
    }

    func stop(clean: Bool) {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        started = false
        let observer = terminationObserver
        terminationObserver = nil
        lock.unlock()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        #if canImport(MetricKit)
        MXMetricManager.shared.remove(self)
        #endif
        if clean { DiagnosticBreadcrumbs.markCleanExit() }
    }
}

#if canImport(MetricKit)
extension AppDiagnostics: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        DiagnosticBreadcrumbs.record(
            category: "diagnostic", message: "metrickit_metrics_received",
            metadata: ["count": String(payloads.count)])
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            DiagnosticBreadcrumbs.storeArtifact(
                prefix: "metrickit-diagnostic",
                data: data,
                metadata: ["source": "MetricKit"])
        }
        ThresholdLog.diagnostics.notice(
            "received \(payloads.count) MetricKit diagnostic payload(s)")
    }
}
#endif
