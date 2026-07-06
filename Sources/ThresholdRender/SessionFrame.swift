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
    /// Animation transport state — what the play/scrub UI displays.
    let animation: AnimationPlaybackState
    /// Dynamic-arena registrations (external DE params) — the UI derives
    /// controls for these exactly as for the static layout entries.
    let dynamicEntries: [CatalogEntry]
    /// Zoom-rebase counter — total zoom depth = octave + resolved scale.zoom.
    let scaleOctave: Int32
    /// Bumped on DE switch / scene apply / external-DE swap — shells reset
    /// temporal-reconstruction history when it moves (the reset funnel).
    let historyEpoch: UInt32
    /// Active external DE program — the encoder binds its pipeline/table
    /// instead of the context's built-in-only ones.
    let externalProgram: ExternalDEProgram?
    /// Live audio feature levels read from the signal table this frame — what
    /// the Music-pane meter displays (the UI cannot read the table directly).
    let audioLevels: AudioLevels

    /// Complete the snapshot with the PREVIOUS completed frame's GPU stats
    /// (the frame path never waits on the GPU — ARCHITECTURE.md §2) plus the
    /// encoder's pipeline diagnostics for this frame.
    func snapshot(
        gpuMilliseconds: Double, totalSteps: UInt64,
        diagnostics: RenderDiagnostics = RenderDiagnostics()
    ) -> RenderSnapshot {
        RenderSnapshot(
            resolved: resolved,
            frameIndex: frameIndex,
            time: time,
            gpuMilliseconds: gpuMilliseconds,
            totalSteps: totalSteps,
            deKey: deKey,
            warpStack: warpStack,
            paused: paused,
            palette: palette,
            animation: animation,
            dynamicEntries: dynamicEntries,
            scaleOctave: scaleOctave,
            diagnostics: diagnostics,
            audioLevels: audioLevels)
    }
}
