// HandFrameFilter.swift — Phase 3 joint conditioning: a stateful pass that
// sits between the raw HandFrame (ARKit or corpus) and gesture detection.
//
// Two jobs per joint, per frame:
//   • Plausibility gate — a joint that jumps faster than a hand physically
//     can (`maxJointSpeed`) is a tracking artifact (re-acquisition spike,
//     mislabeled joint), NOT user motion. It is DROPPED for this frame
//     (returned absent), which downstream reads as a momentary signal loss —
//     the gates ride their grace window instead of integrating the spike.
//   • One-Euro filter — an adaptive low-pass that smooths slow, deliberate
//     poses (killing jitter) while barely lagging fast intentional motion
//     (the whole point of One-Euro over a fixed low-pass). Runs on the joints
//     that survive the plausibility gate.
//
// Pure/deterministic given its dt inputs; no clock. One instance per hand.

import Foundation
import simd
import ThresholdCore

public struct HandFrameFilter: Sendable {
    /// Joint speed (m/s) above which a sample is rejected as implausible.
    /// Human fingertip peak speed tops out around 3–4 m/s; 6 leaves margin
    /// for fast intentional flicks while still catching teleport spikes.
    public var maxJointSpeed: Float = 6.0
    /// One-Euro minimum cutoff (Hz): lower = smoother at rest.
    public var minCutoff: Float = 1.5
    /// One-Euro speed coefficient: higher = less lag during fast motion.
    public var beta: Float = 0.4
    /// One-Euro derivative cutoff (Hz).
    public var dCutoff: Float = 1.0
    /// After this many consecutive implausible samples, accept anyway — the
    /// joint has genuinely re-acquired at a new location (vs a transient
    /// spike). Bounds how long a real fast move can be starved.
    public var maxDropStreak = 3

    private var filters: [HandFrame.Joint: OneEuro] = [:]
    /// Last ACCEPTED raw per joint (plausibility reference) + consecutive-drop
    /// count. Measuring against the last accepted sample (not each incoming
    /// raw) means a one-frame spike costs one frame, not two: the reference
    /// stays put, so the return reads as plausible.
    private var lastAccepted: [HandFrame.Joint: SIMD3<Float>] = [:]
    private var dropStreak: [HandFrame.Joint: Int] = [:]

    public init() {}

    /// Filter one frame. Returns nil when the whole hand is absent. Individual
    /// joints may be dropped (plausibility) even when the frame is present.
    public mutating func apply(_ frame: HandFrame?, dt: Double) -> HandFrame? {
        guard let frame, dt > 0 else {
            // Whole-hand loss: reset every filter so re-acquisition doesn't
            // low-pass across the gap (that would drag the first live frame
            // toward the stale pre-loss position).
            filters.removeAll(keepingCapacity: true)
            lastAccepted.removeAll(keepingCapacity: true)
            dropStreak.removeAll(keepingCapacity: true)
            return nil
        }
        var out = HandFrame()
        let dtf = Float(dt)
        for joint in HandFrame.Joint.allCases {
            guard let raw = frame.position(joint) else {
                filters[joint] = nil  // absent joint: drop its filter history
                lastAccepted[joint] = nil
                dropStreak[joint] = nil
                continue
            }
            // Plausibility vs the last ACCEPTED sample (the filtered value
            // lags a fast ramp by centimeters and would fake a teleport
            // speed). A sustained fast move steps only a little per frame, so
            // it passes; a genuine jump is dropped until it either returns
            // (transient spike) or persists past `maxDropStreak` (re-acquire).
            if let ref = lastAccepted[joint] {
                let jump = simd_length(raw - ref) / dtf
                if jump > maxJointSpeed && (dropStreak[joint] ?? 0) < maxDropStreak {
                    dropStreak[joint, default: 0] += 1
                    continue  // implausible: emit nothing, keep reference
                }
            }
            lastAccepted[joint] = raw
            dropStreak[joint] = 0
            var f = filters[joint] ?? OneEuro(
                minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
            let smoothed = f.filter(raw, dt: dtf)
            filters[joint] = f
            out.set(joint, position: smoothed, confidence: 1)
        }
        return out
    }
}

// MARK: - One-Euro filter

/// The 1€ filter (Casiez, Roussel, Vogel 2012): an adaptive exponential
/// low-pass whose cutoff rises with signal speed, so it smooths at rest and
/// tracks during motion. Per-component on a SIMD3.
struct OneEuro: Sendable {
    var minCutoff: Float
    var beta: Float
    var dCutoff: Float

    private(set) var value: SIMD3<Float>?
    private var dValue: SIMD3<Float> = .zero

    init(minCutoff: Float, beta: Float, dCutoff: Float) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ x: SIMD3<Float>, dt: Float) -> SIMD3<Float> {
        guard let prev = value else {
            value = x
            return x
        }
        let dx = (x - prev) / dt
        let aD = alpha(cutoff: dCutoff, dt: dt)
        dValue = aD * dx + (1 - aD) * dValue
        let speed = simd_length(dValue)
        let cutoff = minCutoff + beta * speed
        let a = alpha(cutoff: cutoff, dt: dt)
        let filtered = a * x + (1 - a) * prev
        value = filtered
        return filtered
    }
}
