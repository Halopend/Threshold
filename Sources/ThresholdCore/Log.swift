// Log.swift — the shared health/error logging surface (observability phase 1).
//
// One subsystem, one Logger per domain, so every failure the app survives
// still leaves a trail. This is for FAILURES and lifecycle facts only — perf
// telemetry (signposts, frame summaries) stays in ThresholdRender's
// RenderTelemetry ("com.polinate.threshold.render"), which feeds Instruments.
//
// Everything logged here is visible in Console.app, in a sysdiagnose, and via
//   log stream --predicate 'subsystem == "com.pupppower.threshold.rebuild"'
// including release builds on device — none of which is true of print().
//
// Severity contract — pick the level by unified logging's NATIVE persistence
// tiers, so routine breadcrumbs cost nothing and failures always persist:
//   .fault  — the feature/session cannot continue (dead render session,
//             GPU fault, wedged pipeline). These are the "why is it frozen"
//             lines; they must fire exactly where the old code went silent.
//   .error  — degraded but running (export failed, dropped frames, corrupt
//             file skipped). Persisted.
//   .notice — lifecycle transitions (session up/stopped, capture started,
//             layer paused). Persisted; keep these LOW-RATE.
//   .info   — context breadcrumbs (user commands, pipeline switches, frame
//             summaries). Memory ring buffer only — visible live via
//             `log stream --info` and captured in a sysdiagnose, but not
//             written to disk in normal operation. Free to be generous.
//   .debug  — chatty per-interaction detail (slider commits, palette edits).
//             Compiled in but discarded unless a debug stream is attached.

import os

public enum ThresholdLog {
    /// Deliberately distinct from the original app: both products otherwise
    /// appear as "Threshold" in crash reports and unified logging.
    public static let subsystem = "com.pupppower.threshold.rebuild"

    /// GPU work: command-buffer faults, pipeline stalls, dropped frames.
    public static let render = Logger(subsystem: subsystem, category: "render")
    /// Session lifecycle: render-thread setup failures, start/stop joins.
    public static let session = Logger(subsystem: subsystem, category: "session")
    /// Audio capture: mic engine, taps, route changes.
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    /// Hand tracking / gesture input.
    public static let hands = Logger(subsystem: subsystem, category: "hands")
    /// Scene/animation/preset persistence.
    public static let io = Logger(subsystem: subsystem, category: "io")
    /// Build identity, breadcrumbs, MetricKit, and diagnostic switches.
    public static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}
