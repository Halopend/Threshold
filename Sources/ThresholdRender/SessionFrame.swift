// SessionFrame.swift — the value SessionCore produces per frame: the GPU
// request plus everything a RenderSnapshot needs except the (asynchronous)
// GPU stats. The display-link shell renders `request` into the drawable and
// publishes `snapshot(...)`; tests render the SAME request through
// OffscreenRenderer and assert on `resolved` directly.

import ThresholdCore

/// One stepped frame, no drawable/display-link dependency.
struct SessionFrame {
    /// Everything the march kernel consumes, sized to the CURRENT drawable.
    let request: RenderRequest
    let resolved: ResolvedParams
    let frameIndex: UInt64
    /// Session clock time (AppClock now, not wall time).
    let time: Double
    let deKey: String
    /// The AUTHORED warp stack (pre-simplification) — `request.ops` carries
    /// the simplified buffer the GPU sees.
    let warpStack: [WarpOpDTO]
    let paused: Bool
    /// The active gradient palette — what the gradient editor displays.
    let palette: Palette

    /// Complete the snapshot with the PREVIOUS completed frame's GPU stats
    /// (the frame path never waits on the GPU — ARCHITECTURE.md §2).
    func snapshot(gpuMilliseconds: Double, totalSteps: UInt64) -> RenderSnapshot {
        RenderSnapshot(
            resolved: resolved,
            frameIndex: frameIndex,
            time: time,
            gpuMilliseconds: gpuMilliseconds,
            totalSteps: totalSteps,
            deKey: deKey,
            warpStack: warpStack,
            paused: paused,
            palette: palette)
    }
}
