// ScaleContextTests.swift — the zoom/scale derivation site (plan §6.3,
// phase 10 part 1): octave→modelScale math, catalog registration, and the
// zoom integrator (scale.zoomSpeed rate → scale.zoom phase).

import Foundation
import Testing
import ThresholdCore

@Suite("Scale context")
struct ScaleContextTests {
    @Test func modelScaleIsExp2OfNegativeZoom() {
        #expect(ScaleContext(zoomOctaves: 0).modelScale == 1)
        #expect(ScaleContext(zoomOctaves: 1).modelScale == 0.5, "zoom in shrinks model space")
        #expect(ScaleContext(zoomOctaves: -2).modelScale == 4, "zoom out grows it")
        #expect(ScaleContext(zoomOctaves: 0).octave == 0, "octave defaults to never-rebased")
    }

    @Test func rebaseStepFiresOnlyPastTheZoomInThreshold() {
        #expect(ScaleContext.rebaseStep(zoomOctaves: 0) == 0)
        #expect(ScaleContext.rebaseStep(zoomOctaves: 7.9) == 0, "within budget")
        #expect(ScaleContext.rebaseStep(zoomOctaves: 8.0) == 8, "fires at the threshold")
        #expect(ScaleContext.rebaseStep(zoomOctaves: 8.5) == 8, "folds the integer part only")
        #expect(ScaleContext.rebaseStep(zoomOctaves: 40.75) == 40)
        #expect(ScaleContext.rebaseStep(zoomOctaves: -30) == 0,
                "zoom-out accumulates no coordinate drift — never rebases")
        #expect(ScaleContext.rebaseStep(zoomOctaves: .nan) == 0)
        #expect(ScaleContext.rebaseStep(zoomOctaves: .infinity) == 0)
    }

    @Test func rebaseIsFloatExact() {
        // The whole point of folding at a power-of-two boundary: subtracting
        // the integer step from the phase and scaling coordinates by 2^-k are
        // both exact, so a rebase cannot move a single pixel.
        let phase: Float = 8.3
        let k = ScaleContext.rebaseStep(zoomOctaves: phase)
        let folded = phase - Float(k)
        #expect(ScaleContext(zoomOctaves: folded).modelScale * exp2(-Float(k))
                == ScaleContext(zoomOctaves: phase).modelScale)
        let camera: Float = 768.25
        #expect(camera * exp2(-Float(k)) * exp2(Float(k)) == camera,
                "power-of-two camera rescale round-trips exactly")
    }

    @Test func totalZoomDepthSpansRebases() {
        #expect(ScaleContext(zoomOctaves: 0.5, octave: 40).totalZoomOctaves == 40.5)
        #expect(ScaleContext(zoomOctaves: 0.5, octave: 40).modelScale == exp2(-0.5 as Float),
                "the kernel sees the PHASE only — octave is bookkeeping")
    }

    @Test func envelopeCarriesTheOctaveCounterOnlyWhenRebased() throws {
        var scene = SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "mandelbulb")
        let pristine = try SceneCodec.encode(scene)
        #expect(!String(decoding: pristine, as: UTF8.self).contains("scaleOctave"),
                "never-rebased scenes stay byte-identical to the pre-octave format")

        scene.scaleOctave = 12
        let reopened = try SceneCodec.decode(SceneCodec.encode(scene))
        #expect(reopened.scaleOctave == 12)
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
