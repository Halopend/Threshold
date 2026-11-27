import Foundation
import simd
import Testing
@testable import ThresholdCore

// A small layout: float3 "pos" (firstContentSlot..+2), scalar "power" (+3), "warpx" (+4).
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
    #expect(m[firstContentSlot] == 1.0)
    #expect(m[firstContentSlot + 1] == 0.5)
    #expect(m[firstContentSlot + 2] == -1.0)
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
    // Only x assigned → one write at warpx (firstContentSlot + 4), span 2 → 1·0.5·2 = 1.0.
    #expect(writes.count == 1)
    #expect(writes[0].slot == firstContentSlot + 4)
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
    #expect(writes[0].slot == firstContentSlot + 3)
    #expect(writes[0].value == 4.0)   // 1 · 0.5 · span(8)
}

@Test func resolverScalarAxisUsesSelectedVectorComponent() {
    let layout = makeLayout()
    var table = GestureBindingTable()
    let src = GestureSource.tapThumb(hand: .right, finger: .index)
    table.setBinding(.scalarAxis(ParamKey("de.f.power"), .z), for: src)

    let writes = GestureLaneResolver.resolve(
        drives: [src: .vector(SIMD3(1, 2, -0.25))],
        table: table, layout: layout, gain: 0.5)
    #expect(writes.count == 1)
    #expect(writes[0].slot == firstContentSlot + 3)
    #expect(writes[0].value == -1.0)   // z(-0.25) * gain(0.5) * span(8)
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

// Deterministic arbitration ---------------------------------------------------
// Composition-policy layout: "mul" (multiplicative 0.05…20, neutral 1),
// "repl" (replace 0…8, default 4), "noRoom" (multiplicative 1…8 — nothing
// below the neutral), "tog" (a bool replace — never a gesture target).

private func makePolicyLayout() -> CatalogLayout {
    let cat = Catalog()
    try! cat.register(ParamSpec(key: ParamKey("de.f.mul"), label: "Mul",
                                range: 0.05...20, default: 1, composition: .multiplicative))
    try! cat.register(ParamSpec(key: ParamKey("de.f.repl"), label: "Repl",
                                range: 0...8, default: 4, composition: .replace))
    try! cat.register(ParamSpec(key: ParamKey("de.f.noRoom"), label: "NoRoom",
                                range: 1...8, default: 1, composition: .multiplicative))
    try! cat.register(ParamSpec(key: ParamKey("de.f.tog"), label: "Tog",
                                kind: .bool, range: 0...1, default: 0, composition: .replace))
    return cat.freeze()
}

// Slots (fresh layout, first registration): mul 16, repl 17, noRoom 18, tog 19.

@Test func arbitrationRankIsTotalPrecisionFirst() {
    // Family-major total order: every tapThumb (left hand first, then right,
    // index through pinky), then every tapPalm, then swipe, then fist.
    var all: [GestureSource] = []
    let fingers: [GestureFinger] = [.index, .middle, .ring, .pinky]
    for finger in fingers { all.append(.tapThumb(hand: .left, finger: finger)) }
    for finger in fingers { all.append(.tapThumb(hand: .right, finger: finger)) }
    for finger in fingers { all.append(.tapPalm(hand: .left, finger: finger)) }
    for finger in fingers { all.append(.tapPalm(hand: .right, finger: finger)) }
    all.append(.swipe(hand: .left))
    all.append(.swipe(hand: .right))
    all.append(.fist(hand: .left))
    all.append(.fist(hand: .right))
    #expect(all == all.sorted { $0.arbitrationRank < $1.arbitrationRank })
    // Family escalation: the precise one-finger sources rank below the
    // whole-hand ones.
    #expect(GestureSource.tapThumb(hand: .left, finger: .index).arbitrationRank
        < GestureSource.tapThumb(hand: .left, finger: .pinky).arbitrationRank)
    #expect(GestureSource.tapThumb(hand: .left, finger: .pinky).arbitrationRank
        < GestureSource.tapPalm(hand: .right, finger: .index).arbitrationRank)
    #expect(GestureSource.fist(hand: .right).arbitrationRank
        == all.map(\.arbitrationRank).max()!)
}

@Test func resolverAdditiveComposesTwoSources() {
    let layout = makeLayout()
    var table = GestureBindingTable()
    let left = GestureSource.tapPalm(hand: .left, finger: .index)
    let right = GestureSource.tapPalm(hand: .right, finger: .index)
    table.setBinding(.scalar(ParamKey("de.f.power")), for: left)
    table.setBinding(.scalar(ParamKey("de.f.power")), for: right)

    // Offsets 0.5·0.5·8 = 2.0 and −0.25·0.5·8 = −1.0 sum to one push of 1.0.
    let writes = GestureLaneResolver.resolve(
        drives: [left: .scalar(0.5), right: .scalar(-0.25)],
        table: table, layout: layout, gain: 0.5)
    #expect(writes.count == 1)
    #expect(writes[0].slot == firstContentSlot + 3)
    #expect(writes[0].value == 1.0)
}

@Test func resolverMultiplicativeMapsThroughLogSpace() {
    let layout = makePolicyLayout()
    var table = GestureBindingTable()
    // A vector source bound per-axis to a multiplicative factor param.
    table.setBinding(.scalarAxis(ParamKey("de.f.mul"), .y), for: GestureSource.swipe(hand: .right))
    let mulSlot = firstContentSlot

    // Full down-drive reaches the lower edge, in log space:
    // exp(−1 · 0.5 · ln(1/0.05)) = √0.05 ≈ 0.2236. (The old additive mapping
    // would have written −0.5·span(19.95) ≈ −9.98.)
    let down = GestureLaneResolver.resolve(
        drives: [GestureSource.swipe(hand: .right): .vector(SIMD3(0, -1, 0))],
        table: table, layout: layout, gain: 0.5)
    #expect(down.count == 1)
    #expect(down[0].slot == mulSlot)
    #expect(abs(down[0].value - 0.223606798) < 1e-5)

    // Full up-drive: exp(0.5 · ln 20) ≈ 4.4721.
    let up = GestureLaneResolver.resolve(
        drives: [GestureSource.swipe(hand: .right): .vector(SIMD3(0, 1, 0))],
        table: table, layout: layout, gain: 0.5)
    #expect(up.count == 1)
    #expect(abs(up[0].value - 4.472136) < 1e-4)

    // Scalar (signless) drives push one-sided, toward the upper edge:
    // exp(0.5 · ln 20) again for full closure.
    var scalarTable = table
    scalarTable.setBinding(.scalar(ParamKey("de.f.mul")), for: GestureSource.fist(hand: .right))
    let scalarWrite = GestureLaneResolver.resolve(
        drives: [GestureSource.fist(hand: .right): .scalar(1)],
        table: scalarTable, layout: layout, gain: 0.5)
    #expect(scalarWrite.count == 1)
    #expect(abs(scalarWrite[0].value - 4.472136) < 1e-4)
}

@Test func resolverMultiplicativeWritesNeutralWhenNoRoom() {
    let layout = makePolicyLayout()
    var table = GestureBindingTable()
    // Range 1…8 passes nowhere below the neutral 1: a down-drive writes the
    // inert factor 1 (the slot stays gesture-owned, the value contributes
    // nothing), while an up-drive still reaches for its edge.
    table.setBinding(.scalarAxis(ParamKey("de.f.noRoom"), .x), for: GestureSource.swipe(hand: .left))
    let noRoomSlot = firstContentSlot + 2

    let down = GestureLaneResolver.resolve(
        drives: [GestureSource.swipe(hand: .left): .vector(SIMD3(-1, 0, 0))],
        table: table, layout: layout, gain: 0.5)
    #expect(down.count == 1 && down[0].slot == noRoomSlot && down[0].value == 1)

    let up = GestureLaneResolver.resolve(
        drives: [GestureSource.swipe(hand: .left): .vector(SIMD3(1, 0, 0))],
        table: table, layout: layout, gain: 0.5)
    #expect(up.count == 1)
    #expect(abs(up[0].value - 2.828427) < 1e-4)   // exp(0.5·ln 8) = √8
}

@Test func resolverReplaceTakesOwnershipFromMostPreciseSource() {
    let layout = makePolicyLayout()
    var table = GestureBindingTable()
    // Two replace-targeting sources on one slot: the whole-hand fist (highest
    // rank) must NOT ratchet the replace slot away from the finer palm tap.
    let precise = GestureSource.tapPalm(hand: .left, finger: .index)
    let blunt = GestureSource.fist(hand: .left)
    table.setBinding(.scalar(ParamKey("de.f.repl")), for: precise)
    table.setBinding(.scalar(ParamKey("de.f.repl")), for: blunt)
    let replSlot = firstContentSlot + 1

    let writes = GestureLaneResolver.resolve(
        drives: [precise: .scalar(0.2), blunt: .scalar(0.9)],
        table: table, layout: layout, gain: 0.5)
    #expect(writes.count == 1)
    #expect(writes[0].slot == replSlot)
    // Owned by the precise source: default 4 + 0.2 · 0.5 · 8 = 4.8, not the
    // fist's 4 + 0.9 · 0.5 · 8 = 7.6.
    #expect(writes[0].value == 4.8)

    // The blunt source alone does own the slot (nobody finer is armed) and
    // writes its absolute value.
    let solo = GestureLaneResolver.resolve(
        drives: [blunt: .scalar(0.9)], table: table, layout: layout, gain: 0.5)
    #expect(solo.count == 1 && solo[0].slot == replSlot && solo[0].value == 7.6)
}

@Test func resolverMultiplicativeComposesFactorsOfTwoSources() {
    let layout = makePolicyLayout()
    var table = GestureBindingTable()
    let left = GestureSource.tapPalm(hand: .left, finger: .index)
    let right = GestureSource.tapPalm(hand: .right, finger: .index)
    table.setBinding(.scalar(ParamKey("de.f.mul")), for: left)
    table.setBinding(.scalar(ParamKey("de.f.mul")), for: right)
    // Factors multiply: exp(0.5·ln20) · exp(0.25·ln20) = exp(0.75·ln20)
    // = 20^0.75 ≈ 9.4576.
    let expectedFactor = Float(pow(20.0, 0.75))
    let writes = GestureLaneResolver.resolve(
        drives: [left: .scalar(1), right: .scalar(0.5)],
        table: table, layout: layout, gain: 0.5)
    #expect(writes.count == 1)
    #expect(abs(writes[0].value - expectedFactor) < 1e-3)
}

@Test func resolverSkipsDiscreteKindTargets() {
    let layout = makePolicyLayout()
    var table = GestureBindingTable()
    // Bool targets are excluded by the editor; a hand-authored binding to one
    // must not produce a mid-table value either.
    table.setBinding(.scalar(ParamKey("de.f.tog")), for: GestureSource.fist(hand: .left))
    let writes = GestureLaneResolver.resolve(
        drives: [GestureSource.fist(hand: .left): .scalar(1)],
        table: table, layout: layout, gain: 0.5)
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
