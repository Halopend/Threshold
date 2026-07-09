// CommandBufferHealth.swift — GPU fault visibility for the LIVE paths
// (observability phase 1).
//
// The offscreen shells check `commandBuffer.error` after waitUntilCompleted
// (OffscreenRenderer, Evaluators). The live shells never wait — a completion
// handler is the only place a fault can surface, and those handlers used to
// read the stats buffer without ever looking at `status`. A GPU fault (page
// fault, runaway march, device restart) therefore froze the image with ZERO
// diagnostics. Every live completion handler now routes through `check`.
//
// THRESHOLD_GPU_FAULTS=1 additionally attaches Metal's per-encoder execution
// status to live command buffers (`MTLCommandBufferErrorOption`) — it names
// the encoder that faulted, at a small tracking cost, so it is opt-in rather
// than always-on for the 120 Hz path.

import Foundation
import Metal
import Synchronization
import ThresholdCore

/// Per-shell fault counter + rate-limited fault logger. Sendable: captured by
/// completion handlers, which Metal runs on its own completion thread.
final class CommandBufferHealth: Sendable {
    /// Opt-in per-encoder execution status (process-wide, read once).
    static let verboseFaults =
        DiagnosticSwitches.isEnabled(.verboseGPUFaults)

    private let shell: String
    private let faults = Atomic<UInt64>(0)

    /// `shell` names the encode path in log lines ("session",
    /// "compositor.raster", …).
    init(shell: String) {
        self.shell = shell
    }

    /// Total faulted command buffers seen (any thread).
    var faultCount: UInt64 { faults.load(ordering: .relaxed) }

    /// Command-buffer factory for the live paths: plain buffer normally, one
    /// with encoder execution status when THRESHOLD_GPU_FAULTS is set.
    static func makeCommandBuffer(on queue: MTLCommandQueue) -> MTLCommandBuffer? {
        guard verboseFaults else { return queue.makeCommandBuffer() }
        let descriptor = MTLCommandBufferDescriptor()
        descriptor.errorOptions = .encoderExecutionStatus
        return queue.makeCommandBuffer(descriptor: descriptor)
    }

    /// Call from the completion handler with the completed buffer. Faults are
    /// logged rate-limited — the first few, then every 60th — because a device
    /// restart faults EVERY subsequent frame, and a line per frame would bury
    /// the first (most informative) report.
    func check(_ completed: MTLCommandBuffer) {
        guard completed.status == .error else { return }
        let n = faults.wrappingAdd(1, ordering: .relaxed).oldValue
        guard n < 5 || (n + 1) % 60 == 0 else { return }
        let description = completed.error.map { String(describing: $0) }
            ?? "status .error with no error object"
        ThresholdLog.render.fault(
            """
            \(self.shell, privacy: .public) command buffer faulted \
            (#\(n + 1)): \(description, privacy: .public)
            """)
        DiagnosticBreadcrumbs.record(
            category: "gpu", message: "command_buffer_fault",
            metadata: [
                "shell": shell,
                "count": String(n + 1),
                "error": description,
            ])
        // Encoder attribution, present when THRESHOLD_GPU_FAULTS built the
        // buffer with .encoderExecutionStatus.
        if let nsError = completed.error as NSError?,
           let infos = nsError.userInfo[MTLCommandBufferEncoderInfoErrorKey]
               as? [any MTLCommandBufferEncoderInfo] {
            for info in infos where info.errorState != .completed {
                ThresholdLog.render.fault(
                    """
                    \(self.shell, privacy: .public) encoder \
                    '\(info.label, privacy: .public)': \
                    \(Self.describe(info.errorState), privacy: .public)
                    """)
                DiagnosticBreadcrumbs.record(
                    category: "gpu", message: "command_encoder_fault",
                    metadata: [
                        "shell": shell,
                        "encoder": info.label,
                        "state": Self.describe(info.errorState),
                    ])
            }
        }
    }

    static func describe(_ state: MTLCommandEncoderErrorState) -> String {
        switch state {
        case .unknown: "unknown"
        case .completed: "completed"
        case .affected: "affected (another encoder faulted)"
        case .pending: "pending (never ran)"
        case .faulted: "faulted (this encoder)"
        @unknown default: "unrecognized"
        }
    }

    /// Human-readable command-buffer status — the stall dump's vocabulary.
    static func describe(_ status: MTLCommandBufferStatus) -> String {
        switch status {
        case .notEnqueued: "not enqueued"
        case .enqueued: "enqueued"
        case .committed: "committed"
        case .scheduled: "scheduled (on GPU or waiting for it)"
        case .completed: "completed"
        case .error: "error"
        @unknown default: "unrecognized"
        }
    }
}
