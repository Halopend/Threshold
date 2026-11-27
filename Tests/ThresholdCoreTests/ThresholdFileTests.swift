// ThresholdFileTests.swift — the one open-a-file entry point (plan §7.4).

import Foundation
import Testing
import ThresholdCore

@Suite("File open classification")
struct ThresholdFileTests {
    @Test func sceneDecodesByExtension() throws {
        let data = try SceneCodec.encode(SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "mandelbox"))
        let file = try ThresholdFile.decode(data, filename: "My Scene.threshscene")
        guard case .scene(let envelope) = file else {
            Issue.record("expected .scene")
            return
        }
        #expect(envelope.fractalTypeKey == "mandelbox")
    }

    @Test func animationDecodesByExtension() throws {
        let clip = AnimationClip(name: "spin", loop: .loop, duration: 4, tracks: [])
        let data = try AnimationCodec.encode(AnimationEnvelope(clip: clip))
        let file = try ThresholdFile.decode(data, filename: "spin.THRESHANIM")
        guard case .animation(let envelope) = file else {
            Issue.record("expected .animation")
            return
        }
        #expect(envelope.clip.name == "spin")
        #expect(envelope.clip.effectiveDuration == 4)
    }

    @Test func unsupportedExtensionThrowsListingSupportedTypes() {
        #expect(throws: ThresholdFile.OpenError.unsupportedType("")) {
            _ = try ThresholdFile.decode(Data(), filename: "extensionless")
        }
    }

    @Test func codecErrorsPropagateWithDiagnostics() {
        #expect(throws: SceneCodecError.self) {
            _ = try ThresholdFile.decode(
                Data("not json".utf8), filename: "bad.threshscene")
        }
        #expect(throws: SceneCodecError.self) {
            _ = try ThresholdFile.decode(
                Data("{}".utf8), filename: "versionless.threshanim")
        }
    }

    @Test func bindingMapDecodesByExtension() throws {
        let binding = Binding(
            signal: .audioRMS, param: .colorSaturation, lane: .music)
        let data = try BindingCodec.encode(BindingMapEnvelope(bindings: [binding]))
        let file = try ThresholdFile.decode(data, filename: "map.threshmp")
        guard case .bindings(let envelope) = file else {
            Issue.record("expected .bindings")
            return
        }
        #expect(envelope.bindings == [binding])
    }

    @Test func warpRecipeDecodesByExtension() throws {
        let op = WarpOpDTO(
            kind: 1, strength: 0.75,
            a: [0, 1, 0, 0], b: [0, 0, 0, 0])
        let data = try WarpRecipeCodec.encode(WarpRecipeEnvelope(
            name: "Twist", warpStack: [op]))
        let file = try ThresholdFile.decode(data, filename: "Twist.THRESHFX")
        guard case .warpRecipe(let envelope) = file else {
            Issue.record("expected .warpRecipe")
            return
        }
        #expect(envelope.name == "Twist")
        #expect(envelope.warpStack == [op])
        #expect(ThresholdFile.supportedExtensions.contains("threshfx"))
    }

    @Test func legacySceneMigratesThroughTheSamePath() throws {
        // A legacy (version-less, fractalType-keyed) file opens through the
        // same entry point — the migration walk is inside SceneCodec.
        let legacy = Data(#"{"fractalType": "mandelbox", "fractalScale": 2.5}"#.utf8)
        let file = try ThresholdFile.decode(legacy, filename: "old.threshscene")
        guard case .scene(let envelope) = file else {
            Issue.record("expected .scene")
            return
        }
        #expect(envelope.fractalTypeKey == "legacyMandelbox")
        #expect(envelope.params["de.legacyMandelbox.scale"] == [2.5])
    }

    // MARK: legacy menger / theliPseudoKleinian (the ThresholdKit port)

    /// The Menger_Drift real scene's formulaParamValues[0...3].
    private let realMengerValues: [Double] =
        [2.0281808, 2.5051615, 1.5245535, 0.9270368,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    /// The Hold real scene's menger values — scale 1 with an offset the
    /// rebuild's declared range (0…4) later clamps at resolution. Both scenes
    /// carry the 16-float legacy array; menger reads only [0...3].
    private let holdMengerValues: [Double] =
        [1, 14.101999, 1, 3, 0.48709917, 1.869392, 0, 1.6070724,
         0, 0, 0, 0, 0, 0, 0, 0]
    /// The Warp_V2 real scene's theli values (mnIterations 0.529… truncates
    /// to 0 in the DE, matching the legacy int() truncation).
    private let warpv2TheliValues: [Double] =
        [2, 1.1239072, 1.225502, 1.1325724, 0, 0, 0, 0.025867915,
         0, 0, 0, 0.52917045, 3, 1, 1, 1]

    @Test func legacyMengerTypeMapsToMengerSponge() throws {
        // fractalType "menger" → "mengerSponge" (the legacy Menger.h documents
        // that DE as numerically identical), formulaParamValues[0...3] →
        // de.mengerSponge.{scale,offsetX,offsetY,offsetZ} positionally.
        let tree: [String: JSONValue] = [
            "fractalType": .string("menger"),
            "fractalIterations": .number(38),
            "maxRaySteps": .number(64),
            "formulaParamValues": .array(realMengerValues.map { .number($0) }),
        ]
        let data = try JSONEncoder().encode(JSONValue.object(tree))
        let file = try ThresholdFile.decode(data, filename: "menger.threshscene")
        guard case .scene(let envelope) = file else {
            Issue.record("expected .scene")
            return
        }
        #expect(envelope.fractalTypeKey == "mengerSponge")
        #expect(envelope.params["de.mengerSponge.scale"] == [2.0281808])
        #expect(envelope.params["de.mengerSponge.offsetX"] == [2.5051615])
        #expect(envelope.params["de.mengerSponge.offsetY"] == [1.5245535])
        #expect(envelope.params["de.mengerSponge.offsetZ"] == [0.9270368])
        #expect(envelope.params[ParamKey.engineIterations.rawValue] == [38])
        // Round-trip is stable.
        let again = try ThresholdFile.decode(
            try SceneCodec.encode(envelope), filename: "again.threshscene")
        guard case .scene(let second) = again else {
            Issue.record("expected .scene")
            return
        }
        #expect(second == envelope)
    }

    @Test func legacyHoldMengerParamsPreserveRawValues() throws {
        // The Hold scene stores an out-of-declared-range offset (14.102 > the
        // rebuild's 0…4 slider span). The migration must store it RAW —
        // resolution clamps later, and at scale 1 the offset is mathematically
        // inert, so the rendered look is unaffected either way.
        let tree: [String: JSONValue] = [
            "fractalType": .string("menger"),
            "fractalIterations": .number(24),
            "maxRaySteps": .number(64),
            "formulaParamValues": .array(holdMengerValues.map { .number($0) }),
        ]
        let data = try JSONEncoder().encode(JSONValue.object(tree))
        let file = try ThresholdFile.decode(data, filename: "Hold.threshscene")
        guard case .scene(let envelope) = file else {
            Issue.record("expected .scene")
            return
        }
        #expect(envelope.fractalTypeKey == "mengerSponge")
        #expect(envelope.params["de.mengerSponge.scale"] == [1])
        #expect(envelope.params["de.mengerSponge.offsetX"] == [14.101999])
        #expect(envelope.params["de.mengerSponge.offsetY"] == [1])
        #expect(envelope.params["de.mengerSponge.offsetZ"] == [3])
        // ...and the engine quality scalars migrate alongside.
        #expect(envelope.params[ParamKey.engineIterations.rawValue] == [24])
        #expect(envelope.params[ParamKey.engineMaxSteps.rawValue] == [64])
        let again = try ThresholdFile.decode(
            try SceneCodec.encode(envelope), filename: "again.threshscene")
        guard case .scene(let second) = again else {
            Issue.record("expected .scene")
            return
        }
        #expect(second == envelope)
    }

    @Test func legacyTheliSceneMigratesPositionallyAndRoundTrips() throws {
        // fractalType "theliPseudoKleinian" passes through by name; the 16
        // formulaParamValues map onto the declared param layout 1:1 —
        // mnIterations ([11]) is a declared DE param, not the engine cap.
        let tree: [String: JSONValue] = [
            "fractalType": .string("theliPseudoKleinian"),
            "fractalIterations": .number(7),
            "maxRaySteps": .number(88),
            "worldRotationX": .number(-0.7138664),
            "worldRotationY": .number(0.0010508186),
            "worldRotationZ": .number(-0.0010692988),
            "worldRotationW": .number(-0.70028037),
            "formulaParamValues": .array(warpv2TheliValues.map { .number($0) }),
        ]
        let data = try JSONEncoder().encode(JSONValue.object(tree))
        let file = try ThresholdFile.decode(data, filename: "Warp_V2.threshscene")
        guard case .scene(let envelope) = file else {
            Issue.record("expected .scene")
            return
        }
        let key = "theliPseudoKleinian"
        #expect(envelope.fractalTypeKey == key)
        // The declared layout: 16 params in the legacy formulaParamValues order.
        let names = [
            "size", "cSizeX", "cSizeY", "cSizeZ",
            "cX", "cY", "cZ", "deOffset",
            "offsetX", "offsetY", "offsetZ",
            "mnIterations", "mnScale", "mnOffsetX", "mnOffsetY", "mnOffsetZ",
        ]
        for (i, name) in names.enumerated() {
            let value = try #require(
                envelope.params["de.\(key).\(name)"]?.first,
                "missing de.\(key).\(name)")
            #expect(abs(value - Float(warpv2TheliValues[i])) < 1e-6,
                    "de.\(key).\(name) = \(value), expected \(warpv2TheliValues[i])")
        }
        // The legacy sub-fold loop cap is a DE param; the scene iterations is
        // the shared engine cap.
        #expect(envelope.params["de.\(key).mnIterations"] == [0.52917045])
        #expect(envelope.params[ParamKey.engineIterations.rawValue] == [7])
        let again = try ThresholdFile.decode(
            try SceneCodec.encode(envelope), filename: "again.threshscene")
        guard case .scene(let second) = again else {
            Issue.record("expected .scene")
            return
        }
        #expect(second == envelope)
    }

    @Test func legacyTheliDefaultParamsMatchTheLegacyCatalog() throws {
        // w_35AB0B54 carries the legacy catalog defaults — the migration maps
        // them onto de.theliPseudoKleinian.* positionally. (The DERegistry
        // defaults equal these values too; asserted in DETests.)
        let names = [
            "size", "cSizeX", "cSizeY", "cSizeZ",
            "cX", "cY", "cZ", "deOffset",
            "offsetX", "offsetY", "offsetZ",
            "mnIterations", "mnScale", "mnOffsetX", "mnOffsetY", "mnOffsetZ",
        ]
        let values: [Double] = [
            1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 2, 3, 1, 1, 1,
        ]
        #expect(names.count == values.count)
        let tree: [String: JSONValue] = [
            "fractalType": .string("theliPseudoKleinian"),
            "formulaParamValues": .array(values.map { .number($0) }),
        ]
        let data = try JSONEncoder().encode(JSONValue.object(tree))
        let file = try ThresholdFile.decode(data, filename: "w.threshscene")
        guard case .scene(let envelope) = file else {
            Issue.record("expected .scene")
            return
        }
        for (name, value) in zip(names, values) {
            #expect(envelope.params["de.theliPseudoKleinian.\(name)"] == [Float(value)],
                    "de.theliPseudoKleinian.\(name) default drifted")
        }
    }

    @Test func retiredLegacyTypesFallBackLikeTheShippingApp() throws {
        // `bulatovLimitSet` (raw 22) and `boxSphereFolder` (raw 20) were
        // REMOVED from the shipping app's FractalModelType too — its decoder
        // back-compat maps them to `.mandelbox`. Mirror that: they decode
        // here as legacyMandelbox (mandelbox-shaped top-level fields, so the
        // legacy mandelbox param mapping applies).
        let tree: [String: JSONValue] = [
            "fractalType": .string("bulatovLimitSet"),
            "fractalScale": .number(2.56),
            "foldingLimit": .number(1.0),
            "sphereRadius": .number(0.5),
            "minDistance": .number(0.8),
            "fractalIterations": .number(12),
            "maxRaySteps": .number(300),
        ]
        let data = try JSONEncoder().encode(JSONValue.object(tree))
        let file = try ThresholdFile.decode(
            data, filename: "Bulatov Limit Set.threshscene")
        guard case .scene(let envelope) = file else {
            Issue.record("expected .scene")
            return
        }
        #expect(envelope.fractalTypeKey == "legacyMandelbox")
        #expect(envelope.params["de.legacyMandelbox.scale"] == [2.56])
        #expect(envelope.params["de.legacyMandelbox.foldLimit"] == [1.0])
        #expect(envelope.params["de.legacyMandelbox.sphereRadius"] == [0.5])
        #expect(envelope.params["de.legacyMandelbox.minDistance"] == [0.8])
        #expect(envelope.params[ParamKey.engineIterations.rawValue] == [12])
        #expect(envelope.params[ParamKey.engineMaxSteps.rawValue] == [300])
        let again = try ThresholdFile.decode(
            try SceneCodec.encode(envelope), filename: "again.threshscene")
        guard case .scene(let second) = again else {
            Issue.record("expected .scene")
            return
        }
        #expect(second == envelope)
    }
}
