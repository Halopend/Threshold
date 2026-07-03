// PaletteTests.swift — the gradient palette model + CPU reference sampler
// (plan §5.5). The sampler mirrors RaymarchCore.metal's samplePalette; these
// tests pin its contract so the GPU look stays anchored.

import Testing
@testable import ThresholdCore

@Suite("Palette sanitization")
struct PaletteSanitizationTests {
    @Test("Stops are sorted by position")
    func sorts() {
        let p = Palette(stops: [
            GradientStop(position: 0.8, red: 1, green: 0, blue: 0),
            GradientStop(position: 0.2, red: 0, green: 1, blue: 0),
            GradientStop(position: 0.5, red: 0, green: 0, blue: 1),
        ])
        #expect(p.stops.map(\.position) == [0.2, 0.5, 0.8])
    }

    @Test("Positions and colors clamp to 0…1; non-finite → 0")
    func clamps() {
        let p = Palette(stops: [
            GradientStop(position: -1, red: 2, green: -0.5, blue: .nan),
            GradientStop(position: 5, red: .infinity, green: 0.5, blue: 0.5),
        ])
        for s in p.stops {
            #expect(s.position >= 0 && s.position <= 1)
            #expect(s.red >= 0 && s.red <= 1)
            #expect(s.green >= 0 && s.green <= 1)
            #expect(s.blue >= 0 && s.blue <= 1)
        }
    }

    @Test("More than maxStops is truncated")
    func caps() {
        let many = (0..<20).map {
            GradientStop(position: Float($0) / 19, red: 0, green: 0, blue: 0)
        }
        #expect(Palette(stops: many).stops.count == Palette.maxStops)
    }

    @Test("Empty input yields a single mid-gray identity stop")
    func emptyFallback() {
        let p = Palette(stops: [])
        #expect(p.stops.count == 1)
        #expect(p.stops[0].red == 0.5)
    }
}

@Suite("Palette sampling")
struct PaletteSamplingTests {
    private let rg = Palette(stops: [
        GradientStop(position: 0, red: 1, green: 0, blue: 0),
        GradientStop(position: 1, red: 0, green: 1, blue: 0),
    ])

    @Test("t=0 is the first stop exactly; t=1 wraps back to it (cyclic phase)")
    func endpoints() {
        let lo = rg.sample(t: 0)
        #expect(lo.red == 1 && lo.green == 0)
        // The coordinate is a cyclic phase (plan §5.5): 1.0 wraps to 0.0.
        let top = rg.sample(t: 1)
        #expect(top.red == 1 && top.green == 0)
        // Approaching 1 from below approaches the last stop.
        let near = rg.sample(t: 0.999)
        #expect(near.green > 0.99)
    }

    @Test("Midpoint linearly interpolates")
    func midpoint() {
        let m = rg.sample(t: 0.5)
        #expect(abs(m.red - 0.5) < 1e-5)
        #expect(abs(m.green - 0.5) < 1e-5)
    }

    @Test("Coordinates below first / above last stop clamp to the edge colors")
    func clampToEdges() {
        let p = Palette(stops: [
            GradientStop(position: 0.25, red: 0.2, green: 0.2, blue: 0.2),
            GradientStop(position: 0.75, red: 0.8, green: 0.8, blue: 0.8),
        ])
        #expect(p.sample(t: 0.1).red == 0.2)   // below first stop → first color
        #expect(p.sample(t: 0.9).red == 0.8)   // above last stop (no wrap) → last color
    }

    @Test("Offset + repeat wrap the coordinate into [0,1)")
    func wraps() {
        // offset 1.0 wraps to 0 → same as t; t=1.5 with repeat 1 wraps to 0.5.
        let a = rg.sample(t: 0.3, repeatCount: 1, offset: 1.0)
        let b = rg.sample(t: 0.3)
        #expect(abs(a.red - b.red) < 1e-6)
        let wrapped = rg.sample(t: 1.5)
        let half = rg.sample(t: 0.5)
        #expect(abs(wrapped.red - half.red) < 1e-6)
    }

    @Test("Single-stop palette is constant everywhere")
    func singleStop() {
        let p = Palette(stops: [GradientStop(position: 0.5, red: 0.3, green: 0.6, blue: 0.9)])
        for t in stride(from: Float(0), through: 1, by: 0.25) {
            let c = p.sample(t: t)
            #expect(c.red == 0.3 && c.green == 0.6 && c.blue == 0.9)
        }
    }
}

@Suite("Palette presets")
struct PalettePresetTests {
    @Test("14 built-in presets, all with valid non-empty palettes")
    func builtIns() {
        #expect(PalettePreset.builtIn.count == 14)
        for preset in PalettePreset.builtIn {
            #expect(!preset.palette.stops.isEmpty)
            #expect(preset.palette.stops.count <= Palette.maxStops)
        }
    }

    @Test("Preset ids are unique and looked up by id")
    func lookup() {
        let ids = PalettePreset.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(PalettePreset.preset(id: "classic")?.name == "Classic")
        #expect(PalettePreset.preset(id: "nope") == nil)
    }

    @Test("Default preset is classic")
    func defaultIsClassic() {
        #expect(PalettePreset.default.id == "classic")
    }
}
