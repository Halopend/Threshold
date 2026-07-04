import CoreGraphics
import SwiftUI
import Testing
@testable import ThresholdUI

// Guards the embedded SVG path parser: a broken tokenizer/number parse would
// mangle the outline. We can't assert "looks like a hand" headlessly, but we
// can assert it parses into a filled, in-bounds, multi-segment path.

@Test func handSilhouetteParsesAndFillsRect() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 200 / (1000.0 / 729.0))
    let path = HandShape().path(in: rect)

    #expect(!path.isEmpty)
    let b = path.boundingRect
    // Stays inside the target rect (small tolerance for control-point overshoot).
    #expect(b.minX >= -2 && b.minY >= -2)
    #expect(b.maxX <= rect.width + 2 && b.maxY <= rect.height + 2)
    // Spans most of the rect — a coordinate-parse bug would collapse it.
    #expect(b.width > rect.width * 0.85)
    #expect(b.height > rect.height * 0.6)

    // Many curve elements (the outline is 80+ cubic segments).
    var elements = 0
    path.forEach { _ in elements += 1 }
    #expect(elements > 60)
}

@Test func handSilhouetteScalesWithRect() {
    let small = HandShape().path(in: CGRect(x: 0, y: 0, width: 100, height: 73))
    let large = HandShape().path(in: CGRect(x: 0, y: 0, width: 300, height: 219))
    #expect(large.boundingRect.width > small.boundingRect.width * 2.5)
}
