// DEParamEditModulationTests.swift — isolate the DE-shape-param slider edit at
// the modulation layer (no GPU / session / render thread). The live slider
// test showed engine params (replace/multiplicative) move but a DE param
// (additive) did not; this pins whether the modulation engine is the cause.

import Testing
import ThresholdCore
import ThresholdShaderIR

@Suite("DE shape param edits at the modulation layer")
struct DEParamEditModulationTests {
    private func makeEngine() throws -> (ModulationEngine, CatalogLayout, FixedStepClock) {
        let catalog = Catalog.withEngineDefaults()
        for descriptor in DERegistry.builtin {
            _ = try descriptor.registerParams(into: catalog)
        }
        let layout = catalog.freeze()
        let clock = FixedStepClock(step: 1.0 / 60.0)
        let engine = ModulationEngine(layout: layout, clock: clock)
        return (engine, layout, clock)
    }

    /// The commit path a slider release runs: scene-lane write of the inverted
    /// target, then clear the momentary user lane.
    private func commit(_ engine: ModulationEngine, slot: Int, target: Float) {
        engine.write(
            lane: .scene, slot: slot,
            value: Inversion.sceneLaneValue(toAchieve: target, slot: slot, in: engine))
        engine.clearLane(.user, slot: slot)
    }

    @Test func mandelbulbPowerCommitMovesResolvedValue() throws {
        let (engine, layout, clock) = try makeEngine()
        let slot = try #require(layout.slot(for: .de("mandelbulb", "power")))

        clock.advance()
        let before = engine.resolve().values[slot]
        #expect(abs(before - 8.0) < 1e-4, "power default is 8.0, got \(before)")

        commit(engine, slot: slot, target: 8.3)
        clock.advance()
        let after = engine.resolve().values[slot]
        #expect(abs(after - 8.3) < 1e-4,
                "committing 8.3 to mandelbulb power should resolve to 8.3, got \(after)")
    }

    @Test func mandelboxScaleCommitMovesResolvedValue() throws {
        let (engine, layout, clock) = try makeEngine()
        let slot = try #require(layout.slot(for: .de("mandelbox", "scale")))

        clock.advance()
        _ = engine.resolve()
        commit(engine, slot: slot, target: 3.1)
        clock.advance()
        let after = engine.resolve().values[slot]
        #expect(abs(after - 3.1) < 1e-4,
                "committing 3.1 to mandelbox scale should resolve to 3.1, got \(after)")
    }

    /// The live-drag path (before release): user-lane write of the inverted
    /// target must also land the resolved value.
    @Test func mandelbulbPowerLiveUserEditMovesResolvedValue() throws {
        let (engine, layout, clock) = try makeEngine()
        let slot = try #require(layout.slot(for: .de("mandelbulb", "power")))
        clock.advance()
        _ = engine.resolve()

        engine.write(
            lane: .user, slot: slot,
            value: Inversion.userLaneValue(toAchieve: 5.0, slot: slot, in: engine))
        clock.advance()
        let after = engine.resolve().values[slot]
        #expect(abs(after - 5.0) < 1e-4,
                "a live user edit to 5.0 should resolve to 5.0, got \(after)")
    }
}
