import simd
import Testing
@testable import ThresholdCore

// The starter (out-of-the-box) gesture bindings: they must seed real per-fractal
// bindings, keep the index finger free for the camera, and resolve to gesture-
// lane writes on the intended params.

@Suite("Starter gesture defaults")
struct GestureDefaultsTests {

    @Test func seedsExpectedPerFractalBindings() {
        let set = GestureBindingSet.starter()

        // Mandelbulb: middle→power, ring→rotationSpeed, both on the LEFT hand.
        let bulb = set.resolvedTable(forFractal: "mandelbulb")
        #expect(bulb.binding(for: .tapThumb(hand: .left, finger: .middle))
                == .vector(.grouped(x: nil, y: .de("mandelbulb", "power"), z: nil)))
        #expect(bulb.binding(for: .tapThumb(hand: .left, finger: .ring))
                == .vector(.grouped(x: nil, y: .de("mandelbulb", "rotationSpeed"), z: nil)))

        // Kleinian: Mins (left) + Maxs (right) triplets.
        let klein = set.resolvedTable(forFractal: "kleinian")
        #expect(klein.binding(for: .tapThumb(hand: .left, finger: .middle))
                == .vector(.grouped(x: .de("kleinian", "minX"),
                                    y: .de("kleinian", "minY"),
                                    z: .de("kleinian", "minZ"))))
        #expect(klein.binding(for: .tapThumb(hand: .right, finger: .middle))
                == .vector(.grouped(x: .de("kleinian", "maxX"),
                                    y: .de("kleinian", "maxY"),
                                    z: .de("kleinian", "maxZ"))))
    }

    @Test func leavesTheIndexFingerFreeForTheCamera() {
        // The hardwired index-pinch camera control (orbit/dolly) must not be
        // claimed by a default binding on any fractal.
        let set = GestureBindingSet.starter()
        for deKey in ["mandelbox", "mandelbulb", "mandelbulbJulia", "quaternionJulia",
                      "kleinian", "mengerSponge", "mandelboxSphereProjection"] {
            let table = set.resolvedTable(forFractal: deKey)
            #expect(table.binding(for: .tapThumb(hand: .left, finger: .index)) == nil)
            #expect(table.binding(for: .tapThumb(hand: .right, finger: .index)) == nil)
        }
    }

    @Test func bindingsAreScopedPerFractal() {
        // Nothing global; each fractal only carries its own params (a mandelbulb
        // binding must not leak onto mandelbox).
        let set = GestureBindingSet.starter()
        #expect(set.table(for: .global).isEmpty)
        let box = set.resolvedTable(forFractal: "mandelbox")
        #expect(box.binding(for: .tapThumb(hand: .left, finger: .middle))
                == .vector(.grouped(x: nil, y: .de("mandelbox", "minRadius"), z: nil)))
    }

    @Test func starterBindingsResolveToLaneWrites() {
        // Wire mandelbulb's default middle-finger binding through the resolver
        // against a layout that actually registers de.mandelbulb.power, and
        // confirm a signed vertical drag lands on the power slot.
        let cat = Catalog()
        try! cat.register(ParamSpec(key: .de("mandelbulb", "power"), label: "Power",
                                    range: 2...16, default: 8))
        try! cat.register(ParamSpec(key: .de("mandelbulb", "rotationSpeed"), label: "Rotation Speed",
                                    range: -2...2, default: 0))
        let layout = cat.freeze()

        let table = GestureBindingSet.starter().resolvedTable(forFractal: "mandelbulb")
        let src = GestureSource.tapThumb(hand: .left, finger: .middle)
        // Drag: only the y (vertical) axis should count; x/z are ignored by the
        // grouped-y binding.
        let writes = GestureLaneResolver.resolve(
            drives: [src: .vector(SIMD3(9, 0.5, 9))],
            table: table, layout: layout, gain: 0.5)

        let powerSlot = layout.entry(for: .de("mandelbulb", "power"))!.slot
        #expect(writes.count == 1)
        #expect(writes[0].slot == powerSlot)
        #expect(writes[0].lane == .gesture)
        // offset = drive.y(0.5) · gain(0.5) · span(14) = 3.5
        #expect(abs(writes[0].value - 3.5) < 1e-5)
    }
}
