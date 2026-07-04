import simd
import Testing
@testable import ThresholdCore

// A small layout: float3 "pos" (slots 16..18), scalar "power" (19), "warpx" (20).
private func makeLayout() -> CatalogLayout {
    let cat = Catalog()
    try! cat.register(ParamSpec(key: ParamKey("de.f.pos"), label: "Position",
                                kind: .float3, range: -1...1, defaultValue: [0, 0, 0]))
    try! cat.register(ParamSpec(key: ParamKey("de.f.power"), label: "Power",
                                range: 0...8, default: 4))
    try! cat.register(ParamSpec(key: ParamKey("de.f.warpx"), label: "Warp.x",
                                range: 0...2, default: 0))
    return cat.freeze()
}

private func writeMap(_ writes: [LaneWrite]) -> [Int: Float] {
    Dictionary(uniqueKeysWithValues: writes.map { ($0.slot, $0.value) })
}

// Vector binding → three slots ---------------------------------------------

@Test func resolverVectorNativeWritesThreeComponents() {
    let layout = makeLayout()
    var table = GestureBindingTable()
    let src = GestureSource.tapThumb(hand: .right, finger: .index)
    table.setBinding(.vector(.native(ParamKey("de.f.pos"))), for: src)

    let writes = GestureLaneResolver.resolve(
        drives: [src: .vector(SIMD3(1, 0.5, -1))],
        table: table, layout: layout, gain: 0.5)
    let m = writeMap(writes)
    // offset = drive · gain(0.5) · span(2) = drive · 1
    #expect(m[16] == 1.0)
    #expect(m[17] == 0.5)
    #expect(m[18] == -1.0)
    #expect(writes.allSatisfy { $0.lane == .gesture })
    #expect(writes.count == 3)
}

@Test func resolverGroupedWritesOnlyAssignedAxes() {
    let layout = makeLayout()
    var table = GestureBindingTable()
    let src = GestureSource.swipe(hand: .left)
    table.setBinding(.vector(.grouped(x: ParamKey("de.f.warpx"), y: nil, z: nil)), for: src)

    let writes = GestureLaneResolver.resolve(
        drives: [src: .vector(SIMD3(1, 9, 9))],
        table: table, layout: layout, gain: 0.5)
    // Only x assigned → one write at warpx (slot 20), span 2 → 1·0.5·2 = 1.0.
    #expect(writes.count == 1)
    #expect(writes[0].slot == 20)
    #expect(writes[0].value == 1.0)
}

// Scalar binding ------------------------------------------------------------

@Test func resolverScalarWritesOneSlot() {
    let layout = makeLayout()
    var table = GestureBindingTable()
    let src = GestureSource.fist(hand: .left)
    table.setBinding(.scalar(ParamKey("de.f.power")), for: src)

    let writes = GestureLaneResolver.resolve(
        drives: [src: .scalar(1.0)], table: table, layout: layout, gain: 0.5)
    #expect(writes.count == 1)
    #expect(writes[0].slot == 19)
    #expect(writes[0].value == 4.0)   // 1 · 0.5 · span(8)
}

// Guards --------------------------------------------------------------------

@Test func resolverSkipsArityMismatch() {
    let layout = makeLayout()
    var table = GestureBindingTable()
    let src = GestureSource.tapThumb(hand: .right, finger: .middle)
    table.setBinding(.vector(.native(ParamKey("de.f.pos"))), for: src)
    // A scalar drive on a vector binding is ignored.
    let writes = GestureLaneResolver.resolve(
        drives: [src: .scalar(1)], table: table, layout: layout)
    #expect(writes.isEmpty)
}

@Test func resolverSkipsUnboundMissingAndCore() {
    let layout = makeLayout()
    var table = GestureBindingTable()
    // Unbound source.
    let unbound = GestureSource.tapPalm(hand: .right, finger: .ring)
    // Bound to a missing key.
    let missing = GestureSource.tapPalm(hand: .left, finger: .index)
    table.setBinding(.scalar(ParamKey("nope")), for: missing)
    // Core binding — behavioral, no param write.
    let core = GestureSource.fist(hand: .right)
    table.setBinding(.core(.grabZoom), for: core)

    let writes = GestureLaneResolver.resolve(
        drives: [unbound: .scalar(1), missing: .scalar(1), core: .scalar(1)],
        table: table, layout: layout)
    #expect(writes.isEmpty)
}

// HandGeometry --------------------------------------------------------------

@Test func proximityRamp() {
    #expect(HandGeometry.proximity(0.02, on: 0.02, off: 0.05) == 1)
    #expect(HandGeometry.proximity(0.05, on: 0.02, off: 0.05) == 0)
    #expect(abs(HandGeometry.proximity(0.035, on: 0.02, off: 0.05) - 0.5) < 1e-5)
    #expect(HandGeometry.proximity(0.10, on: 0.02, off: 0.05) == 0)   // clamped
}

@Test func pinchAndFist() {
    let thumb = SIMD3<Float>(0, 0, 0)
    #expect(HandGeometry.pinchStrength(thumb: thumb, finger: SIMD3(0.01, 0, 0)) == 1)
    #expect(HandGeometry.pinchStrength(thumb: thumb, finger: SIMD3(0.06, 0, 0)) == 0)

    let palm = SIMD3<Float>(0, 0, 0)
    let curled = [SIMD3<Float>(0.03, 0, 0), SIMD3(0, 0.03, 0),
                  SIMD3(0.02, 0.02, 0), SIMD3(0.03, 0.01, 0)]
    #expect(HandGeometry.fistClosure(fingerTips: curled, palm: palm) == 1)
    // One finger extended drops closure below full.
    let openHand = curled + [SIMD3<Float>(0.2, 0, 0)]
    #expect(HandGeometry.fistClosure(fingerTips: openHand, palm: palm) < 1)
}
