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

        public var summaryLine: String {
            String(format: "median %.2f ms (%.1f fps) mean %.2f p95 %.2f "
                   + "min %.2f max %.2f over %d frames",
                   medianMs, medianFPS, meanMs, p95Ms, minMs, maxMs,
                   measuredFrames)
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
    /// directly; `run` is the driver).
    public static func summarize(
        warmup: Int, samples: [Double], totalSteps: UInt64
    ) -> Result {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        let median = percentile(sorted, 0.5)
        return Result(
            warmupFrames: warmup,
            measuredFrames: samples.count,
            gpuMsSamples: samples,
            meanMs: samples.reduce(0, +) / Double(samples.count),
            medianMs: median,
            p95Ms: percentile(sorted, 0.95),
            minMs: sorted.first!,
            maxMs: sorted.last!,
            medianFPS: median > 0 ? 1000.0 / median : .infinity,
            totalSteps: totalSteps)
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
