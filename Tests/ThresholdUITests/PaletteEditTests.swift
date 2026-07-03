// PaletteEditTests.swift — the pure gradient-stop edits behind PaletteSection.
// No GPU, no views.

import Testing
import ThresholdCore
@testable import ThresholdUI

@Suite("PaletteEdit")
struct PaletteEditTests {
    private let base = Palette(stops: [
        GradientStop(position: 0.0, red: 1, green: 0, blue: 0),
        GradientStop(position: 0.5, red: 0, green: 1, blue: 0),
        GradientStop(position: 1.0, red: 0, green: 0, blue: 1),
    ])

    @Test("setColor replaces exactly one stop's color, keeps position")
    func setColor() {
        let edited = PaletteEdit.setColor(base, at: 1, red: 0.2, green: 0.3, blue: 0.4)
        #expect(edited.stops.count == 3)
        #expect(edited.stops[1].position == 0.5)
        #expect(edited.stops[1].red == 0.2 && edited.stops[1].green == 0.3 && edited.stops[1].blue == 0.4)
        #expect(edited.stops[0] == base.stops[0])
    }

    @Test("setPosition re-sorts when a stop crosses a neighbor")
    func setPositionResorts() {
        // Move stop 0 (red) past stop 1 → sorting reorders by position.
        let edited = PaletteEdit.setPosition(base, at: 0, to: 0.9)
        #expect(edited.stops.map(\.position) == [0.5, 0.9, 1.0])
        // The green stop (was index 1) is now first.
        #expect(edited.stops[0].green == 1)
    }

    @Test("deleting removes a stop but never the last one")
    func deleting() {
        let edited = PaletteEdit.deleting(base, at: 1)
        #expect(edited.stops.count == 2)
        let single = Palette(stops: [GradientStop(position: 0, red: 1, green: 1, blue: 1)])
        #expect(PaletteEdit.deleting(single, at: 0).stops.count == 1)  // refuses last
    }

    @Test("addingStop inserts in the widest gap, sampled seamlessly")
    func addingStop() {
        let two = Palette(stops: [
            GradientStop(position: 0.0, red: 1, green: 0, blue: 0),
            GradientStop(position: 1.0, red: 0, green: 0, blue: 1),
        ])
        let edited = PaletteEdit.addingStop(two)
        #expect(edited.stops.count == 3)
        // New stop sits at the midpoint 0.5.
        #expect(edited.stops[1].position == 0.5)
    }

    @Test("addingStop is a no-op at the stop cap")
    func addingStopCapped() {
        let full = Palette(stops: (0..<Palette.maxStops).map {
            GradientStop(position: Float($0) / Float(Palette.maxStops - 1), red: 0, green: 0, blue: 0)
        })
        #expect(PaletteEdit.addingStop(full).stops.count == Palette.maxStops)
    }

    @Test("Out-of-range indices are no-ops")
    func outOfRange() {
        #expect(PaletteEdit.setColor(base, at: 9, red: 0, green: 0, blue: 0) == base)
        #expect(PaletteEdit.setPosition(base, at: -1, to: 0.5) == base)
        #expect(PaletteEdit.deleting(base, at: 9) == base)
    }
}
