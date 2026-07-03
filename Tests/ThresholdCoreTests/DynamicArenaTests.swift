// DynamicArenaTests.swift — runtime registration into the catalog's dynamic
// arena (Catalog.freeze doc; build order phase 9: external DE params get
// sliders/bindings like built-ins). Covers the allocator and the engine's
// registerDynamic/unregisterDynamic recycle contract.

import Testing
import ThresholdCore

@Suite("Arena allocator")
struct ArenaAllocatorTests {
    @Test func allocatesConsecutiveRangesAndExhausts() {
        var arena = ArenaAllocator(range: 100..<108)
        #expect(arena.allocate(3) == 100..<103)
        #expect(arena.allocate(5) == 103..<108)
        #expect(arena.allocate(1) == nil, "exhausted")
        #expect(arena.allocated == 100..<108)
    }

    @Test func zeroCountAllocationIsEmptyNotNil() {
        var arena = ArenaAllocator(range: 10..<10)
        #expect(arena.allocate(0) == 10..<10)
        #expect(arena.allocate(1) == nil)
    }

    @Test func resetRecyclesFromTheStart() {
        var arena = ArenaAllocator(range: 0..<4)
        _ = arena.allocate(4)
        arena.reset()
        #expect(arena.allocated.isEmpty)
        #expect(arena.allocate(2) == 0..<2)
    }
}

@Suite("Engine dynamic registration")
struct EngineDynamicRegistrationTests {
    private static func makeEngine(arenaSlots: Int = 8) -> (ModulationEngine, FixedStepClock, CatalogLayout) {
        let catalog = Catalog.withEngineDefaults()
        let layout = catalog.freeze(dynamicArenaSlots: arenaSlots)
        let clock = FixedStepClock()
        return (ModulationEngine(layout: layout, clock: clock), clock, layout)
    }

    private static func dynSpec(_ key: String, range: ClosedRange<Float> = -2...2,
                                default def: Float = 0.5) -> ParamSpec {
        ParamSpec(key: ParamKey(key), label: key, range: range, default: def,
                  composition: .additive, smoothing: .instant,
                  persistence: .scene, group: .shape)
    }

    @Test func unregisteredArenaSlotResolvesToZero() {
        let (engine, clock, layout) = Self.makeEngine()
        clock.advance()
        let slot = layout.arenaRange.lowerBound
        #expect(engine.resolve().values[slot] == 0)
    }

    @Test func registeredSlotResolvesDefaultAndClampsWrites() {
        let (engine, clock, layout) = Self.makeEngine()
        let slot = layout.arenaRange.lowerBound
        engine.registerDynamic(Self.dynSpec("dyn.a"), atSlot: slot)
        clock.advance()
        #expect(engine.resolve().values[slot] == 0.5, "default with no lane values")

        engine.write(lane: .user, slot: slot, value: 100)
        clock.advance()
        #expect(engine.resolve().values[slot] == 2, "single clamp site applies to arena slots")
    }

    @Test func unregisterClearsLaneStateSoRecycledSlotStartsClean() {
        let (engine, clock, layout) = Self.makeEngine()
        let slot = layout.arenaRange.lowerBound
        engine.registerDynamic(Self.dynSpec("dyn.a"), atSlot: slot)
        engine.write(lane: .user, slot: slot, value: 1.5)
        engine.write(lane: .music, slot: slot, value: 0.25)
        clock.advance()
        _ = engine.resolve()

        engine.unregisterDynamic(slots: slot..<(slot + 1))
        clock.advance()
        #expect(engine.resolve().values[slot] == 0, "unregistered again")
        #expect(engine.currentValue(lane: .user, slot: slot) == nil,
                "recycling must not leak the previous occupant's lane values")

        // Re-register with a DIFFERENT spec: fresh default, no ghost offsets.
        engine.registerDynamic(Self.dynSpec("dyn.b", range: 0...10, default: 3), atSlot: slot)
        clock.advance()
        #expect(engine.resolve().values[slot] == 3)
    }

    @Test func sceneLaneWriteOnDynamicSlotComposesLikeStatic() {
        let (engine, clock, layout) = Self.makeEngine()
        let slot = layout.arenaRange.lowerBound
        engine.registerDynamic(Self.dynSpec("dyn.a"), atSlot: slot)
        engine.write(lane: .scene, slot: slot, value: 1)
        engine.write(lane: .user, slot: slot, value: 0.25)
        clock.advance()
        #expect(engine.resolve().values[slot] == 1.25, "scene base + additive user offset")
    }
}
