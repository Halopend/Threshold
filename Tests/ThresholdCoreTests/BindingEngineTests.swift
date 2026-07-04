// BindingEngineTests.swift — signal→lane binding execution (plan §4.2, §3.2):
// freshness, mapping/scale/deadzone/curves, momentary vs latched staleness,
// lane restrictions, slot resolution (vector components, unknown keys).

import Testing

@testable import ThresholdCore

@Suite("BindingEngine")
struct BindingEngineTests {
    static let sig = SignalID("test.level")

    /// One scalar param "b.a" (default 10, additive, instant smoothing) at
    /// the first content slot, plus the pieces around it.
    private func makeWorld(
        specs: [ParamSpec]? = nil,
        step: Double = 1.0 / 60.0
    ) throws -> (clock: FixedStepClock, engine: ModulationEngine, table: SignalTable, binder: BindingEngine) {
        let clock = FixedStepClock(step: step)
        let engine = try makeEngine(specs ?? [spec("b.a", default: 10)], clock: clock)
        let table = SignalTable(ids: [Self.sig])
        let binder = BindingEngine(layout: engine.layout)
        return (clock, engine, table, binder)
    }

    // MARK: Fresh writes

    @Test("Fresh signal writes the mapped value to the music lane")
    func freshSignalWritesMusicLane() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .music)
        ]

        table.publish(id: Self.sig, value: SIMD4(0.5, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0.016)  // fresh: 16 ms old
        clock.advance()
        let resolved = engine.resolve()

        #expect(engine.currentValue(lane: .music, slot: firstContentSlot) == 0.5)
        #expect(abs(resolved.values[firstContentSlot] - 10.5) < 1e-6)  // base 10 + music 0.5
        #expect(binder.lastSkippedCount == 0)
    }

    @Test("Zero-confidence signal is stale even with a recent timestamp")
    func zeroConfidenceIsStale() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .music)
        ]

        table.publish(id: Self.sig, value: SIMD4(0.5, 0, 0, 0), confidence: 0, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0.0)
        clock.advance()
        let resolved = engine.resolve()

        #expect(engine.currentValue(lane: .music, slot: firstContentSlot) == nil)
        #expect(abs(resolved.values[firstContentSlot] - 10) < 1e-6)
    }

    // MARK: Mapping: scale, deadzone, curves

    @Test("Scale multiplies the mapped value")
    func scaleHonored() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .music, scale: 2)
        ]

        table.publish(id: Self.sig, value: SIMD4(0.5, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)
        clock.advance()
        _ = engine.resolve()

        #expect(engine.currentValue(lane: .music, slot: firstContentSlot) == 1.0)  // 0.5 mapped × 2
    }

    @Test("Deadzone gates raw input below the floor to the mapping's zero")
    func deadzoneHonored() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(
                signal: Self.sig, param: ParamKey("b.a"), lane: .music,
                mapping: SignalMapping(deadzone: 0.2))
        ]

        // Below the deadzone → treated as 0 → mapped output 0.
        table.publish(id: Self.sig, value: SIMD4(0.1, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 10) < 1e-6)
        #expect(engine.currentValue(lane: .music, slot: firstContentSlot) == 0)

        // Above the deadzone → passes through.
        table.publish(id: Self.sig, value: SIMD4(0.6, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)
        clock.advance()
        _ = engine.resolve()
        #expect(engine.currentValue(lane: .music, slot: firstContentSlot) == 0.6)
    }

    @Test("Pulse curve gates at its threshold")
    func pulseCurveGates() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(
                signal: Self.sig, param: ParamKey("b.a"), lane: .music,
                mapping: SignalMapping(curve: .pulse(threshold: 0.6)))
        ]

        table.publish(id: Self.sig, value: SIMD4(0.5, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)
        clock.advance()
        _ = engine.resolve()
        #expect(engine.currentValue(lane: .music, slot: firstContentSlot) == 0)  // below threshold

        table.publish(id: Self.sig, value: SIMD4(0.7, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)
        clock.advance()
        _ = engine.resolve()
        #expect(engine.currentValue(lane: .music, slot: firstContentSlot) == 1)  // gated on
    }

    @Test("Non-finite mapped values are never written")
    func nonFiniteMappedValueDropped() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(
                signal: Self.sig, param: ParamKey("b.a"), lane: .music,
                scale: .infinity)  // finite signal × infinite scale → non-finite
        ]

        table.publish(id: Self.sig, value: SIMD4(0.5, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)
        clock.advance()
        let resolved = engine.resolve()

        #expect(engine.currentValue(lane: .music, slot: firstContentSlot) == nil)
        #expect(resolved.values[firstContentSlot] == 10)
    }

    // MARK: Staleness policy

    @Test("Momentary clears the gesture lane when the signal goes stale — once")
    func momentaryClearsGestureWhenStale() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(
                signal: Self.sig, param: ParamKey("b.a"), lane: .gesture,
                policy: .momentary)
        ]

        table.publish(id: Self.sig, value: SIMD4(1, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0.1)  // fresh (0.1 <= 0.25)
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 11) < 1e-6)

        // Stale (0.5 s since publish > staleAfter 0.25): cleared.
        binder.apply(signals: table, engine: engine, now: 0.5)
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 10) < 1e-6)
        #expect(engine.currentValue(lane: .gesture, slot: firstContentSlot) == nil)

        // The clear fires ONCE per stale episode: a later write to the same
        // slot by someone else survives further stale applies.
        engine.write(lane: .gesture, slot: firstContentSlot, value: 7)
        binder.apply(signals: table, engine: engine, now: 1.0)  // still stale
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 17) < 1e-6)

        // Fresh again re-arms the clear.
        table.publish(id: Self.sig, value: SIMD4(1, 0, 0, 0), confidence: 1, timestamp: 2.0)
        binder.apply(signals: table, engine: engine, now: 2.0)
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 11) < 1e-6)
        binder.apply(signals: table, engine: engine, now: 3.0)  // stale again
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 10) < 1e-6)
    }

    @Test("Latched holds the last written gesture value after the signal goes stale")
    func latchedHoldsWhenStale() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(
                signal: Self.sig, param: ParamKey("b.a"), lane: .gesture,
                policy: .latched)
        ]

        table.publish(id: Self.sig, value: SIMD4(1, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0.1)
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 11) < 1e-6)

        // Long stale: the value holds until re-grabbed or cleared.
        for now in [0.5, 1.0, 5.0] {
            binder.apply(signals: table, engine: engine, now: now)
            clock.advance()
            #expect(abs(engine.resolve().values[firstContentSlot] - 11) < 1e-6)
        }
        #expect(engine.currentValue(lane: .gesture, slot: firstContentSlot) == 1)
    }

    @Test("staleAfter is settable and respected")
    func staleAfterSettable() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.staleAfter = 1.0
        binder.bindings = [
            Binding(
                signal: Self.sig, param: ParamKey("b.a"), lane: .gesture,
                policy: .momentary)
        ]

        table.publish(id: Self.sig, value: SIMD4(1, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0.9)  // fresh under 1.0 s window
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 11) < 1e-6)

        binder.apply(signals: table, engine: engine, now: 1.5)  // now stale
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 10) < 1e-6)
    }

    // MARK: Lane restrictions & slot resolution

    @Test("Non-transient lanes in a Binding are skipped and counted")
    func nonTransientLanesRejected() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .scene),
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .user),
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .animation),
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .system),
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .music),  // the one valid binding
        ]
        #expect(binder.lastSkippedCount == 4)  // counted at assignment

        table.publish(id: Self.sig, value: SIMD4(0.5, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)
        #expect(binder.lastSkippedCount == 4)
        clock.advance()
        let resolved = engine.resolve()

        // Only the music write landed; no other lane was touched.
        #expect(abs(resolved.values[firstContentSlot] - 10.5) < 1e-6)
        for lane in [Lane.scene, .animation, .system, .user, .gesture] {
            #expect(engine.currentValue(lane: lane, slot: firstContentSlot) == nil)
        }
    }

    @Test("Vector component addressing writes the correct slot")
    func vectorComponentAddressing() throws {
        let (clock, engine, table, binder) = try makeWorld(
            specs: [spec("b.v", default: 0, kind: .float3)])
        // b.v spans the first three content slots; component 1 → the second.
        // Component 3 is out of range for a float3 → skipped.
        binder.bindings = [
            Binding(signal: Self.sig, param: ParamKey("b.v"), component: 1, lane: .music),
            Binding(signal: Self.sig, param: ParamKey("b.v"), component: 3, lane: .music),
        ]
        #expect(binder.lastSkippedCount == 1)

        table.publish(id: Self.sig, value: SIMD4(0.5, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)
        clock.advance()
        let resolved = engine.resolve()

        #expect(resolved.values[firstContentSlot] == 0)
        #expect(abs(resolved.values[firstContentSlot + 1] - 0.5) < 1e-6)
        #expect(resolved.values[firstContentSlot + 2] == 0)
        #expect(engine.currentValue(lane: .music, slot: firstContentSlot) == nil)
        #expect(engine.currentValue(lane: .music, slot: firstContentSlot + 1) == 0.5)
        #expect(engine.currentValue(lane: .music, slot: firstContentSlot + 2) == nil)
    }

    @Test("Unknown ParamKey is skipped without crashing")
    func unknownParamKeySkipped() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(signal: Self.sig, param: ParamKey("no.such.param"), lane: .music),
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .music),
        ]
        #expect(binder.lastSkippedCount == 1)

        table.publish(id: Self.sig, value: SIMD4(0.5, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)  // must not crash
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 10.5) < 1e-6)
    }

    @Test("A signal missing from the table behaves as permanently stale")
    func unregisteredSignalIsStale() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(
                signal: SignalID("not.registered"), param: ParamKey("b.a"),
                lane: .gesture, policy: .momentary)
        ]
        #expect(binder.lastSkippedCount == 0)  // structurally valid

        binder.apply(signals: table, engine: engine, now: 0)  // no crash, no write
        clock.advance()
        #expect(engine.resolve().values[firstContentSlot] == 10)
        #expect(engine.currentValue(lane: .gesture, slot: firstContentSlot) == nil)
    }

    @Test("Replacing the bindings array rebuilds the cache")
    func bindingReplacementRebuildsCache() throws {
        let (clock, engine, table, binder) = try makeWorld()
        binder.bindings = [
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .scene)  // skipped
        ]
        #expect(binder.lastSkippedCount == 1)

        binder.bindings = [
            Binding(signal: Self.sig, param: ParamKey("b.a"), lane: .music)
        ]
        #expect(binder.lastSkippedCount == 0)

        table.publish(id: Self.sig, value: SIMD4(0.25, 0, 0, 0), confidence: 1, timestamp: 0)
        binder.apply(signals: table, engine: engine, now: 0)
        clock.advance()
        #expect(abs(engine.resolve().values[firstContentSlot] - 10.25) < 1e-6)
    }
}
