// HandFrameFilterTests.swift — Phase 3 joint conditioning: plausibility gate
// (reject teleport spikes) + One-Euro smoothing (kill jitter, keep motion).

import Foundation
import simd
import Testing
import ThresholdCore

@testable import ThresholdInputs

private let dt = 1.0 / 60.0

@Suite("HandFrameFilter")
struct HandFrameFilterTests {
    private func frame(_ p: SIMD3<Float>) -> HandFrame {
        var f = HandFrame()
        f.set(.indexTip, position: p)
        return f
    }

    @Test("A teleport-speed jump is dropped, not tracked")
    func plausibilityDropsTeleport() {
        var filter = HandFrameFilter()
        // Settle at a point.
        for _ in 0..<5 { _ = filter.apply(frame(SIMD3(0, 1, 0)), dt: dt) }
        // Jump 1 m in one 60 Hz frame = 60 m/s ≫ maxJointSpeed: dropped.
        let out = filter.apply(frame(SIMD3(1, 1, 0)), dt: dt)
        #expect(out?.position(.indexTip) == nil)
        // A plausible step is accepted.
        let ok = filter.apply(frame(SIMD3(0.01, 1, 0)), dt: dt)
        #expect(ok?.position(.indexTip) != nil)
    }

    @Test("One-Euro attenuates jitter around a still pose")
    func smoothsJitter() {
        var filter = HandFrameFilter()
        var seed: UInt64 = 42
        func noise() -> Float {  // deterministic ±3 mm
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.006
        }
        var maxDev: Float = 0
        for _ in 0..<120 {
            let jittered = SIMD3<Float>(noise(), 1 + noise(), noise())
            if let out = filter.apply(frame(jittered), dt: dt)?.position(.indexTip) {
                maxDev = max(maxDev, simd_length(out - SIMD3(0, 1, 0)))
            }
        }
        // Raw jitter reaches ~5 mm; filtered output stays well under it.
        #expect(maxDev < 0.004)
    }

    @Test("Whole-hand loss resets history (no low-pass across the gap)")
    func lossResetsHistory() {
        var filter = HandFrameFilter()
        for _ in 0..<10 { _ = filter.apply(frame(SIMD3(0, 1, 0)), dt: dt) }
        _ = filter.apply(nil, dt: dt)  // hand gone
        // Reappears somewhere far: first sample passes through verbatim (no
        // history to low-pass toward, and no plausibility ref to reject it).
        let out = filter.apply(frame(SIMD3(0.5, 1.2, -0.3)), dt: dt)
        #expect(out?.position(.indexTip) == SIMD3(0.5, 1.2, -0.3))
    }

    @Test("Fast intentional motion is tracked with little lag")
    func tracksFastMotion() {
        var filter = HandFrameFilter()
        var pos = SIMD3<Float>(0, 1, 0)
        var last = pos
        for _ in 0..<60 {
            pos.x += 0.02  // 1.2 m/s — fast but plausible
            if let out = filter.apply(frame(pos), dt: dt)?.position(.indexTip) { last = out }
        }
        // One-Euro trails fast motion by a bounded margin (adaptive cutoff),
        // and would catch up once motion stops.
        #expect(abs(last.x - pos.x) < 0.06)
    }
}
