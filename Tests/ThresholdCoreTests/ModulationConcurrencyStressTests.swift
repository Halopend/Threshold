// ModulationConcurrencyStressTests.swift — the app's REAL threading shape,
// maximally concurrent, as a regression net for the live Bitset-storage
// crashes (musicWritten.removeAll / resolve-iteration EXC_BAD_ACCESS): the
// engine confined to ONE worker thread exactly like the render thread, while
// producer threads hammer the two legal cross-thread channels (LaneMailbox,
// SignalTable) and the worker churns every per-slot Bitset the engine owns —
// music writes + decay, full/slot lane clears, scene-clear scheduling, and
// dynamic-arena register/unregister recycling.
//
// Run it under the sanitizers when hunting: any illegal sharing or stomp in
// this wiring shape flags here instead of corrupting a live session.
//   swift test --sanitize thread  --filter ModulationConcurrencyStress
//   swift test --sanitize address --filter ModulationConcurrencyStress
//
// NOTE: producers publish only IN-RANGE slots — the drain/Bitset guards
// assert on out-of-range in debug (the loud-alarm contract), so garbage-slot
// behavior is a release-mode property and is not exercised here.

import Dispatch
import Foundation
import Testing
import ThresholdCore

@Suite("Modulation concurrency stress", .serialized)
struct ModulationConcurrencyStressTests {

    private static func dynSpec(_ key: String) -> ParamSpec {
        ParamSpec(key: ParamKey(key), label: key, range: -2...2, default: 0.5,
                  composition: .additive, smoothing: .instant,
                  persistence: .scene, group: .shape)
    }

    @Test func legalChannelsSurviveAConcurrentStorm() {
        let catalog = Catalog.withEngineDefaults()
        let layout = catalog.freeze(dynamicArenaSlots: 8)
        let mailbox = LaneMailbox()
        let signals = SignalTable(ids: SignalID.standardSession)
        let slotCount = layout.slotCount
        let frames = 3000

        let group = DispatchGroup()
        let stop = DispatchSemaphore(value: 0)

        // Producers: the ONLY legal cross-thread ingress — mailbox lane
        // writes (all lanes, valid slots, finite and non-finite values: the
        // engine drops non-finite at ingress by contract) and signal-table
        // publishes (the seqlock next door to everything).
        for producer in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                var seed = UInt64(0x9E3779B97F4A7C15 &* UInt64(producer + 1))
                func next() -> UInt64 {
                    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                    return seed
                }
                let lanes = Lane.allCases
                while stop.wait(timeout: .now()) == .timedOut {
                    for _ in 0..<64 {
                        let lane = lanes[Int(next() % UInt64(lanes.count))]
                        let slot = Int(next() % UInt64(slotCount))
                        let raw = Float(bitPattern: UInt32(truncatingIfNeeded: next()))
                        let value = next() % 13 == 0 ? raw  // occasionally NaN/inf
                            : Float(next() % 4000) / 1000 - 2
                        mailbox.publish(LaneWrite(lane: lane, slot: slot, value: value))
                    }
                }
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            var t = 0.0
            let ids = signals.registeredIDs
            while stop.wait(timeout: .now()) == .timedOut {
                for id in ids {
                    signals.publish(
                        id: id, value: SIMD4(Float(t.truncatingRemainder(dividingBy: 2)), 0, 0, 0),
                        confidence: 1, timestamp: t)
                }
                t += 0.011
            }
        }

        // The "render thread": engine born here, touched only here — the
        // ADR-004 confinement contract. Churn every Bitset the engine owns.
        let clock = FixedStepClock()
        let engine = ModulationEngine(layout: layout, clock: clock, mailbox: mailbox)
        let arenaSlot = layout.arenaRange.lowerBound
        var registered = false
        var finiteFailures = 0

        for frame in 0..<frames {
            clock.advance()
            // Direct render-thread music writes (what BindingEngine does).
            engine.write(lane: .music, slot: frame % slotCount, value: 0.4)
            engine.write(lane: .music, slot: (frame * 7) % slotCount, value: -0.2)
            if frame % 37 == 0 { engine.clearLane(.music) }
            if frame % 53 == 0 { engine.clearLane(.gesture, slot: frame % slotCount) }
            if frame % 61 == 0 { engine.scheduleSceneClear(slot: frame % slotCount) }
            if frame % 101 == 0 {
                if registered {
                    engine.unregisterDynamic(slots: arenaSlot..<(arenaSlot + 1))
                } else {
                    engine.registerDynamic(Self.dynSpec("stress.dyn"), atSlot: arenaSlot)
                }
                registered.toggle()
            }
            let resolved = engine.resolve()
            if frame % 250 == 0 {
                for v in resolved.values where !v.isFinite { finiteFailures += 1 }
            }
        }

        stop.signal(); stop.signal(); stop.signal(); stop.signal()
        _ = group.wait(timeout: .now() + 10)

        #expect(finiteFailures == 0, "non-finite resolved values leaked through")
        // One final quiet frame: music decays/clears without incident.
        clock.advance()
        engine.clearLane(.music)
        let final = engine.resolve()
        #expect(final.values.count == slotCount)
    }
}
