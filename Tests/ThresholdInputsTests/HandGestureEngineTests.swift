// HandGestureEngineTests.swift — the HandFrame seam + replay harness
// (adversarial plan Phase 0). Everything ARKit used to hide is now driven
// headlessly: synthesized HandFrames step the engine, writes land in a real
// ModulationEngine through the shared mailbox, and resolve() is the
// observable. Deterministic by construction (FixedStepClock, no randomness).

import Foundation
import simd
import Testing
import ThresholdCore

@testable import ThresholdInputs

// MARK: - Harness

/// Engine + modulation stack on one mailbox: the minimal replay rig.
private struct Rig {
    let layout: CatalogLayout
    let clock: FixedStepClock
    let mod: ModulationEngine
    let hands: HandGestureEngine
    let signals: SignalTable

    init() {
        let catalog = Catalog.withEngineDefaults()
        try! catalog.register(ParamSpec(
            key: ParamKey("de.t.warpx"), label: "Warp.x", range: 0...2, default: 0))
        layout = catalog.freeze()
        clock = FixedStepClock(step: 1.0 / 60.0)
        mod = ModulationEngine(layout: layout, clock: clock)
        signals = SignalTable(ids: SignalID.standardSession)
        hands = HandGestureEngine(
            layout: layout, mailbox: mod.mailbox, signals: signals)
    }

    /// Step one frame: feed hands, tick the clock, resolve.
    @discardableResult
    mutating func step(left: HandFrame? = nil, right: HandFrame? = nil) -> ResolvedParams {
        hands.update(left: left, right: right, sessionTime: clock.now)
        clock.advance()
        return mod.resolve()
    }
}

/// A right hand with thumb/index at a controlled gap, CENTERED on the same
/// midpoint regardless of gap — so opening the pinch to release does not
/// shift the drag midpoint. (Asymmetric release does nudge the latched
/// value in the current engine: a real Phase 1 finding, pinned separately.)
private func rightHand(
    base: SIMD3<Float>, gap: Float
) -> HandFrame {
    var f = HandFrame()
    f.set(.wrist, position: base)
    f.set(.thumbTip, position: base + SIMD3(-gap / 2, 0.05, 0))
    f.set(.indexTip, position: base + SIMD3(gap / 2, 0.05, 0))
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
                time: 0.5,
                left: nil,
                right: rightHand(base: SIMD3(0.1, 1.0, -0.3), gap: 0.01)),
            HandFrameRecord(time: 0.6),
        ]
        let jsonl = try HandFrameRecord.dump(records)
        #expect(jsonl.split(separator: "\n").count == 2)
        let back = try HandFrameRecord.load(jsonl: jsonl)
        #expect(back == records)
    }
}

// MARK: - Engine invariants

@Suite("HandGestureEngine")
struct HandGestureEngineTests {
    @Test("Silence invariant: no hands ⇒ resolve stays at authored defaults")
    func silenceWhenUntracked() {
        var rig = Rig()
        let baseline = rig.step().values
        for _ in 0..<10 {
            let values = rig.step(left: nil, right: nil).values
            #expect(values == baseline)
        }
    }

    @Test("Right-hand pinch-drag orbits yaw; release latches it")
    func pinchDragOrbits() throws {
        var rig = Rig()
        let yawSlot = try #require(rig.layout.slot(for: .cameraOrbitYaw))
        let base = SIMD3<Float>(0.2, 1.0, -0.4)

        // Engage (gap 1 cm < on 1.5 cm), drag +10 cm, hold to converge.
        rig.step(right: rightHand(base: base, gap: 0.01))
        let dragged = base + SIMD3<Float>(0.1, 0, 0)
        for _ in 0..<60 { rig.step(right: rightHand(base: dragged, gap: 0.01)) }
        // 0.1 m · 2.5 rad/m = 0.25 rad.
        #expect(abs(rig.mod.resolvedValue(slot: yawSlot) - 0.25) < 0.01)

        // Open past the release distance (4 cm > off 3.5 cm): latched.
        for _ in 0..<60 { rig.step(right: rightHand(base: dragged, gap: 0.04)) }
        #expect(abs(rig.mod.resolvedValue(slot: yawSlot) - 0.25) < 0.01)
    }

    @Test("NaN mid-drag ends the drag cleanly — no jump, output stays finite")
    func nanMidDragIsClean() throws {
        var rig = Rig()
        let yawSlot = try #require(rig.layout.slot(for: .cameraOrbitYaw))
        let base = SIMD3<Float>(0.2, 1.0, -0.4)

        rig.step(right: rightHand(base: base, gap: 0.01))
        let dragged = base + SIMD3<Float>(0.1, 0, 0)
        for _ in 0..<60 { rig.step(right: rightHand(base: dragged, gap: 0.01)) }
        let before = rig.mod.resolvedValue(slot: yawSlot)

        // Thumb goes NaN with the hand still "tracked": the gated read makes
        // this indistinguishable from occlusion — the drag must end where it
        // was, not integrate garbage.
        var poisoned = rightHand(base: dragged + SIMD3(5, 5, 5), gap: 0.01)
        poisoned.set(.thumbTip, position: SIMD3(.nan, .nan, .nan))
        for _ in 0..<30 { rig.step(right: poisoned) }
        let after = rig.mod.resolvedValue(slot: yawSlot)
        #expect(after.isFinite)
        #expect(abs(after - before) < 0.01)
    }

    @Test("Swipe drive reaches a bound param (documents the ungated feed)")
    func swipeDrivesBoundParam() throws {
        var rig = Rig()
        var table = GestureBindingTable()
        table.setBinding(
            .vector(.grouped(x: ParamKey("de.t.warpx"), y: nil, z: nil)),
            for: .swipe(hand: .right))
        rig.hands.setBindings(table)
        let slot = try #require(rig.layout.slot(for: ParamKey("de.t.warpx")))
        let baseline = rig.mod.resolvedValue(slot: slot)

        // Plain wrist motion with the hand fully OPEN (10 cm gap — no pinch),
        // and the bound param still moves. This is the Phase 1 target: swipe
        // must become a gated event. The test pins today's behavior so the
        // fix shows up as an intentional expectation change.
        var pos = SIMD3<Float>(0, 1, -0.4)
        var moved = false
        for _ in 0..<30 {
            pos.x += 0.05  // 3 m/s at 60 Hz
            let v = rig.step(right: rightHand(base: pos, gap: 0.1)).values[slot]
            moved = moved || abs(v - baseline) > 0.05
        }
        #expect(moved)
    }

    @Test("Replay determinism: same corpus ⇒ identical resolve trace")
    func replayIsDeterministic() throws {
        // Synthesize a mixed corpus: engage, drag, occlusion dropout, release.
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
        // Round-trip through JSONL so the corpus format itself is under test.
        let corpus = try HandFrameRecord.load(jsonl: HandFrameRecord.dump(records))

        func trace(_ corpus: [HandFrameRecord]) -> [[Float]] {
            var rig = Rig()
            return corpus.map { rec in
                rig.step(left: rec.left, right: rec.right).values
            }
        }
        #expect(trace(corpus) == trace(corpus))
    }
}
