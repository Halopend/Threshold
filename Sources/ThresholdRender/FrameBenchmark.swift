// FrameBenchmark.swift — frame-time benchmark built into the headless
// render architecture (plan §9). Drives any per-frame render closure
// (offscreen CLI, tests, future shells) through warmup + measured passes and
// reports distribution statistics on the GPU frame time — the number the
// FPS-at-resolution contract is judged on.
//
// GPU milliseconds come from the command buffer (gpuStartTime/gpuEndTime via
// MarchStats), not wall clock, so the figures are readback/IO-independent and
// deterministic-machine comparable across optimization rounds.

import Foundation

public enum FrameBenchmark {

    /// Distribution summary over the measured frames.
    public struct Result: Codable, Sendable {
        public let warmupFrames: Int
        public let measuredFrames: Int
        public let gpuMsSamples: [Double]
        public let meanMs: Double
        public let medianMs: Double
        public let p95Ms: Double
        public let minMs: Double
        public let maxMs: Double
        /// Steady-state throughput implied by the median GPU frame time.
        public let medianFPS: Double
        public let totalSteps: UInt64
        /// Sample standard deviation of the GPU frame times (noise band).
        public let stdevMs: Double
        /// Coefficient of variation `stdev/mean` as a percent — the
        /// noise-relative-to-signal figure a regression must clear.
        public let covPct: Double
        /// Deterministic march step count of ONE measured-pipeline frame,
        /// recovered from a stats-on twin so the timing pass stays atomic-free.
        /// 0 when unmeasured (e.g. generic pipeline already counted inline).
        public let stepsPerFrame: UInt64
        /// `medianMs` attributed per march step — separates "fewer steps" from
        /// "faster steps" across optimization rounds. 0 when `stepsPerFrame` is.
        public let nsPerStep: Double
        /// `ProcessInfo.thermalState` at measurement time — a warm run's slow
        /// numbers carry this flag instead of masquerading as a regression.
        public let thermalState: String

        public var summaryLine: String {
            String(format: "median %.2f ms (%.1f fps) mean %.2f p95 %.2f "
                   + "min %.2f max %.2f over %d frames",
                   medianMs, medianFPS, meanMs, p95Ms, minMs, maxMs,
                   measuredFrames)
        }

        /// Second line: measurement-quality context (noise, step attribution,
        /// thermal) — the figures Phase-0 instrumentation added (ADR-006).
        public var qualityLine: String {
            let noise = String(format: "cov %.1f%% (σ %.2f ms)", covPct, stdevMs)
            let thermal = "thermal \(thermalState)"
            guard stepsPerFrame > 0 else { return "\(noise) · \(thermal)" }
            return String(format: "%@ · %llu steps/frame @ %.1f ns/step · %@",
                          noise, stepsPerFrame, nsPerStep, thermal)
        }
    }

    /// Run `renderFrame` warmup+frames times; the closure returns that
    /// frame's stats (advance clocks/animation inside it as desired).
    public static func run(
        warmup: Int, frames: Int,
        renderFrame: (_ frameIndex: Int, _ measured: Bool) throws -> MarchStats
    ) rethrows -> Result {
        precondition(frames > 0, "benchmark needs at least one measured frame")
        for i in 0..<max(0, warmup) {
            _ = try renderFrame(i, false)
        }
        var samples: [Double] = []
        samples.reserveCapacity(frames)
        var steps: UInt64 = 0
        for i in 0..<frames {
            let stats = try renderFrame(max(0, warmup) + i, true)
            samples.append(stats.gpuMilliseconds)
            steps += stats.totalSteps
        }
        return summarize(warmup: max(0, warmup), samples: samples,
                         totalSteps: steps)
    }

    /// Pure statistics over already-collected samples (tests use this
    /// directly; `run` is the driver). `stepsPerFrame`/`thermalState` are
    /// run-context the caller measures separately (a stats-on twin and
    /// `ProcessInfo`) — defaulted so non-bench callers are unaffected.
    public static func summarize(
        warmup: Int, samples: [Double], totalSteps: UInt64,
        stepsPerFrame: UInt64 = 0, thermalState: String = "unknown"
    ) -> Result {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        let median = percentile(sorted, 0.5)
        let mean = samples.reduce(0, +) / Double(samples.count)
        // Sample variance (n−1); 0 for a single frame.
        let variance = samples.count > 1
            ? samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(samples.count - 1)
            : 0
        let stdev = variance.squareRoot()
        let nsPerStep = stepsPerFrame > 0
            ? median * 1_000_000.0 / Double(stepsPerFrame) : 0
        return Result(
            warmupFrames: warmup,
            measuredFrames: samples.count,
            gpuMsSamples: samples,
            meanMs: mean,
            medianMs: median,
            p95Ms: percentile(sorted, 0.95),
            minMs: sorted.first!,
            maxMs: sorted.last!,
            medianFPS: median > 0 ? 1000.0 / median : .infinity,
            totalSteps: totalSteps,
            stdevMs: stdev,
            covPct: mean > 0 ? stdev / mean * 100 : 0,
            stepsPerFrame: stepsPerFrame,
            nsPerStep: nsPerStep,
            thermalState: thermalState)
    }

    /// Linear-interpolated percentile over pre-sorted samples, q ∈ [0, 1].
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Int(pos.rounded(.up))
        if lo == hi { return sorted[lo] }
        let f = pos - Double(lo)
        return sorted[lo] * (1 - f) + sorted[hi] * f
    }
}
