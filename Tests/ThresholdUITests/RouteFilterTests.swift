import Testing
import ThresholdCore
@testable import ThresholdUI

// Guards the fractal-tagging that the Routes filter keys off.

@Test func fractalKeyExtractsDEKey() {
    #expect(BindTarget.fractalKey(for: ParamKey("de.mandelbulb.power")) == "mandelbulb")
    // A component suffix must not confuse the deKey (first segment after "de").
    #expect(BindTarget.fractalKey(for: ParamKey("de.mandelbox.Translate.x")) == "mandelbox")
    // Universal params carry no fractal.
    #expect(BindTarget.fractalKey(for: ParamKey("engine.aoStrength")) == nil)
    #expect(BindTarget.fractalKey(for: ParamKey("color.gamma")) == nil)
    #expect(BindTarget.fractalKey(for: ParamKey("camera.orbit.yaw")) == nil)
}

@Test func groupedPutsGeneralFirstThenActiveFractal() {
    let targets = [
        BindTarget(key: ParamKey("engine.aoStrength"), component: 0,
                   label: "AO", range: 0...2, fractalKey: nil),
        BindTarget(key: ParamKey("de.mandelbulb.power"), component: 0,
                   label: "Power", range: 0...8, fractalKey: "mandelbulb"),
        BindTarget(key: ParamKey("de.mandelbox.scale"), component: 0,
                   label: "Scale", range: -3...3, fractalKey: "mandelbox"),
    ]
    let sections = BindTarget.grouped(targets, activeFractal: "mandelbox")
    #expect(sections.first?.title == "General")           // universal first
    #expect(sections.count == 3)
    // The active fractal's section precedes the other fractal's.
    let titles = sections.map(\.title)
    let activeIdx = titles.firstIndex { $0 != "General" }
    #expect(sections[activeIdx!].targets.first?.fractalKey == "mandelbox")
}

@Test func targetPickerRespectsMusicBindableDeclaration() throws {
    // Availability is the catalog's declaration: params that never declared
    // bindability (engine knobs) no longer surface in the Routes picker,
    // while the declared DE/camera/color vocabulary does.
    let catalog = Catalog.withEngineDefaults()
    // Stand-in for a DE's registered param (same capabilities the registry
    // declares; the registry itself lives in ThresholdShaderIR).
    try catalog.register(ParamSpec(
        key: ParamKey.de("testbulb", "power"), label: "Power",
        range: 0...8, default: 4,
        capabilities: [.musicBindable, .gestureBindable, .animatable],
        group: .shape))
    try catalog.register(ParamSpec(
        key: ParamKey("engine.undeclared"), label: "Undeclared",
        range: 1...4096, default: 256, group: .performance))
    let layout = catalog.freeze()

    let targets = BindTarget.all(layout: layout, dynamic: [])
    let keys = Set(targets.map(\.key))

    // Declared → offered.
    #expect(keys.contains(.colorSaturation))
    #expect(keys.contains(.atmosphereBloomStrength))
    #expect(keys.contains(.cameraDolly))
    #expect(keys.contains(ParamKey.de("testbulb", "power")))

    // Never declared or discrete → excluded.
    #expect(!keys.contains(ParamKey("engine.undeclared")))
    #expect(!keys.contains(.engineMaxSteps))
    #expect(!keys.contains(.engineMaxDist))
    #expect(!keys.contains(.colorMapMode))  // discrete kind, declared nowhere
}
