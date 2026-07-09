// PipelineCompilationScheduler.swift — one bounded lane for runtime Metal
// source/library/pipeline compilation. Metal compiler calls can block for
// seconds; they must not occupy Swift's fixed-width cooperative pool.

import Dispatch
import Foundation
import ThresholdCore

final class PipelineCompilationScheduler: @unchecked Sendable {
    static let shared = PipelineCompilationScheduler()

    private let queue = DispatchQueue(
        label: "com.pupppower.threshold.rebuild.pipeline-compilation",
        qos: .utility)

    private init() {}

    func submit(
        label: String,
        operation: @escaping @Sendable () -> Void
    ) {
        DiagnosticBreadcrumbs.record(
            category: "pipeline", message: "compile_queued",
            metadata: ["label": label])
        queue.async {
            let started = ProcessInfo.processInfo.systemUptime
            DiagnosticBreadcrumbs.record(
                category: "pipeline", message: "compile_started",
                metadata: ["label": label])
            operation()
            let milliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - started) * 1_000)
            DiagnosticBreadcrumbs.record(
                category: "pipeline", message: "compile_completed",
                metadata: [
                    "label": label,
                    "durationMs": String(milliseconds),
                ])
        }
    }
}
