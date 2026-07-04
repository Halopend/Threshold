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
