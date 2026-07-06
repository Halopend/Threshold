// HandGestureEngineTests.swift — the HandFrame seam + replay harness + the
// adversarial detection suite (plan Phases 0–4). Everything ARKit used to
// hide is driven headlessly: synthesized HandFrames step the engine, writes
// land in a real ModulationEngine through the shared mailbox, and resolve()
// (plus the arming snapshot) is the observable. Deterministic by construction.

import Foundation
import simd
import Testing
import ThresholdCore

@testable import ThresholdInputs

// MARK: - Harness

private struct Rig {
    let layout: CatalogLayout
    let clock: FixedStepClock
    let mod: ModulationEngine
    let hands: HandGestureEngine
    let signals: SignalTable
    var grabActive = false

    init() {
        let catalog = Catalog.withEngineDefaults()
        try! catalog.register(ParamSpec(
            key: ParamKey("de.t.warpx"), label: "Warp.x", range: 0...2, default: 0))
        try! catalog.register(ParamSpec(
            key: ParamKey("de.t.warpy"), label: "Warp.y", range: 0...2, default: 0))
        layout = catalog.freeze()
        clock = FixedStepClock(step: 1.0 / 60.0)
        mod = ModulationEngine(layout: layout, clock: clock)
        signals = SignalTable(ids: SignalID.standardSession)
        hands = HandGestureEngine(
            layout: layout, mailbox: mod.mailbox, signals: signals)
    }

    @discardableResult
    mutating func step(left: HandFrame? = nil, right: HandFrame? = nil) -> ResolvedParams {
        hands.update(
            left: left, right: right, sessionTime: clock.now,
            dt: clock.step, grabActive: grabActive)
        clock.advance()
        return mod.resolve()
    }

    /// Hold `right` for `frames` steps (past stability + dwell) to engage.
    mutating func warmup(right: HandFrame, frames: Int = 20) {
        for _ in 0..<frames { step(right: right) }
    }
}

/// A right hand with thumb/index at a controlled gap, centered on `base` so
/// the drag midpoint (x,z) is `base` regardless of gap — opening to release
/// never shifts the midpoint. Fingers other than index sit far from the
/// thumb (no pinch) and far from the palm (no fist).
private func rightHand(base: SIMD3<Float>, gap: Float) -> HandFrame {
    var f = HandFrame()
    f.set(.wrist, position: base)
    f.set(.thumbTip, position: base + SIMD3(-gap / 2, 0.05, 0))
    f.set(.indexTip, position: base + SIMD3(gap / 2, 0.05, 0))
    f.set(.middleTip, position: base + SIMD3(0.20, 0.05, 0))
    f.set(.ringTip, position: base + SIMD3(0.24, 0.05, 0))
    f.set(.littleTip, position: base + SIMD3(0.28, 0.05, 0))
    f.set(.palmCenter, position: base + SIMD3(0, -0.30, 0))
    return f
}

/// Thumb-index distance (m) that yields pinch strength `s` on the standard
/// ramp (on 0.02, off 0.05). Inverse of `HandGeometry.pinchStrength`.
private func gap(forStrength s: Float) -> Float {
    max(0.001, 0.05 - min(max(s, 0), 1) * 0.03)
}

/// A right hand where each finger's thumb-pinch strength is set independently
/// (distinct directions from the thumb so distances are exact). Palm far, so
/// no fist unless `palmClose`.
private func rightHand(
    base: SIMD3<Float>, pinches: [GestureFinger: Float], palmClose: Bool = false
) -> HandFrame {
    var f = HandFrame()
    let thumb = base
    f.set(.wrist, position: base)
    f.set(.thumbTip, position: thumb)
    let dirs: [GestureFinger: SIMD3<Float>] = [
        .index: SIMD3(1, 0, 0), .middle: SIMD3(0, 1, 0),
        .ring: SIMD3(0, 0, 1), .pinky: SIMD3(-1, 0, 0),
    ]
    let joints: [GestureFinger: HandFrame.Joint] = [
        .index: .indexTip, .middle: .middleTip, .ring: .ringTip, .pinky: .littleTip,
    ]
    for (finger, dir) in dirs {
        let s = pinches[finger] ?? 0
        f.set(joints[finger]!, position: thumb + dir * gap(forStrength: s))
    }
    f.set(.palmCenter, position: base + SIMD3(0, palmClose ? -0.02 : -0.30, 0))
    return f
}

// MARK: - Seam hygiene

@Suite("HandFrame seam")
struct HandFrameSeamTests {
    @Test("Non-finite joints are dropped at the gated read")
    func nanJointDropped() {
        var f = HandFrame()
        f.set(.thumbTip, position: SIMD3(.nan, 0, 0))
        f.set(.indexTip, position: SIMD3(0, .infinity, 0))
        f.set(.wrist, position: SIMD3(1, 1, 1), confidence: .nan)
        #expect(f.position(.thumbTip) == nil)
        #expect(f.position(.indexTip) == nil)
        #expect(f.position(.wrist) == nil)
    }

    @Test("Confidence below the floor reads as absent")
    func lowConfidenceDropped() {
        var f = HandFrame()
        f.set(.thumbTip, position: SIMD3(1, 2, 3), confidence: 0.4)
        #expect(f.position(.thumbTip) == nil)
        #expect(f.position(.thumbTip, minConfidence: 0.3) == SIMD3(1, 2, 3))
    }

    @Test("JSONL corpus round-trips exactly")
    func jsonlRoundTrip() throws {
        let records = [
            HandFrameRecord(
                time: 0.5, left: nil,
                right: rightHand(base: SIMD3(0.1, 1.0, -0.3), gap: 0.01)),
            HandFrameRecord(time: 0.6),
        ]
        let jsonl = try HandFrameRecord.dump(records)
        #expect(jsonl.split(separator: "\n").count == 2)
        let back = try HandFrameRecord.load(jsonl: jsonl)
        #expect(back == records)
    }
}

// MARK: - Engagement (Phases 0–2)

@Suite("HandGestureEngine")
struct HandGestureEngineTests {
    @Test("Silence invariant: no hands ⇒ resolve stays at authored defaults")
    func silenceWhenUntracked() {
        var rig = Rig()
        let baseline = rig.step().values
        for _ in 0..<10 { #expect(rig.step(left: nil, right: nil).values == baseline) }
    }

    @Test("Right-hand pinch-drag orbits yaw; release latches it")
    func pinchDragOrbits() throws {
        var rig = Rig()
        let yawSlot = try #require(rig.layout.slot(for: .cameraOrbitYaw))
        let base = SIMD3<Float>(0.2, 1.0, -0.4)

        // Warm up (stabilize + engage + anchor) at base, THEN drag +10 cm.
        rig.warmup(right: rightHand(base: base, gap: 0.01))
        let dragged = base + SIMD3<Float>(0.1, 0, 0)
        for _ in 0..<60 { rig.step(right: rightHand(base: dragged, gap: 0.01)) }
        #expect(abs(rig.mod.resolvedValue(slot: yawSlot) - 0.25) < 0.01)

        // Open past release (strength < off): value latches.
        for _ in 0..<60 { rig.step(right: rightHand(base: dragged, gap: gap(forStrength: 0.2))) }
        #expect(abs(rig.mod.resolvedValue(slot: yawSlot) - 0.25) < 0.01)
    }

    @Test("Hysteresis dead-band: pinch hovering between off and on never engages")
    func hysteresisDeadBand() throws {
        var rig = Rig()
        let yawSlot = try #require(rig.layout.slot(for: .cameraOrbitYaw))
        // Strength 0.55 sits between off(0.4) and on(0.7): idle forever, so
        // even large hand motion produces no orbit.
        var base = SIMD3<Float>(0, 1, -0.4)
        for _ in 0..<60 {
            base.x += 0.02
            rig.step(right: rightHand(base: base, gap: gap(forStrength: 0.55)))
        }
        #expect(abs(rig.mod.resolvedValue(slot: yawSlot)) < 1e-4)
    }

    @Test("No ratchet: engage, move out and back, release ⇒ net ~0")
    func noRatchet() throws {
        var rig = Rig()
        let yawSlot = try #require(rig.layout.slot(for: .cameraOrbitYaw))
        let base = SIMD3<Float>(0, 1, -0.4)
        for _ in 0..<5 {
            rig.warmup(right: rightHand(base: base, gap: 0.01), frames: 20)
            for k in 1...10 {  // out to +0.1
                rig.step(right: rightHand(base: base + SIMD3(0.01 * Float(k), 0, 0), gap: 0.01))
            }
            for k in stride(from: 10, through: 0, by: -1) {  // back to base
                rig.step(right: rightHand(base: base + SIMD3(0.01 * Float(k), 0, 0), gap: 0.01))
            }
            // Settle at base while still engaged (a user stops before letting
            // go) so the joint filter catches up, THEN release. This isolates
            // the accumulator's monotone-release property from filter lag.
            for _ in 0..<15 { rig.step(right: rightHand(base: base, gap: 0.01)) }
            for _ in 0..<10 { rig.step(right: rightHand(base: base, gap: gap(forStrength: 0.1))) }
        }
        for _ in 0..<30 { rig.step() }  // settle
        #expect(abs(rig.mod.resolvedValue(slot: yawSlot)) < 0.02)
    }

    @Test("Suspension: a brief dropout mid-drag resumes without a jump")
    func suspensionResumesCleanly() throws {
        var rig = Rig()
        let yawSlot = try #require(rig.layout.slot(for: .cameraOrbitYaw))
        let base = SIMD3<Float>(0, 1, -0.4)
        rig.warmup(right: rightHand(base: base, gap: 0.01))
        let mid = base + SIMD3<Float>(0.05, 0, 0)
        for _ in 0..<40 { rig.step(right: rightHand(base: mid, gap: 0.01)) }
        let held = rig.mod.resolvedValue(slot: yawSlot)  // ~0.125

        // Drop for 5 frames (< grace 0.2 s ≈ 12 frames): value must hold.
        for _ in 0..<5 { rig.step(right: nil) }
        // Return at the SAME position and continue: no jump on resume.
        for _ in 0..<40 { rig.step(right: rightHand(base: mid, gap: 0.01)) }
        #expect(abs(rig.mod.resolvedValue(slot: yawSlot) - held) < 0.02)
    }

    @Test("NaN mid-drag ends the drag cleanly — no jump, output stays finite")
    func nanMidDragIsClean() throws {
        var rig = Rig()
        let yawSlot = try #require(rig.layout.slot(for: .cameraOrbitYaw))
        let base = SIMD3<Float>(0.2, 1.0, -0.4)
        rig.warmup(right: rightHand(base: base, gap: 0.01))
        let dragged = base + SIMD3<Float>(0.1, 0, 0)
        for _ in 0..<60 { rig.step(right: rightHand(base: dragged, gap: 0.01)) }
        let before = rig.mod.resolvedValue(slot: yawSlot)

        var poisoned = rightHand(base: dragged + SIMD3(5, 5, 5), gap: 0.01)
        poisoned.set(.thumbTip, position: SIMD3(.nan, .nan, .nan))
        for _ in 0..<40 { rig.step(right: poisoned) }
        let after = rig.mod.resolvedValue(slot: yawSlot)
        #expect(after.isFinite)
        #expect(abs(after - before) < 0.02)
    }

    @Test("Entry stability: a pinch present less than the window can't arm")
    func entryStabilityGate() {
        var rig = Rig()
        let hand = rightHand(base: SIMD3(0, 1, -0.4), gap: 0.01)
        rig.step(right: hand)  // one frame: not yet stable
        #expect(rig.hands.armingSnapshot().isEmpty)
        for _ in 0..<20 { rig.step(right: hand) }  // past window
        #expect(!rig.hands.armingSnapshot().isEmpty)
    }
}

// MARK: - Arbitration (Phase 1)

@Suite("HandGestureEngine arbitration")
struct HandGestureArbitrationTests {
    private func armedFingers(_ snap: [GestureSource: Float]) -> Set<GestureFinger> {
        var s = Set<GestureFinger>()
        for (src, _) in snap {
            if case let .tapThumb(_, finger) = src { s.insert(finger) }
        }
        return s
    }

    @Test("Lead gap: a leading finger claims; a coupled runner-up does not")
    func leadGapWinnerTakesAll() {
        var rig = Rig()
        let base = SIMD3<Float>(0, 1, -0.4)
        // Middle leads ring by 0.9 - 0.72 = 0.18 ≥ leadGap(0.15). Index low so
        // the camera/index source stays out of it.
        let hand = rightHand(
            base: base, pinches: [.index: 0.1, .middle: 0.9, .ring: 0.72])
        for _ in 0..<20 { rig.step(right: hand) }
        let armed = armedFingers(rig.hands.armingSnapshot())
        #expect(armed.contains(.middle))
        #expect(!armed.contains(.ring))
    }

    @Test("Ambiguous coupling: two near-equal fingers ⇒ neither claims")
    func ambiguousCouplingBlocks() {
        var rig = Rig()
        let base = SIMD3<Float>(0, 1, -0.4)
        // Middle and ring both 0.85 (within leadGap): block both.
        let hand = rightHand(
            base: base, pinches: [.index: 0.1, .middle: 0.85, .ring: 0.85])
        for _ in 0..<20 { rig.step(right: hand) }
        let armed = armedFingers(rig.hands.armingSnapshot())
        #expect(!armed.contains(.middle))
        #expect(!armed.contains(.ring))
    }

    @Test("Fist pose suppresses individual taps and emits only the fist drive")
    func fistPoseExclusivity() throws {
        var rig = Rig()
        var table = GestureBindingTable()
        table.setBinding(.scalar(ParamKey("de.t.warpx")), for: .fist(hand: .right))
        // Bind every palm-tap so, if the fist DIDN'T suppress them, they'd write.
        for finger in GestureFinger.allCases {
            table.setBinding(
                .scalar(ParamKey("de.t.warpy")), for: .tapPalm(hand: .right, finger: finger))
        }
        rig.hands.setBindings(table)
        let warpx = try #require(rig.layout.slot(for: ParamKey("de.t.warpx")))
        let warpy = try #require(rig.layout.slot(for: ParamKey("de.t.warpy")))

        // A closed fist: all fingertips near the palm.
        var fist = HandFrame()
        let base = SIMD3<Float>(0, 1, -0.4)
        fist.set(.wrist, position: base)
        fist.set(.palmCenter, position: base)
        fist.set(.thumbTip, position: base + SIMD3(0.01, 0, 0))
        fist.set(.indexTip, position: base + SIMD3(0.01, 0.01, 0))
        fist.set(.middleTip, position: base + SIMD3(0, 0.012, 0))
        fist.set(.ringTip, position: base + SIMD3(-0.01, 0.01, 0))
        fist.set(.littleTip, position: base + SIMD3(-0.012, 0.005, 0))
        for _ in 0..<30 { rig.step(right: fist) }
        // Fist drive fired (warpx moved off 0); palm-taps suppressed (warpy 0).
        #expect(rig.mod.resolvedValue(slot: warpx) > 0.05)
        #expect(rig.mod.resolvedValue(slot: warpy) < 1e-4)
    }
}

// MARK: - Swipe gating (Phase 1) + suppression (Phase 4)

@Suite("HandGestureEngine swipe & suppression")
struct HandGestureSwipeSuppressionTests {
    private func rigBoundToSwipe() throws -> (Rig, Int) {
        var rig = Rig()
        var table = GestureBindingTable()
        table.setBinding(
            .vector(.grouped(x: ParamKey("de.t.warpx"), y: nil, z: nil)),
            for: .swipe(hand: .right))
        rig.hands.setBindings(table)
        let slot = try #require(rig.layout.slot(for: ParamKey("de.t.warpx")))
        return (rig, slot)
    }

    /// Move an OPEN hand at `speed` m/s for a stretch; return peak |Δ| on the
    /// bound param. `pinched` closes the index (a pose that must veto swipe).
    private func sweep(_ rig: inout Rig, slot: Int, speed: Float, pinched: Bool) -> Float {
        var pos = SIMD3<Float>(-0.3, 1, -0.4)
        let baseline = rig.mod.resolvedValue(slot: slot)
        var peak: Float = 0
        for _ in 0..<20 {
            pos.x += speed * Float(rig.clock.step)
            let hand = pinched
                ? rightHand(base: pos, gap: gap(forStrength: 0.9))
                : rightHand(base: pos, gap: gap(forStrength: 0.0))
            let v = rig.step(right: hand).values[slot]
            peak = max(peak, abs(v - baseline))
        }
        return peak
    }

    @Test("Slow open-hand motion produces NO swipe (was: any motion fired)")
    func slowMotionNoSwipe() throws {
        var (rig, slot) = try rigBoundToSwipe()
        rig.warmup(right: rightHand(base: SIMD3(-0.3, 1, -0.4), gap: gap(forStrength: 0)))
        #expect(sweep(&rig, slot: slot, speed: 0.2, pinched: false) < 0.02)  // < floor 0.5 m/s
    }

    @Test("Fast open-hand motion DOES swipe")
    func fastOpenHandSwipes() throws {
        var (rig, slot) = try rigBoundToSwipe()
        rig.warmup(right: rightHand(base: SIMD3(-0.3, 1, -0.4), gap: gap(forStrength: 0)))
        #expect(sweep(&rig, slot: slot, speed: 1.5, pinched: false) > 0.05)
    }

    @Test("Fast motion while pinching does NOT swipe (pose exclusivity)")
    func pinchedFastMotionNoSwipe() throws {
        var (rig, slot) = try rigBoundToSwipe()
        rig.warmup(right: rightHand(base: SIMD3(-0.3, 1, -0.4), gap: 0.01))
        #expect(sweep(&rig, slot: slot, speed: 1.5, pinched: true) < 0.02)
    }

    @Test("Grab-active suppresses skeleton drives (cross-stack arbiter)")
    func grabSuppressesDrives() throws {
        var (rig, slot) = try rigBoundToSwipe()
        rig.grabActive = true
        rig.warmup(right: rightHand(base: SIMD3(-0.3, 1, -0.4), gap: gap(forStrength: 0)))
        #expect(sweep(&rig, slot: slot, speed: 1.5, pinched: false) < 0.02)
    }

    @Test("UI suppression blocks drives until cleared")
    func uiSuppressionBlocks() throws {
        var (rig, slot) = try rigBoundToSwipe()
        rig.hands.setUISuppressed(true)
        rig.warmup(right: rightHand(base: SIMD3(-0.3, 1, -0.4), gap: gap(forStrength: 0)))
        #expect(sweep(&rig, slot: slot, speed: 1.5, pinched: false) < 0.02)
    }
}

// MARK: - Replay determinism

@Suite("HandGestureEngine replay")
struct HandGestureReplayTests {
    @Test("Same corpus ⇒ identical resolve trace")
    func replayIsDeterministic() throws {
        var records: [HandFrameRecord] = []
        var pos = SIMD3<Float>(0.1, 1.0, -0.3)
        for i in 0..<120 {
            let t = Double(i) / 60.0
            switch i {
            case 0..<20: records.append(.init(time: t))
            case 20..<70:
                pos.x += 0.002
                records.append(.init(time: t, right: rightHand(base: pos, gap: 0.01)))
            case 70..<80: records.append(.init(time: t))  // dropout
            default:
                records.append(.init(time: t, right: rightHand(base: pos, gap: 0.05)))
            }
        }
        let corpus = try HandFrameRecord.load(jsonl: HandFrameRecord.dump(records))

        func trace(_ corpus: [HandFrameRecord]) -> [[Float]] {
            var rig = Rig()
            return corpus.map { rig.step(left: $0.left, right: $0.right).values }
        }
        #expect(trace(corpus) == trace(corpus))
    }
}
