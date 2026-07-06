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
}
