// Log.swift — the shared health/error logging surface (observability phase 1).
//
// One subsystem, one Logger per domain, so every failure the app survives
// still leaves a trail. This is for FAILURES and lifecycle facts only — perf
// telemetry (signposts, frame summaries) stays in ThresholdRender's
// RenderTelemetry ("com.polinate.threshold.render"), which feeds Instruments.
//
// Everything logged here is visible in Console.app, in a sysdiagnose, and via
//   log stream --predicate 'subsystem BEGINSWITH "com.polinate.threshold"'
// including release builds on device — none of which is true of print().
//
// Severity contract:
//   .fault  — the feature/session cannot continue (dead render session,
//             GPU fault, wedged pipeline). These are the "why is it frozen"
//             lines; they must fire exactly where the old code went silent.
//   .error  — degraded but running (export failed, tracking unavailable).
//   .notice — lifecycle breadcrumbs worth having in a log archive.

import os

public enum ThresholdLog {
    public static let subsystem = "com.polinate.threshold"

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
}
