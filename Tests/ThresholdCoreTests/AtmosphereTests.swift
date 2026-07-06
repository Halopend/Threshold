import Testing
@testable import ThresholdCore

// Atmosphere (legacy Effects ▸ Static): glow, bloom, fog + fog tint. These
// assert the catalog wiring — the shader behavior is covered by the render
// golden/parity suites (identity when disabled, which is the default).

@Suite("Atmosphere params")
struct AtmosphereTests {

    private var layout: CatalogLayout { Catalog.withEngineDefaults().freeze() }

    @Test func atmosphereParamsLandAtTheirFixedSlots() {
        let layout = layout
        #expect(layout.slot(for: .atmosphereGlowEnabled) == EngineSlot.glowEnabled.rawValue)
        #expect(layout.slot(for: .atmosphereGlowIntensity) == EngineSlot.glowIntensity.rawValue)
        #expect(layout.slot(for: .atmosphereBloomEnabled) == EngineSlot.bloomEnabled.rawValue)
        #expect(layout.slot(for: .atmosphereBloomStrength) == EngineSlot.bloomStrength.rawValue)
        #expect(layout.slot(for: .atmosphereFogEnabled) == EngineSlot.fogEnabled.rawValue)
        #expect(layout.slot(for: .atmosphereFogIntensity) == EngineSlot.fogIntensity.rawValue)
        // Fog tint is a float3 occupying fogColorR..fogColorB.
        #expect(layout.slot(for: .atmosphereFogColor) == EngineSlot.fogColorR.rawValue)
    }

    @Test func atmosphereDefaultsAreDisabled() {
        // Every effect ships OFF so authored/golden scenes are untouched.
        let layout = layout
        func def(_ key: ParamKey) -> Float? { layout.entry(for: key)?.spec.defaultValue.first }
        #expect(def(.atmosphereGlowEnabled) == 0)
        #expect(def(.atmosphereBloomEnabled) == 0)
        #expect(def(.atmosphereFogEnabled) == 0)
    }

    @Test func fogTintSpansThreeContiguousSlots() {
        let layout = layout
        let base = EngineSlot.fogColorR.rawValue
        #expect(base + 2 == EngineSlot.fogColorB.rawValue)
        // The reserved block ends exactly after the fog tint.
        #expect(EngineSlot.fogColorB.rawValue + 1 == EngineSlot.reservedCount)
        #expect(layout.slot(for: .atmosphereFogColor) == base)
    }

    // The LIVE path is catalog → ModulationEngine.resolve → resolved.values →
    // SessionCore maps to EngineParams → shader. The GPU render tests build the
    // param table directly and skip resolve, so these prove the atmosphere
    // params (incl. the float3 fog tint at fixed engine slots — the first such
    // multi-slot engine param) resolve correctly through the real lane engine.

    @Test func atmosphereResolvesToDefaultsThroughTheEngine() {
        let clock = FixedStepClock(step: 0.1)
        let engine = ModulationEngine(
            layout: Catalog.withEngineDefaults().freeze(), clock: clock)
        clock.advance()
        let v = engine.resolve().values
        // Every effect off, intensities at their (inert) defaults.
        #expect(v[EngineSlot.glowEnabled.rawValue] == 0)
        #expect(v[EngineSlot.glowIntensity.rawValue] == 0.3)
        #expect(v[EngineSlot.bloomEnabled.rawValue] == 0)
        #expect(v[EngineSlot.bloomStrength.rawValue] == 0.2)
        #expect(v[EngineSlot.fogEnabled.rawValue] == 0)
        #expect(v[EngineSlot.fogIntensity.rawValue] == 0.32)
        // Fog tint float3 default (dark blue) on its three contiguous slots.
        #expect(abs(v[EngineSlot.fogColorR.rawValue] - 0.01) < 1e-6)
        #expect(abs(v[EngineSlot.fogColorG.rawValue] - 0.015) < 1e-6)
        #expect(abs(v[EngineSlot.fogColorB.rawValue] - 0.02) < 1e-6)
    }

    @Test func fogTintFloat3WritesLandOnAllThreeSlots() {
        let clock = FixedStepClock(step: 0.1)
        let engine = ModulationEngine(
            layout: Catalog.withEngineDefaults().freeze(), clock: clock)
        let base = EngineSlot.fogColorR.rawValue
        // A user edit to each component (as the ColorPicker UI does).
        engine.write(lane: .user, slot: base, value: 0.7)
        engine.write(lane: .user, slot: base + 1, value: 0.4)
        engine.write(lane: .user, slot: base + 2, value: 0.1)
        clock.advance()
        let v = engine.resolve().values
        // .replace composition: the user value wins outright.
        #expect(abs(v[base] - 0.7) < 1e-6)
        #expect(abs(v[base + 1] - 0.4) < 1e-6)
        #expect(abs(v[base + 2] - 0.1) < 1e-6)
    }
}
