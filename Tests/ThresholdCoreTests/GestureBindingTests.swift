import Foundation
import Testing
@testable import ThresholdCore

// Helpers ------------------------------------------------------------------

private func scalarEntry(_ slot: Int, key: String, label: String,
                         range: ClosedRange<Float> = 0...1) -> CatalogEntry {
    CatalogEntry(slot: slot, spec: ParamSpec(
        key: ParamKey(key), label: label, kind: .float,
        range: range, default: 0))
}

private func vec3Entry(_ slot: Int, key: String, label: String) -> CatalogEntry {
    CatalogEntry(slot: slot, spec: ParamSpec(
        key: ParamKey(key), label: label, kind: .float3,
        range: -1...1, defaultValue: [0, 0, 0]))
}

// GestureSource persistence -------------------------------------------------

@Test func sourcePersistenceKeyRoundTrips() {
    let sources: [GestureSource] = [
        .tapThumb(hand: .right, finger: .index),
        .tapThumb(hand: .left, finger: .pinky),
        .tapPalm(hand: .right, finger: .middle),
        .swipe(hand: .left),
        .fist(hand: .right),
    ]
    for source in sources {
        #expect(GestureSource(persistenceKey: source.persistenceKey) == source)
    }
}

@Test func sourceKeyIsStableStringForm() {
    #expect(GestureSource.tapThumb(hand: .right, finger: .index).persistenceKey
            == "R.index.tapThumb")
    #expect(GestureSource.tapPalm(hand: .left, finger: .ring).persistenceKey
            == "L.ring.tapPalm")
    #expect(GestureSource.swipe(hand: .left).persistenceKey == "L.swipe")
    #expect(GestureSource.fist(hand: .right).persistenceKey == "R.fist")
}

@Test func unknownSourceKeyReturnsNil() {
    #expect(GestureSource(persistenceKey: "R.thumb.orient") == nil)
    #expect(GestureSource(persistenceKey: "garbage") == nil)
    #expect(GestureSource(persistenceKey: "X.index.tapThumb") == nil)
}

// Arity enforcement ---------------------------------------------------------

@Test func vectorBindingRejectedOnScalarSource() {
    var table = GestureBindingTable()
    // A palm tap is scalar — a vector binding must be refused.
    table.setBinding(.vector(.native(ParamKey("de.x.translate"))),
                     for: .tapPalm(hand: .right, finger: .index))
    #expect(table.binding(for: .tapPalm(hand: .right, finger: .index)) == nil)

    // A scalar binding on the same scalar source is accepted.
    table.setBinding(.scalar(ParamKey("engine.aoStrength")),
                     for: .tapPalm(hand: .right, finger: .index))
    #expect(table.binding(for: .tapPalm(hand: .right, finger: .index))
            == .scalar(ParamKey("engine.aoStrength")))
}

@Test func vectorBindingAcceptedOnVectorSource() {
    var table = GestureBindingTable()
    let src = GestureSource.tapThumb(hand: .right, finger: .index)
    table.setBinding(.vector(.native(ParamKey("de.mbox.offset"))), for: src)
    #expect(table.binding(for: src) == .vector(.native(ParamKey("de.mbox.offset"))))
}

@Test func nilClearsBinding() {
    var table = GestureBindingTable()
    let src = GestureSource.fist(hand: .left)
    table.setBinding(.core(.grabZoom), for: src)
    table.setBinding(nil, for: src)
    #expect(table.binding(for: src) == nil)
    #expect(table.isEmpty)
}

// Codable + forward compatibility ------------------------------------------

@Test func tableRoundTripsThroughJSON() throws {
    var table = GestureBindingTable()
    table.setBinding(.vector(.grouped(x: ParamKey("a.x"), y: ParamKey("a.y"), z: nil)),
                     for: .tapThumb(hand: .right, finger: .middle))
    table.setBinding(.scalar(ParamKey("engine.aoStrength")), for: .fist(hand: .left))
    table.setBinding(.core(.resetView), for: .tapPalm(hand: .right, finger: .pinky))

    let data = try JSONEncoder().encode(table)
    let decoded = try JSONDecoder().decode(GestureBindingTable.self, from: data)
    #expect(decoded == table)
}

@Test func unknownKeysSurviveRoundTrip() throws {
    // The table's wire form IS `[persistenceKey: GestureBinding]`, so build one
    // directly — including a source key a FUTURE build minted — rather than
    // hand-writing the synthesized enum payload shape.
    let raw: [String: GestureBinding] = [
        "R.index.tapThumb": .scalar(ParamKey("engine.aoStrength")),
        "R.wrist.orient": .core(.grabZoom),
    ]
    let json = try JSONEncoder().encode(raw)
    let decoded = try JSONDecoder().decode(GestureBindingTable.self, from: json)
    // Known key parsed into bindings; unknown preserved separately.
    #expect(decoded.binding(for: .tapThumb(hand: .right, finger: .index)) != nil)
    #expect(decoded.unknownBindings["R.wrist.orient"] != nil)
    // Re-encode keeps the foreign key.
    let reencoded = try JSONEncoder().encode(decoded)
    let s = String(data: reencoded, encoding: .utf8)!
    #expect(s.contains("R.wrist.orient"))
}

// Pruning on DE switch ------------------------------------------------------

@Test func pruningDropsOrphansKeepsCoreAndValid() {
    var table = GestureBindingTable()
    table.setBinding(.vector(.native(ParamKey("de.old.p"))),
                     for: .tapThumb(hand: .right, finger: .index))
    table.setBinding(.scalar(ParamKey("engine.aoStrength")), for: .fist(hand: .left))
    table.setBinding(.core(.grabZoom), for: .tapPalm(hand: .right, finger: .ring))

    table.pruning(toKeys: [ParamKey("engine.aoStrength")])

    #expect(table.binding(for: .tapThumb(hand: .right, finger: .index)) == nil) // orphan gone
    #expect(table.binding(for: .fist(hand: .left)) != nil)                       // valid kept
    #expect(table.binding(for: .tapPalm(hand: .right, finger: .ring)) != nil)    // core kept
}

// Vec3Group auto-detect -----------------------------------------------------

@Test func autoDetectGroupsDottedTriple() {
    let entries = [
        scalarEntry(firstContentSlot, key: "de.f.Translate.x", label: "Translate.x", range: -2...2),
        scalarEntry(firstContentSlot + 1, key: "de.f.Translate.y", label: "Translate.y", range: -3...3),
        scalarEntry(firstContentSlot + 2, key: "de.f.Translate.z", label: "Translate.z", range: -1...1),
    ]
    let groups = Vec3Group.autoDetect(from: entries)
    #expect(groups.count == 1)
    let g = groups[0]
    #expect(g.name == "Translate")
    #expect(g.axisCount == 3)
    #expect(g.x == ParamKey("de.f.Translate.x"))
    #expect(g.z == ParamKey("de.f.Translate.z"))
    // Range is the union of components.
    #expect(g.range == -3...3)
}

@Test func autoDetectAllowsPartialTriple() {
    let entries = [
        scalarEntry(firstContentSlot, key: "a.x", label: "Offset x"),
        scalarEntry(firstContentSlot + 1, key: "a.y", label: "Offset y"),
    ]
    let groups = Vec3Group.autoDetect(from: entries)
    #expect(groups.count == 1)
    #expect(groups[0].axisCount == 2)
    #expect(groups[0].z == nil)
}

@Test func autoDetectIgnoresLoneAxisAndFloat3AndNonAxis() {
    let entries = [
        scalarEntry(firstContentSlot, key: "lone.x", label: "Solo.x"),       // lone axis — not a group
        scalarEntry(firstContentSlot + 1, key: "p.power", label: "Power"),        // no axis token
        vec3Entry(firstContentSlot + 2, key: "de.f.pos", label: "Position"),      // native float3 — skipped
    ]
    #expect(Vec3Group.autoDetect(from: entries).isEmpty)
}

@Test func autoDetectDoesNotSplitWordsEndingInAxisLetter() {
    // "Max" ends in x but has no separator — must NOT split into "Ma" + x.
    let entries = [
        scalarEntry(firstContentSlot, key: "m.max", label: "Max"),
        scalarEntry(firstContentSlot + 1, key: "m.box", label: "Box"),
    ]
    #expect(Vec3Group.autoDetect(from: entries).isEmpty)
}

@Test func autoDetectHandlesUnderscoreAndSpaceSeparators() {
    let entries = [
        scalarEntry(firstContentSlot, key: "u.x", label: "Fold_X"),
        scalarEntry(firstContentSlot + 1, key: "u.y", label: "Fold_Y"),
        scalarEntry(firstContentSlot + 2, key: "u.z", label: "Fold_Z"),
    ]
    let groups = Vec3Group.autoDetect(from: entries)
    #expect(groups.count == 1)
    #expect(groups[0].name == "Fold")
    #expect(groups[0].axisCount == 3)
}

// BindableParams deriver ----------------------------------------------------

@Test func deriveSortsIntoVectorsScalarsAndGroups() {
    let entries = [
        vec3Entry(firstContentSlot, key: "de.f.pos", label: "Position"),
        scalarEntry(firstContentSlot + 3, key: "de.f.power", label: "Power"),
        scalarEntry(firstContentSlot + 4, key: "de.f.Warp.x", label: "Warp.x"),
        scalarEntry(firstContentSlot + 5, key: "de.f.Warp.y", label: "Warp.y"),
        scalarEntry(firstContentSlot + 6, key: "de.f.Warp.z", label: "Warp.z"),
    ]
    let p = BindableParams.derive(from: entries)
    #expect(p.vectors.map(\.key) == [ParamKey("de.f.pos")])
    #expect(p.scalars.count == 4)                       // power + 3 warp components
    #expect(p.groups.count == 1)                        // Warp x/y/z
    #expect(p.groups[0].name == "Warp")
    #expect(p.label(for: ParamKey("de.f.pos")) == "Position")
    #expect(p.label(for: ParamKey("unknown")) == "unknown")   // falls back to raw
}

@Test func deriveExcludesBoolsAndEnums() {
    let entries = [
        scalarEntry(firstContentSlot, key: "s", label: "Scalar"),
        CatalogEntry(slot: firstContentSlot + 1, spec: ParamSpec(
            key: ParamKey("b"), label: "Flag", kind: .bool, range: 0...1, default: 0)),
        CatalogEntry(slot: firstContentSlot + 2, spec: ParamSpec(
            key: ParamKey("e"), label: "Mode", kind: .enumeration(caseCount: 3),
            range: 0...2, default: 0)),
    ]
    let p = BindableParams.derive(from: entries)
    #expect(p.scalars.map(\.key) == [ParamKey("s")])
    #expect(p.vectors.isEmpty)
}

// GestureBindingSet (per-fractal) -------------------------------------------

@Test func setStoresPerFractalAndPrunesEmpty() {
    var set = GestureBindingSet()
    let src = GestureSource.tapThumb(hand: .right, finger: .index)
    set.setBinding(.vector(.native(ParamKey("de.a.pos"))), for: src, scope: .fractal("mandelbulb"))
    #expect(set.resolvedBinding(for: src, fractal: "mandelbulb") != nil)
    #expect(set.resolvedBinding(for: src, fractal: "mandelbox") == nil)   // isolated per fractal

    // Clearing the last binding prunes the fractal's table entirely.
    set.setBinding(nil, for: src, scope: .fractal("mandelbulb"))
    #expect(set.isEmpty)
}

@Test func setRoundTripsThroughJSON() throws {
    var set = GestureBindingSet()
    set.setBinding(.scalar(ParamKey("engine.aoStrength")),
                   for: .fist(hand: .left), scope: .fractal("mandelbox"))
    set.setBinding(.vector(.grouped(x: ParamKey("a.x"), y: nil, z: ParamKey("a.z"))),
                   for: .swipe(hand: .right), scope: .global)
    let data = try JSONEncoder().encode(set)
    let decoded = try JSONDecoder().decode(GestureBindingSet.self, from: data)
    #expect(decoded == set)
}

// Global vs per-fractal scope -----------------------------------------------

@Test func globalBindingAppliesToAllFractalsUntilOverridden() {
    var set = GestureBindingSet()
    let src = GestureSource.tapThumb(hand: .right, finger: .index)
    set.setBinding(.scalar(ParamKey("g")), for: src, scope: .global)
    // Global reaches every fractal.
    #expect(set.resolvedBinding(for: src, fractal: "mandelbulb") == .scalar(ParamKey("g")))
    #expect(set.resolvedBinding(for: src, fractal: "mandelbox") == .scalar(ParamKey("g")))
    #expect(set.scope(of: src, fractal: "mandelbulb") == .global)

    // A fractal-specific binding overrides global for THAT fractal only.
    set.setBinding(.scalar(ParamKey("mb")), for: src, scope: .fractal("mandelbox"))
    #expect(set.resolvedBinding(for: src, fractal: "mandelbox") == .scalar(ParamKey("mb")))
    #expect(set.resolvedBinding(for: src, fractal: "mandelbulb") == .scalar(ParamKey("g")))
    #expect(set.scope(of: src, fractal: "mandelbox") == .fractal("mandelbox"))
}

@Test func resolvedTableMergesGlobalUnderFractal() {
    var set = GestureBindingSet()
    let a = GestureSource.fist(hand: .left)
    let b = GestureSource.fist(hand: .right)
    set.setBinding(.scalar(ParamKey("ga")), for: a, scope: .global)
    set.setBinding(.scalar(ParamKey("gb")), for: b, scope: .global)
    set.setBinding(.scalar(ParamKey("fb")), for: b, scope: .fractal("mbox"))

    let merged = set.resolvedTable(forFractal: "mbox")
    #expect(merged.binding(for: a) == .scalar(ParamKey("ga")))   // global survives
    #expect(merged.binding(for: b) == .scalar(ParamKey("fb")))   // fractal wins
}

@Test func setScopeMovesBindingBetweenScopes() {
    var set = GestureBindingSet()
    let src = GestureSource.swipe(hand: .left)
    set.setBinding(.scalar(ParamKey("p")), for: src, scope: .fractal("mbox"))
    // Promote to global — leaves the fractal scope, lands in global.
    set.setScope(.global, for: src, fractal: "mbox")
    #expect(set.binding(for: src, scope: .fractal("mbox")) == nil)
    #expect(set.binding(for: src, scope: .global) == .scalar(ParamKey("p")))
    #expect(set.resolvedBinding(for: src, fractal: "anything") == .scalar(ParamKey("p")))
}
