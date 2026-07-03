// ScaleContextTests.swift — the zoom/scale derivation site (plan §6.3,
// phase 10 part 1): octave→modelScale math, catalog registration, and the
// zoom integrator (scale.zoomSpeed rate → scale.zoom phase).

import Testing
import ThresholdCore

@Suite("Scale context")
struct ScaleContextTests {
    @Test func modelScaleIsExp2OfNegativeZoom() {
        #expect(ScaleContext(zoomOctaves: 0).modelScale == 1)
        #expect(ScaleContext(zoomOctaves: 1).modelScale == 0.5, "zoom in shrinks model space")
        #expect(ScaleContext(zoomOctaves: -2).modelScale == 4, "zoom out grows it")
        #expect(ScaleContext(zoomOctaves: 0).octave == 0, "octave rebase is phase 2")
    }

    @Test func engineDefaultsRegisterZoomParams() {
        let layout = Catalog.withEngineDefaults().freeze()
        let zoom = try! #require(layout.entry(for: .scaleZoom))
        let speed = try! #require(layout.entry(for: .scaleZoomSpeed))
        #expect(zoom.spec.integratorRateKey == .scaleZoomSpeed)
        #expect(zoom.spec.persistence == .transient,
                "phase persists via integratorPhases, not the params walk")
        #expect(speed.spec.defaultValue == [0], "stationary by default")
        #expect(speed.spec.capabilities.contains(.musicBindable),
                "Infinite Zoom speed is bindable for free (plan §12.8)")
    }

    @Test func zoomSpeedIntegratesIntoZoomPhase() {
        let layout = Catalog.withEngineDefaults().freeze()
        let clock = FixedStepClock(step: 0.25)
        let engine = ModulationEngine(layout: layout, clock: clock)
        let zoomSlot = layout.slot(for: .scaleZoom)!

        clock.advance()
        #expect(engine.resolve().values[zoomSlot] == 0, "no speed, no motion")

        engine.write(lane: .user, slot: layout.slot(for: .scaleZoomSpeed)!, value: 1)
        clock.advance()
        let after = engine.resolve().values[zoomSlot]
        #expect(abs(after - 0.25) < 1e-6, "phase advances rate × dt octaves")

        // Signed speed zooms back out.
        engine.write(lane: .user, slot: layout.slot(for: .scaleZoomSpeed)!, value: -1)
        clock.advance()
        #expect(abs(engine.resolve().values[zoomSlot]) < 1e-6)
    }
}
