// PersistenceTests.swift — scene envelope, catalog-walk codec, lane-scoped
// apply, unknown-content preservation, and the migration scaffold
// (plan §7.1/§7.3, ARCHITECTURE.md §7).

import Foundation
import Testing

@testable import ThresholdCore

// MARK: - Fixtures

/// A catalog exercising every ParamKind and every Persistence tier.
private func persistenceFixture() throws -> (CatalogLayout, ModulationEngine, FixedStepClock) {
    let catalog = Catalog()
    try catalog.register(ParamSpec(
        key: ParamKey("shape.power"), label: "Power", range: 1...16, default: 8))
    try catalog.register(ParamSpec(
        key: ParamKey("shape.enabled"), label: "Enabled", kind: .bool, range: 0...1, default: 1,
        composition: .replace))
    try catalog.register(ParamSpec(
        key: ParamKey("color.mode"), label: "Mode", kind: .enumeration(caseCount: 6),
        range: 0...5, default: 0, composition: .replace))
    try catalog.register(ParamSpec(
        key: ParamKey("color.tint"), label: "Tint", kind: .float3, range: 0...1,
        defaultValue: [1, 0.5, 0.25]))
    try catalog.register(ParamSpec(
        key: ParamKey("hand.shaping"), label: "Hand Shaping", kind: .float4, range: 0...2,
        defaultValue: [1, 0.3, 0.5, 0.2]))
    try catalog.register(ParamSpec(
        key: ParamKey("perf.quality"), label: "Quality", range: 0...1, default: 1,
        persistence: .deviceLocal))
    try catalog.register(ParamSpec(
        key: ParamKey("debug.probe"), label: "Probe", range: 0...1, default: 0,
        persistence: .transient))
    // Integrator pair: scene-persisted phase driven by a rate param.
    try catalog.register(ParamSpec(
        key: ParamKey("color.hueSpeed"), label: "Hue Speed", range: -10...10, default: 0.5))
    try catalog.register(ParamSpec(
        key: ParamKey("color.huePhase"), label: "Hue Phase", range: 0...(2 * Float.pi),
        default: 0, integratorRateKey: ParamKey("color.hueSpeed")))

    let layout = catalog.freeze(dynamicArenaSlots: 0)
    let clock = FixedStepClock()
    return (layout, ModulationEngine(layout: layout, clock: clock), clock)
}

private let sceneKeys = [
    "shape.power", "shape.enabled", "color.mode", "color.tint", "hand.shaping",
    "color.hueSpeed", "color.huePhase",
]

// MARK: - Round trip

@Suite("Scene round trip")
struct SceneRoundTripSuite {
    @Test("Catalog walk: every .scene param round-trips; other tiers excluded")
    func roundTrip() throws {
        let (layout, engine, clock) = try persistenceFixture()

        // Distinct scene values per key (vectors get distinct components).
        var written: [String: [Float]] = [:]
        var v: Float = 1.25
        for entry in layout.entries where entry.spec.persistence == .scene {
            var components = [Float]()
            for _ in 0..<entry.kind.slotWidth {
                let clamped = min(max(v, entry.spec.range.lowerBound), entry.spec.range.upperBound)
                components.append(clamped)
                v += 0.5
            }
            engine.write(lane: .scene, key: entry.key, values: components)
            written[entry.key.rawValue] = components
        }
        clock.advance()
        _ = engine.resolve()  // scene lane is instant; resolve settles current = target

        let envelope = SceneCodec.snapshot(
            layout: layout, engine: engine, fractalTypeKey: "mandelbulb",
            warpStack: [WarpOpDTO(kind: 1, strength: 0.5, a: [0, 1, 0, 0], b: [0, 0, 0, 0])],
            name: "roundtrip")
        let data = try SceneCodec.encode(envelope)
        let decoded = try SceneCodec.decode(data)

        #expect(decoded == envelope)
        for key in sceneKeys {
            #expect(decoded.params[key] == written[key], "param \(key) did not round-trip")
        }
        // Non-scene tiers are structurally excluded from the file.
        #expect(decoded.params["perf.quality"] == nil)
        #expect(decoded.params["debug.probe"] == nil)

        // Apply into a FRESH engine reproduces the scene lane.
        let (_, fresh, freshClock) = try persistenceFixture()
        let report = SceneCodec.apply(decoded, layout: layout, engine: fresh)
        #expect(report.appliedCount == sceneKeys.count)
        #expect(report.unknownParams.isEmpty)
        freshClock.advance()
        _ = fresh.resolve()
        for entry in layout.entries where entry.spec.persistence == .scene {
            for (i, slot) in entry.slotRange.enumerated() {
                #expect(
                    fresh.currentValue(lane: .scene, slot: slot) == written[entry.key.rawValue]?[i],
                    "\(entry.key) component \(i)")
            }
        }
    }

    @Test("Encoding is deterministic (sorted keys, stable bytes)")
    func deterministicBytes() throws {
        let (layout, engine, _) = try persistenceFixture()
        let envelope = SceneCodec.snapshot(layout: layout, engine: engine, fractalTypeKey: "m")
        #expect(try SceneCodec.encode(envelope) == SceneCodec.encode(envelope))
    }

    @Test("Integrator phase snapshots and restores")
    func integratorPhase() throws {
        let (layout, engine, clock) = try persistenceFixture()
        clock.advance(frames: 30)  // 0.5 s at rate 0.5 → phase 0.25
        _ = engine.resolve()
        for _ in 0..<29 { clock.advance(); _ = engine.resolve() }

        let phaseSlot = try #require(layout.slot(for: ParamKey("color.huePhase")))
        let livePhase = try #require(engine.readIntegratorPhase(slot: phaseSlot))
        #expect(livePhase > 0)

        let envelope = SceneCodec.snapshot(layout: layout, engine: engine, fractalTypeKey: "m")
        #expect(envelope.integratorPhases["color.huePhase"] == livePhase)

        let (_, fresh, _) = try persistenceFixture()
        SceneCodec.apply(envelope, layout: layout, engine: fresh)
        #expect(fresh.readIntegratorPhase(slot: phaseSlot) == livePhase)
    }
}

// MARK: - Unknown content preservation

@Suite("Forward compatibility")
struct ForwardCompatSuite {
    private func futureSceneJSON() -> Data {
        Data("""
        {
          "version": 1,
          "fractalTypeKey": "mandelbulb",
          "params": {
            "shape.power": [9],
            "future.newParam": [1, 2],
            "future.richParam": {"mode": "fancy", "amount": 3}
          },
          "warpStack": [],
          "camera": {"position": [0, 0, 3], "orientation": [0, 0, 0, 1], "fovYRadians": 1.0472},
          "futureTopLevel": {"nested": [1, 2, 3], "flag": true}
        }
        """.utf8)
    }

    @Test("Unknown top-level keys, numeric params, and rich params all survive re-save")
    func unknownPreserved() throws {
        let decoded = try SceneCodec.decode(futureSceneJSON())
        #expect(decoded.unknown["futureTopLevel"] != nil)
        #expect(decoded.params["future.newParam"] == [1, 2])
        #expect(decoded.foreignParams["future.richParam"] != nil)

        let resaved = try SceneCodec.decode(SceneCodec.encode(decoded))
        #expect(resaved == decoded)
        #expect(resaved.unknown["futureTopLevel"] ==
            .object(["nested": .array([.number(1), .number(2), .number(3)]), "flag": .bool(true)]))
    }

    @Test("Apply warns on unknown/foreign params without dropping them")
    func applyReportsUnknown() throws {
        let (layout, engine, _) = try persistenceFixture()
        let decoded = try SceneCodec.decode(futureSceneJSON())
        let report = SceneCodec.apply(decoded, layout: layout, engine: engine)
        #expect(report.appliedCount == 1)  // shape.power
        #expect(report.unknownParams == ["future.newParam"])
        #expect(report.foreignParams == ["future.richParam"])
    }

    @Test("Bare-number param values normalize to 1-element arrays")
    func bareNumberNormalizes() throws {
        let data = Data(
            #"{"version": 1, "fractalTypeKey": "m", "params": {"shape.power": 9}}"#.utf8)
        let decoded = try SceneCodec.decode(data)
        #expect(decoded.params["shape.power"] == [9])
    }
}

// MARK: - Lane-scoped apply

@Suite("Scene apply is lane-scoped and authoritative")
struct SceneApplySuite {
    @Test("Apply writes only the scene lane; user offsets survive (Invariant 11)")
    func userOffsetSurvives() throws {
        let (layout, engine, clock) = try persistenceFixture()
        let powerKey = ParamKey("shape.power")

        engine.write(lane: .user, key: powerKey, values: [2])  // additive offset
        var envelope = SceneCodec.snapshot(layout: layout, engine: engine, fractalTypeKey: "m")
        envelope.params["shape.power"] = [10]

        SceneCodec.apply(envelope, layout: layout, engine: engine)
        clock.advance()
        let resolved = engine.resolve()
        let slot = try #require(layout.slot(for: powerKey))
        #expect(resolved.values[slot] == 12)  // new base 10 + surviving user offset 2
        #expect(engine.currentValue(lane: .user, slot: slot) == 2)
    }

    @Test("Authoritative apply clears .scene params absent from the file")
    func authoritativeClears() throws {
        let (layout, engine, clock) = try persistenceFixture()
        let tintKey = ParamKey("color.tint")
        engine.write(lane: .scene, key: tintKey, values: [0.9, 0.9, 0.9])
        clock.advance()
        _ = engine.resolve()

        var envelope = SceneCodec.snapshot(layout: layout, engine: engine, fractalTypeKey: "m")
        envelope.params.removeValue(forKey: "color.tint")

        SceneCodec.apply(envelope, layout: layout, engine: engine)
        let slot = try #require(layout.slot(for: tintKey))
        #expect(engine.currentValue(lane: .scene, slot: slot) == nil)  // back to default base

        // Overlay mode keeps it.
        engine.write(lane: .scene, key: tintKey, values: [0.9, 0.9, 0.9])
        SceneCodec.apply(envelope, layout: layout, engine: engine, authoritative: false)
        clock.advance()
        _ = engine.resolve()  // settle the instant scene lane before reading
        #expect(engine.currentValue(lane: .scene, slot: slot) == 0.9)
    }

    @Test("Non-scene-persisted params in a file are skipped by policy")
    func nonSceneSkipped() throws {
        let (layout, engine, _) = try persistenceFixture()
        var envelope = SceneCodec.snapshot(layout: layout, engine: engine, fractalTypeKey: "m")
        envelope.params["perf.quality"] = [0.1]

        let report = SceneCodec.apply(envelope, layout: layout, engine: engine)
        #expect(report.skippedNonScene == ["perf.quality"])
        let slot = try #require(layout.slot(for: ParamKey("perf.quality")))
        #expect(engine.currentValue(lane: .scene, slot: slot) == nil)
    }

    @Test("Component-count mismatches are reported, not applied")
    func componentMismatch() throws {
        let (layout, engine, _) = try persistenceFixture()
        var envelope = SceneCodec.snapshot(layout: layout, engine: engine, fractalTypeKey: "m")
        envelope.params["color.tint"] = [1]  // float3 param, 1 component

        let report = SceneCodec.apply(envelope, layout: layout, engine: engine)
        #expect(report.componentMismatches == ["color.tint"])
        let slot = try #require(layout.slot(for: ParamKey("color.tint")))
        #expect(engine.currentValue(lane: .scene, slot: slot) == nil)
    }
}

// MARK: - Versioning & migration

@Suite("Versioning & migration")
struct MigrationSuite {
    @Test("Migration table rewrites old keys and the codec bumps versions")
    func migrationRuns() throws {
        // A "version 0" file using a retired param key.
        let old = Data(
            #"{"version": 0, "fractalTypeKey": "m", "params": {"shape.msp.radius": [2]}}"#.utf8)
        let migrations = [
            SceneMigration(fromVersion: 0) { tree in
                guard case .object(var params)? = tree["params"] else { return }
                if let value = params.removeValue(forKey: "shape.msp.radius") {
                    params["warp.sphereProject.radius"] = value
                }
                tree["params"] = .object(params)
            }
        ]
        let decoded = try SceneCodec.decode(old, migrations: migrations)
        #expect(decoded.version == SceneCodec.currentVersion)
        #expect(decoded.params["warp.sphereProject.radius"] == [2])
        #expect(decoded.params["shape.msp.radius"] == nil)
    }

    @Test("Newer-format files are rejected, not mangled")
    func unsupportedVersion() {
        let future = Data(#"{"version": 99, "fractalTypeKey": "m"}"#.utf8)
        #expect(throws: SceneCodecError.unsupportedVersion(99)) {
            try SceneCodec.decode(future)
        }
    }

    @Test("A gap in the migration table is an explicit error")
    func missingMigration() {
        let old = Data(#"{"version": 0, "fractalTypeKey": "m"}"#.utf8)
        #expect(throws: SceneCodecError.missingMigration(from: 0)) {
            try SceneCodec.decode(old, migrations: [])
        }
    }

    @Test("Malformed input throws malformed, never traps")
    func malformed() {
        #expect(throws: SceneCodecError.self) { try SceneCodec.decode(Data("not json".utf8)) }
        #expect(throws: SceneCodecError.self) { try SceneCodec.decode(Data("[1, 2]".utf8)) }
        #expect(throws: SceneCodecError.self) {
            try SceneCodec.decode(Data(#"{"fractalTypeKey": "m"}"#.utf8))  // no version
        }
    }
}

// MARK: - DTO validation

@Suite("Envelope DTOs")
struct EnvelopeDTOSuite {
    @Test("WarpOpDTO rejects malformed payload counts on decode")
    func warpOpValidation() throws {
        let bad = Data(
            #"{"kind": 1, "strength": 1, "a": [1, 2], "b": [0, 0, 0, 0]}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WarpOpDTO.self, from: bad)
        }
    }

    @Test("CameraDTO rejects malformed component counts on decode")
    func cameraValidation() throws {
        let bad = Data(
            #"{"position": [0, 0], "orientation": [0, 0, 0, 1], "fovYRadians": 1}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CameraDTO.self, from: bad)
        }
    }
}
