// CatalogTests.swift — slot assignment, engine reservation, arena, errors.

import Testing
@testable import ThresholdCore

@Suite("Catalog & layout")
struct CatalogTests {
    @Test("EngineSlot raw values match the documented ABI slots")
    func engineSlotValues() {
        // The authoritative cross-check against THRESH_SLOT_* lives in a
        // target that can import ThresholdShaderABI; this pins the Core-side
        // values so a drift there fails HERE too.
        #expect(EngineSlot.maxSteps.rawValue == 0)
        #expect(EngineSlot.maxDist.rawValue == 1)
        #expect(EngineSlot.stepSafety.rawValue == 2)
        #expect(EngineSlot.iterations.rawValue == 3)
        #expect(EngineSlot.aoStrength.rawValue == 4)
        #expect(EngineSlot.shadowSoft.rawValue == 5)
        // Atmosphere (legacy Effects ▸ Static) extended the reserved block
        // from 20 → 29 (glow ×2, bloom ×2, fog ×2 + float3 tint).
        #expect(EngineSlot.reservedCount == 29)
        #expect(EngineSlot.fogColorB.rawValue == 28)
    }

    @Test("withEngineDefaults registers the six engine params at fixed slots with march defaults")
    func engineDefaults() {
        let layout = Catalog.withEngineDefaults().freeze()

        let expected: [(ParamKey, Int, Float)] = [
            (.engineMaxSteps, 0, 256),
            (.engineMaxDist, 1, 64.0),
            (.engineStepSafety, 2, 0.9),
            (.engineIterations, 3, 12),
            (.engineAOStrength, 4, 0.5),
            (.engineShadowSoft, 5, 8.0),
        ]
        for (key, slot, def) in expected {
            let entry = layout.entry(for: key)
            #expect(entry?.slot == slot, "\(key)")
            #expect(entry?.spec.defaultValue == [def], "\(key)")
        }

        // A fresh engine resolves the march defaults with zero writes.
        let engine = ModulationEngine(layout: layout, clock: FixedStepClock())
        let values = engine.resolve().values
        #expect(values[0] == 256 && values[1] == 64 && values[2] == 0.9)
        #expect(values[3] == 12 && values[4] == 0.5 && values[5] == 8)
    }

    @Test("Normal registration starts at the first content slot even with no engine params")
    func registrationStartsAtFirstContentSlot() throws {
        let catalog = Catalog()
        let slot = try catalog.register(spec("t.first"))
        #expect(slot == EngineSlot.reservedCount)
    }

    @Test("Slots are dense, in registration order; vectors span consecutive slots")
    func denseSlotAssignment() throws {
        let catalog = Catalog.withEngineDefaults()
        let a = try catalog.register(spec("t.scalar1"))
        let b = try catalog.register(spec("t.vec3", kind: .float3))
        let c = try catalog.register(spec("t.vec4", kind: .float4))
        let d = try catalog.register(spec("t.scalar2"))

        // withEngineDefaults registers scale (firstContentSlot..+1) + camera
        // rig (firstContentSlot+2..+4) params first, so five content slots are
        // taken before t.scalar1.
        #expect(a == firstContentSlot + 5)
        #expect(b == firstContentSlot + 6)  // +6, +7, +8
        #expect(c == firstContentSlot + 9)  // +9, +10, +11, +12
        #expect(d == firstContentSlot + 13)

        let layout = catalog.freeze(dynamicArenaSlots: 0)
        #expect(layout.entry(for: ParamKey("t.vec3"))?.slotRange == (firstContentSlot + 6)..<(firstContentSlot + 9))
        #expect(layout.entry(for: ParamKey("t.vec4"))?.slotRange == (firstContentSlot + 9)..<(firstContentSlot + 13))
        #expect(layout.slotCount == firstContentSlot + 14)
    }

    @Test("freeze appends the dynamic arena after the static slots")
    func arenaRange() throws {
        let catalog = Catalog()
        try catalog.register(spec("t.a"))
        try catalog.register(spec("t.v", kind: .float3))
        // Static slots: firstContentSlot, firstContentSlot+1..+3 → static
        // count firstContentSlot + 4.
        let layout = catalog.freeze(dynamicArenaSlots: 32)
        #expect(layout.arenaRange == (firstContentSlot + 4)..<(firstContentSlot + 4 + 32))
        #expect(layout.slotCount == firstContentSlot + 4 + 32)

        let defaultLayout = catalog.freeze()  // default arena is 256
        #expect(defaultLayout.arenaRange.count == 256)
        #expect(defaultLayout.slotCount == firstContentSlot + 4 + 256)
    }

    @Test("Duplicate key registration throws")
    func duplicateKeyThrows() throws {
        let catalog = Catalog()
        try catalog.register(spec("t.dup"))
        #expect(throws: CatalogError.duplicateKey(ParamKey("t.dup"))) {
            try catalog.register(spec("t.dup"))
        }
        // Also across register/registerEngine.
        #expect(throws: CatalogError.duplicateKey(ParamKey("t.dup"))) {
            try catalog.registerEngine(
                ParamSpec(key: ParamKey("t.dup"), label: "x", range: 0...1, default: 0),
                atSlot: 7)
        }
    }

    @Test("Occupied engine slot throws")
    func engineSlotOccupiedThrows() throws {
        let catalog = Catalog()
        try catalog.registerEngine(
            ParamSpec(key: ParamKey("e.a"), label: "a", range: 0...1, default: 0), atSlot: 3)
        #expect(throws: CatalogError.engineSlotOccupied(3)) {
            try catalog.registerEngine(
                ParamSpec(key: ParamKey("e.b"), label: "b", range: 0...1, default: 0), atSlot: 3)
        }
    }

    @Test("Layout lookup by key")
    func lookupByKey() throws {
        let catalog = Catalog.withEngineDefaults()
        try catalog.register(spec("t.x"))
        let layout = catalog.freeze()
        // Scale (firstContentSlot..+1) + camera rig (firstContentSlot+2..+4)
        // params occupy the front of the content range, so t.x lands at
        // firstContentSlot + 5.
        #expect(layout.slot(for: ParamKey("t.x")) == firstContentSlot + 5)
        #expect(layout.slot(for: .engineStepSafety) == 2)
        #expect(layout.slot(for: ParamKey("t.missing")) == nil)
        #expect(layout.entry(for: ParamKey("t.x"))?.kind == .float)
    }

    @Test("ParamKey factories produce the documented formats (Invariant 14)")
    func paramKeyFactories() {
        #expect(ParamKey.warp(slot: 3, field: "strength").rawValue == "warp.slot3.strength")
        #expect(ParamKey.warp(slot: 0, field: "a.x").rawValue == "warp.slot0.a.x")
        #expect(ParamKey.de("mandelbox", "scale").rawValue == "de.mandelbox.scale")
    }

    @Test("ParamKind slot widths")
    func slotWidths() {
        #expect(ParamKind.float.slotWidth == 1)
        #expect(ParamKind.bool.slotWidth == 1)
        #expect(ParamKind.enumeration(caseCount: 5).slotWidth == 1)
        #expect(ParamKind.float3.slotWidth == 3)
        #expect(ParamKind.float4.slotWidth == 4)
    }
}
