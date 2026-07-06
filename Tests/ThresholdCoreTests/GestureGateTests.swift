// GestureGateTests.swift — the engagement FSM in isolation (plan Phases 1–2).
// Pure, deterministic: feed strengths + dt, assert edges and states.

import Testing
@testable import ThresholdCore

private let dt = 1.0 / 60.0

/// Drive a gate for `frames` at constant strength, return the last tick.
@discardableResult
private func run(
    _ gate: inout GestureGate, strength: Float?, frames: Int
) -> GateTick {
    var t = GateTick.inactive
    for _ in 0..<frames { t = gate.update(strength: strength, dt: dt) }
    return t
}

@Suite("GestureGate")
struct GestureGateTests {
    @Test("Dwell: a single spurious high frame never engages")
    func dwellRejectsSingleFrame() {
        var g = GestureGate(GateConfig(on: 0.7, off: 0.4, armDwell: 0.05))
        let t = g.update(strength: 1, dt: dt)  // one frame < 0.05 s
        #expect(!t.engaged)
        #expect(t.state == .arming)
    }

    @Test("Sustained strength engages after the dwell, once")
    func engagesAfterDwell() {
        var g = GestureGate(GateConfig(on: 0.7, off: 0.4, armDwell: 0.05))
        var engagedEdges = 0
        for _ in 0..<10 {
            if g.update(strength: 1, dt: dt).justEngaged { engagedEdges += 1 }
        }
        #expect(engagedEdges == 1)
        #expect(g.state == .active)
    }

    @Test("Hysteresis: strength between off and on neither engages nor releases")
    func hysteresisBand() {
        var g = GestureGate(GateConfig(on: 0.7, off: 0.4, armDwell: 0.02))
        run(&g, strength: 1, frames: 5)  // engage
        #expect(g.state == .active)
        let t = run(&g, strength: 0.5, frames: 20)  // in the band
        #expect(t.engaged)  // still held
        #expect(g.state == .active)
    }

    @Test("Release below off, then a cooldown blocks immediate re-arm")
    func releaseThenCooldown() {
        var g = GestureGate(GateConfig(on: 0.7, off: 0.4, armDwell: 0.02, cooldown: 0.1))
        run(&g, strength: 1, frames: 5)
        let rel = g.update(strength: 0.1, dt: dt)
        #expect(rel.justReleased)
        #expect(g.state == .cooling)
        // Immediately high again, but cooldown (0.1 s) blocks arming.
        let t = g.update(strength: 1, dt: dt)
        #expect(!t.engaged && t.state == .cooling)
        // After the cooldown elapses it re-arms.
        run(&g, strength: 1, frames: 12)
        #expect(g.state == .active)
    }

    @Test("Grace: a brief nil holds the gesture; recovery resumes")
    func graceHoldsAndResumes() {
        var g = GestureGate(GateConfig(on: 0.7, off: 0.4, armDwell: 0.02, graceWindow: 0.1))
        run(&g, strength: 1, frames: 5)
        let sus = g.update(strength: nil, dt: dt)
        #expect(sus.suspended && sus.engaged && g.state == .suspended)
        let resumed = g.update(strength: 1, dt: dt)
        #expect(resumed.resumed && resumed.live && g.state == .active)
    }

    @Test("Grace expiry releases cleanly")
    func graceExpiryReleases() {
        var g = GestureGate(GateConfig(on: 0.7, off: 0.4, armDwell: 0.02, graceWindow: 0.05))
        run(&g, strength: 1, frames: 5)
        var released = false
        for _ in 0..<10 { if g.update(strength: nil, dt: dt).justReleased { released = true } }
        #expect(released)
        #expect(g.state == .cooling || g.state == .idle)
    }

    @Test("Lost mid-arm drops to idle without engaging")
    func lostMidArmDrops() {
        var g = GestureGate(GateConfig(on: 0.7, off: 0.4, armDwell: 0.1))
        _ = g.update(strength: 1, dt: dt)  // arming
        let t = g.update(strength: nil, dt: dt)
        #expect(!t.engaged && g.state == .idle)
    }

    @Test("armingProgress ramps 0→1 across the dwell")
    func armingProgressRamps() {
        var g = GestureGate(GateConfig(on: 0.7, off: 0.4, armDwell: 0.05))
        let first = g.update(strength: 1, dt: dt)
        #expect(first.armingProgress >= 0 && first.armingProgress < 1)
        run(&g, strength: 1, frames: 5)
        #expect(g.update(strength: 1, dt: dt).armingProgress == 1)
    }

    @Test("Frame-rate invariance: dwell measured in seconds, not frames")
    func frameRateInvariant() {
        // 90 Hz and 45 Hz both engage at ~0.05 s of sustained strength.
        func framesToEngage(dt: Double) -> Int {
            var g = GestureGate(GateConfig(on: 0.7, off: 0.4, armDwell: 0.05))
            var n = 0
            while !g.update(strength: 1, dt: dt).justEngaged { n += 1; if n > 1000 { break } }
            return n
        }
        let fast = Double(framesToEngage(dt: 1.0 / 90.0)) / 90.0
        let slow = Double(framesToEngage(dt: 1.0 / 45.0)) / 45.0
        #expect(abs(fast - slow) < 0.03)  // both ≈ 0.05 s
    }
}
