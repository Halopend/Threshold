// PaletteCrossfadeTests.swift — Palette.crossfade, the scene-transition
// gradient blend (ADR-005 §2). Pure value math, no engine.

import Testing
@testable import ThresholdCore

@Suite("Palette crossfade (ADR-005)")
struct PaletteCrossfadeTests {
    private let red = Palette(stops: [
        GradientStop(position: 0, rgb: (1, 0, 0)),
        GradientStop(position: 1, rgb: (1, 0, 0)),
    ])
    private let blue = Palette(stops: [
        GradientStop(position: 0, rgb: (0, 0, 1)),
        GradientStop(position: 1, rgb: (0, 0, 1)),
    ])

    @Test("weight 0 is the from palette, weight 1 is the to palette")
    func endpoints() {
        #expect(Palette.crossfade(from: red, to: blue, weight: 0) == red)
        #expect(Palette.crossfade(from: red, to: blue, weight: 1) == blue)
    }

    @Test("Non-finite weight lands on the target (fail toward the destination)")
    func nanWeightIsTarget() {
        #expect(Palette.crossfade(from: red, to: blue, weight: .nan) == blue)
    }

    @Test("Midpoint blends each channel halfway")
    func midpointBlends() {
        let mid = Palette.crossfade(from: red, to: blue, weight: 0.5)
        let c = mid.sample(t: 0.5)
        #expect(abs(c.red - 0.5) < 1e-4)
        #expect(abs(c.blue - 0.5) < 1e-4)
        #expect(abs(c.green) < 1e-4)
    }

    @Test("A weight-0.25 blend leans toward the from palette")
    func quarterLeansFrom() {
        let c = Palette.crossfade(from: red, to: blue, weight: 0.25).sample(t: 0.5)
        #expect(abs(c.red - 0.75) < 1e-4)
        #expect(abs(c.blue - 0.25) < 1e-4)
    }

    @Test("Crossfading a palette with itself is a no-op at any weight")
    func selfCrossfadeIsIdentity() {
        for w: Float in [0, 0.3, 0.5, 0.9, 1] {
            let c = Palette.crossfade(from: red, to: red, weight: w).sample(t: 0.5)
            #expect(abs(c.red - 1) < 1e-4 && abs(c.blue) < 1e-4)
        }
    }

    @Test("A union past the ABI stop cap still yields a valid palette")
    func unionOverCapFallsBack() {
        // Two 8-stop palettes at disjoint positions → 16-stop union, capped.
        func ramp(_ shift: Float) -> Palette {
            Palette(stops: (0..<8).map {
                GradientStop(position: min(Float($0) / 8 + shift, 1), rgb: (Float($0) / 8, 0, 0))
            })
        }
        let blended = Palette.crossfade(from: ramp(0), to: ramp(0.03), weight: 0.5)
        #expect(blended.stops.count <= Palette.maxStops)
        #expect(blended.stops.count >= 1)
    }
}
