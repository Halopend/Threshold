// RenderTelemetry.swift — profiling instrumentation for the render thread
// (plan §9 "measured in CI"; the perf-testing seam). This exists to ANSWER
// "why is the frame rate sporadic at high resolution?" with data instead of
// guesses: is the pipeline GPU-bound (frame cadence tracks GPU time) or
// CPU/sync-bound (the step/encode/drawable-wait costs dominate)?
//
// Two channels:
//  1. os_signpost intervals — zero-cost when no tool is attached, and visible
//     as named regions in Instruments' os_signpost + Metal System Trace.
//  2. A periodic os_log summary — the average phase breakdown every N frames,
//     so we get numbers WITHOUT attaching Instruments (fast feedback / CI).
//
// INVARIANT 9 NOTE: the wall-clock reads here are NON-authoritative telemetry.
// They never feed render logic (the frame still steps on the display link's
// targetTimestamp). Profiling timestamps ≠ the render clock, deliberately.

import Foundation
import os

/// Sendable holder for the signpost/log handles (safe to capture anywhere).
public struct RenderTelemetry: Sendable {
    public static let subsystem = "com.polinate.threshold.render"

    let signposter: OSSignposter
    let log: Logger

    public init() {
        self.signposter = OSSignposter(subsystem: Self.subsystem, category: "frame")
        self.log = Logger(subsystem: Self.subsystem, category: "frame")
    }
}

/// Monotonic nanosecond stopwatch for telemetry only (Invariant 9: not the
/// render clock). Uses the mach uptime clock via DispatchTime.
enum Mono {
    @inline(__always) static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    @inline(__always) static func ms(_ from: UInt64, _ to: UInt64) -> Double {
        to > from ? Double(to - from) / 1_000_000.0 : 0
    }
}

/// Render-thread-confined frame profiler. NOT Sendable — created on and touched
/// only by the render thread. Accumulates the per-phase costs and the callback
/// cadence, emits an os_signpost interval per frame, and logs a rolling average
/// every `summaryEvery` frames.
final class FrameProfiler {
    private let telemetry: RenderTelemetry
    private let summaryEvery: Int
    /// When true, also logs a summary line; signposts are always emitted.
    private let logSummaries: Bool
    /// Optional file sink for the summary lines. os_log is ideal under
    /// Instruments, but a headless/sandboxed capture can't always read the
    /// unified log store — a plain file always works. Render-thread confined.
    private let sink: FileHandle?

    // Rolling accumulators (reset each summary window).
    private var frames = 0
    private var sumInterFrame = 0.0
    private var sumStep = 0.0
    private var sumEncode = 0.0
    private var sumDrawable = 0.0
    private var sumGpu = 0.0
    private var maxInterFrame = 0.0
    private var lastFrameEntry: UInt64 = 0

    init(
        telemetry: RenderTelemetry, summaryEvery: Int = 60, logSummaries: Bool,
        filePath: String? = nil
    ) {
        self.telemetry = telemetry
        self.summaryEvery = max(summaryEvery, 1)
        self.logSummaries = logSummaries
        if let filePath, logSummaries {
            FileManager.default.createFile(atPath: filePath, contents: nil)
            self.sink = FileHandle(forWritingAtPath: filePath)
        } else {
            self.sink = nil
        }
        if logSummaries {
            // Immediate plumbing confirmation (fires on the render thread the
            // moment profiling starts, independent of frame rate).
            let banner = "profiler active — summaries every \(self.summaryEvery) frames"
            telemetry.log.log("\(banner, privacy: .public)")
            emitToFile(banner)
        }
    }

    private func emitToFile(_ line: String) {
        guard let sink else { return }
        try? sink.write(contentsOf: Data((line + "\n").utf8))
    }

    var signposter: OSSignposter { telemetry.signposter }

    /// Record one frame's measured phases (all milliseconds; gpuMs is the
    /// PREVIOUS completed frame's GPU time, the value the pipeline actually
    /// publishes). Call once per render callback.
    func record(
        entry: UInt64, stepMs: Double, drawableMs: Double, encodeMs: Double,
        gpuMs: Double, frameIndex: UInt64, pixels: Int
    ) {
        let inter = lastFrameEntry == 0 ? 0 : Mono.ms(lastFrameEntry, entry)
        lastFrameEntry = entry

        frames += 1
        sumInterFrame += inter
        sumStep += stepMs
        sumEncode += encodeMs
        sumDrawable += drawableMs
        sumGpu += gpuMs
        maxInterFrame = max(maxInterFrame, inter)

        guard logSummaries, frames >= summaryEvery else { return }
        let n = Double(frames)
        let cpu = (sumStep + sumEncode + sumDrawable) / n
        let avgInter = sumInterFrame / n
        let realFps = avgInter > 0 ? 1000.0 / avgInter : 0
        // Diagnosis heuristic: if the callback cadence tracks GPU time and CPU
        // is small, it's GPU-bound; if CPU (esp. drawable-wait) dominates the
        // gap, it's CPU/sync-bound.
        let gpuAvg = sumGpu / n
        let bound = gpuAvg > cpu * 1.5 ? "GPU-bound" : (cpu > gpuAvg * 1.5 ? "CPU-bound" : "mixed")
        emitToFile(String(
            format: "frame %llu %dpx realFps=%.1f inter=%.2fms(max %.2f) "
                + "step=%.3f drawable=%.3f encode=%.3f gpu=%.2f -> %@",
            frameIndex, pixels, realFps, avgInter, maxInterFrame,
            sumStep / n, sumDrawable / n, sumEncode / n, gpuAvg, bound))
        telemetry.log.log("""
            frame \(frameIndex, privacy: .public) \(Int(sqrt(Double(pixels))), privacy: .public)²px \
            realFps=\(realFps, format: .fixed(precision: 1), privacy: .public) \
            inter=\(avgInter, format: .fixed(precision: 2), privacy: .public)ms \
            (max \(self.maxInterFrame, format: .fixed(precision: 2), privacy: .public)) \
            step=\(self.sumStep / n, format: .fixed(precision: 3), privacy: .public) \
            drawable=\(self.sumDrawable / n, format: .fixed(precision: 3), privacy: .public) \
            encode=\(self.sumEncode / n, format: .fixed(precision: 3), privacy: .public) \
            gpu=\(gpuAvg, format: .fixed(precision: 2), privacy: .public) → \(bound, privacy: .public)
            """)
        frames = 0
        sumInterFrame = 0; sumStep = 0; sumEncode = 0; sumDrawable = 0; sumGpu = 0
        maxInterFrame = 0
    }
}
