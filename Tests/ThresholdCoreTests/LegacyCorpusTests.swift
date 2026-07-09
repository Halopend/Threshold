// LegacyCorpusTests.swift — replay every REAL original-app scene file
// (Corpus/legacy/scenes/, captured from TEMP/MetalRaymarch-main 2026-07-02)
// through the 0→1 migration per commit (plan §7.3/§9 — "capture the corpus
// early"; the original's Disguise/Vampire field loss is the cautionary tale).

import Foundation
import Testing

@testable import ThresholdCore

@Suite("Legacy scene corpus")
struct LegacyCorpusTests {
    private var scenesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ThresholdCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Corpus/legacy/scenes")
    }

    private func corpusFiles() throws -> [URL] {
        let files = try FileManager.default
            .contentsOfDirectory(at: scenesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "threshscene" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!files.isEmpty, "legacy corpus missing at \(scenesDir.path)")
        return files
    }

    @Test("Every legacy scene decodes, applies, and round-trips")
    func corpusReplay() throws {
        let clock = FixedStepClock()
        let engine = try makeEngine([spec("x.y")], clock: clock)

        for file in try corpusFiles() {
            let data = try Data(contentsOf: file)
            let envelope: SceneEnvelope
            do {
                envelope = try SceneCodec.decode(data)
            } catch {
                Issue.record("\(file.lastPathComponent): decode failed: \(error)")
                continue
            }

            #expect(envelope.version == SceneCodec.currentVersion, Comment(rawValue: file.lastPathComponent))
            #expect(!envelope.fractalTypeKey.isEmpty, Comment(rawValue: file.lastPathComponent))
            // Every consumed-or-not legacy key must survive (never delete):
            // fractalType is always present in the originals and is NOT a
            // known envelope key, so it must land in `unknown`.
            #expect(envelope.unknown["fractalType"] != nil, Comment(rawValue: file.lastPathComponent))

            // Apply must never crash; unknown catalog params are report
            // entries, not errors.
            _ = SceneCodec.apply(envelope, layout: engine.layout, engine: engine)

            // Round-trip: encode → decode is stable and loses nothing.
            let reencoded = try SceneCodec.encode(envelope)
            let second = try SceneCodec.decode(reencoded)
            #expect(second == envelope, Comment(rawValue: file.lastPathComponent))
        }
    }

    @Test("Stress_test: coxeter op maps kind and payload")
    func stressTestSceneMapping() throws {
        let data = try Data(
            contentsOf: scenesDir.appendingPathComponent("Stress_test.threshscene"))
        let envelope = try SceneCodec.decode(data)
        #expect(envelope.fractalTypeKey == "kleinian")
        // Legacy: one enabled op {type: 11 coxeter, p1: 3, p2: 3}.
        try #require(envelope.warpStack.count == 1)
        let op = envelope.warpStack[0]
        #expect(op.kind == 8)  // rebuild coxeter
        #expect(op.a[0] == 3 && op.a[1] == 3)  // p, q
    }

    @Test("Crystal Palace: palette, grading params, camera")
    func crystalPalaceMapping() throws {
        let data = try Data(
            contentsOf: scenesDir.appendingPathComponent("Crystal Palace.threshscene"))
        let envelope = try SceneCodec.decode(data)
        let palette = try #require(envelope.palette)
        #expect(palette.stops.count >= 2)
        #expect(envelope.params[ParamKey.colorSaturation.rawValue]?.count == 1)
        #expect(envelope.params[ParamKey.engineIterations.rawValue] == [8])
        // Legacy position [x, y, z] became the camera position.
        #expect(envelope.camera.position.count == 3)
        #expect(envelope.camera.position != CameraDTO.default.position)
    }

    @Test("Stress_test: kleinian formulaParamValues map positionally to de.kleinian.*")
    func kleinianFormulaParams() throws {
        let data = try Data(
            contentsOf: scenesDir.appendingPathComponent("Stress_test.threshscene"))
        let envelope = try SceneCodec.decode(data)
        // Legacy formulaParamValues[0...7]:
        // [-0.7129297, -0.8780583, 0.07105777, 2.9999967, …]
        let minX = try #require(envelope.params["de.kleinian.minX"]?.first)
        #expect(abs(minX - -0.7129297) < 1e-6)
        let sphereFold = try #require(envelope.params["de.kleinian.sphereFold"]?.first)
        #expect(abs(sphereFold - 2.9999967) < 1e-6)
        #expect(envelope.params["de.kleinian.crossRadius"]?.count == 1)
    }

    @Test("Blue hero: mandelboxSphereProjection DE shape from formulaParamValues + zoom migrate")
    func mandelboxScaleAndZoomMapping() throws {
        let data = try Data(
            contentsOf: scenesDir.appendingPathComponent("Blue hero.threshscene"))
        let envelope = try SceneCodec.decode(data)
        // Legacy MSP stores shape in formulaParamValues:
        // [minDistance, foldingLimit, sphereRadius, fractalScale, blend, radius].
        let key = "mandelboxSphereProjection"
        #expect(envelope.fractalTypeKey == key)
        let scale = try #require(envelope.params["de.\(key).scale"]?.first)
        #expect(abs(scale - Float(4.9319124 / 0.702063)) < 1e-5)
        #expect(envelope.params["de.\(key).foldLimit"] == [3.6218371])
        #expect(envelope.params["de.\(key).fixedRadius"] == [1])
        let minRadius = try #require(envelope.params["de.\(key).minRadius"]?.first)
        #expect(abs(minRadius - 2.8280883) < 1e-5)
        #expect(envelope.params["de.\(key).projBlend"] == [1])
        #expect(envelope.params["de.\(key).projRadius"] == [1])
        // scale(1) × detailScale(1.4763585) → zoom octaves, in
        // integratorPhases (a params write would lose to the integrator).
        let zoom = try #require(envelope.integratorPhases[ParamKey.scaleZoom.rawValue])
        #expect(abs(zoom - log2(Float(1.4763585))) < 1e-5)
    }

    @Test("Paul: legacy Mandelbox sphere projection promotes to projected DE with atmosphere")
    func paulProjectedMandelboxMapping() throws {
        let data = try Data(
            contentsOf: scenesDir.appendingPathComponent("Pulsing.threshscene"))
        let envelope = try SceneCodec.decode(data)
        let key = "mandelboxSphereProjection"

        #expect(envelope.name == "Paul")
        #expect(envelope.fractalTypeKey == key)
        #expect(envelope.warpStack.isEmpty)
        #expect(abs(envelope.camera.position[0] - 0.892858) < 1e-5)
        #expect(abs(envelope.camera.position[1] - 2.6393511) < 1e-5)
        #expect(abs(envelope.camera.position[2] - 3.7964892) < 1e-5)
        let scale = try #require(envelope.params["de.\(key).scale"]?.first)
        #expect(abs(scale - Float(2.8 / 2.2960358)) < 1e-5)
        #expect(envelope.params["de.\(key).foldLimit"] == [1])
        #expect(envelope.params["de.\(key).minRadius"] == [0.01])
        #expect(envelope.params["de.\(key).fixedRadius"] == [1])
        #expect(envelope.params["de.\(key).projBlend"] == [0.3059373])
        #expect(envelope.params["de.\(key).projRadius"] == [4.1328073])

        #expect(envelope.params[ParamKey.atmosphereGlowEnabled.rawValue] == [1])
        #expect(envelope.params[ParamKey.atmosphereGlowIntensity.rawValue] == [0.37757903])
        #expect(envelope.params[ParamKey.atmosphereBloomEnabled.rawValue] == [1])
        #expect(envelope.params[ParamKey.atmosphereBloomStrength.rawValue] == [0.9135956])
        #expect(envelope.params[ParamKey.atmosphereFogEnabled.rawValue] == [1])
        #expect(envelope.params[ParamKey.atmosphereFogIntensity.rawValue] == [0.6014268])
        #expect(envelope.params[ParamKey.atmosphereFogColor.rawValue] == [0.01, 0.015, 0.02])
    }

    // MARK: .threshanim corpus

    private var animsDir: URL {
        scenesDir.deletingLastPathComponent().appendingPathComponent("anims")
    }

    @Test("Every legacy animation decodes into tracks and round-trips")
    func animCorpusReplay() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: animsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "threshanim" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!files.isEmpty, "legacy anim corpus missing at \(animsDir.path)")

        for file in files {
            let envelope = try AnimationCodec.decode(try Data(contentsOf: file))
            let name = Comment(rawValue: file.lastPathComponent)
            #expect(envelope.version == AnimationCodec.currentVersion, name)
            // Every corpus anim animates at least the shared engine params.
            #expect(!envelope.clip.tracks.isEmpty, name)
            #expect(envelope.clip.effectiveDuration >= 0, name)
            #expect(envelope.clip.loop == .loop, name)  // all corpus anims loop
            // Never delete: the raw keyframes survive in `unknown`.
            #expect(envelope.unknown["keyframes"] != nil, name)
            // Round-trip: encode → decode is stable.
            let again = try AnimationCodec.decode(try AnimationCodec.encode(envelope))
            #expect(again == envelope, name)
        }
    }

    @Test("Ambient_Blur: mandelbox tracks with cumulative times and easing")
    func ambientBlurTracks() throws {
        let data = try Data(
            contentsOf: animsDir.appendingPathComponent("Ambient_Blur.threshanim"))
        let envelope = try AnimationCodec.decode(data)
        let clip = envelope.clip

        let scaleTrack = try #require(
            clip.tracks.first { $0.param == .de("mandelbox", "scale") })
        #expect(scaleTrack.mode == .absolute)
        #expect(scaleTrack.keyframes.count == 8)
        // Keyframe 0: duration 0 → time 0; keyframe 1: duration 10 → time 10.
        #expect(scaleTrack.keyframes[0].time == 0)
        #expect(scaleTrack.keyframes[1].time == 10)
        #expect(abs(scaleTrack.keyframes[0].values[0] - Float(3.0075026 / 12.501993)) < 1e-5)
        // Legacy bezier easing → smooth segments.
        #expect(scaleTrack.keyframes[0].interpolation == .smooth)

        let minRadius = try #require(
            clip.tracks.first { $0.param == .de("mandelbox", "minRadius") })
        #expect(abs(minRadius.keyframes[0].values[0] - 0.31832752) < 1e-5)
        let fixedRadius = try #require(
            clip.tracks.first { $0.param == .de("mandelbox", "fixedRadius") })
        #expect(fixedRadius.keyframes[0].values[0] == 1)

        // Shared engine params always track.
        #expect(clip.tracks.contains { $0.param == .engineIterations })
    }

    @Test("Kaleidoscope: legacy projected Mandelbox animation targets projected DE params")
    func projectedMandelboxAnimationTracks() throws {
        let data = try Data(
            contentsOf: animsDir.appendingPathComponent("Kaleidoscope.threshanim"))
        let envelope = try AnimationCodec.decode(data)
        let clip = envelope.clip
        let key = "mandelboxSphereProjection"

        let scaleTrack = try #require(
            clip.tracks.first { $0.param == .de(key, "scale") })
        #expect(abs(scaleTrack.keyframes[0].values[0] - Float(4.9999847 / 0.9956826)) < 1e-5)

        let foldLimit = try #require(
            clip.tracks.first { $0.param == .de(key, "foldLimit") })
        #expect(abs(foldLimit.keyframes[0].values[0] - 0.3348397) < 1e-5)

        let minRadius = try #require(
            clip.tracks.first { $0.param == .de(key, "minRadius") })
        #expect(abs(minRadius.keyframes[0].values[0] - 3.4728134) < 1e-5)

        let projRadius = try #require(
            clip.tracks.first { $0.param == .de(key, "projRadius") })
        #expect(abs(projRadius.keyframes[0].values[0] - 0.87175786) < 1e-5)

        #expect(!clip.tracks.contains { $0.param.rawValue.hasPrefix("de.mandelbox.") })

        // Shared engine params always track.
        #expect(clip.tracks.contains { $0.param == .engineIterations })
    }

    // MARK: .threshmp corpus

    @Test("Every legacy binding map decodes and round-trips; sources/lanes are sane")
    func mapCorpusReplay() throws {
        let mapsDir = scenesDir.deletingLastPathComponent().appendingPathComponent("maps")
        let files = try FileManager.default
            .contentsOfDirectory(at: mapsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "threshmp" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!files.isEmpty, "legacy map corpus missing at \(mapsDir.path)")

        var anyBindings = false
        for file in files {
            let envelope = try BindingCodec.decode(try Data(contentsOf: file))
            let name = Comment(rawValue: file.lastPathComponent)
            #expect(envelope.version == BindingCodec.currentVersion, name)
            // Never delete: the raw config survives in `unknown`.
            #expect(envelope.unknown["audioReactiveConfig"] != nil, name)
            for binding in envelope.bindings {
                #expect(binding.lane == .music, name)  // only the music lane
                #expect(binding.signal.rawValue.hasPrefix("audio."), name)
            }
            anyBindings = anyBindings || !envelope.bindings.isEmpty
            let again = try BindingCodec.decode(try BindingCodec.encode(envelope))
            #expect(again == envelope, name)
        }
        #expect(anyBindings, "corpus maps target saturation/iterations/fractalScale — some must map")
    }

    @Test("mandelboxSphereProjection maps to the dedicated DE from formulaParamValues")
    func sphereProjectionDedicatedType() throws {
        for file in try corpusFiles() {
            let raw = try JSONDecoder().decode(
                JSONValue.self, from: Data(contentsOf: file))
            guard case .object(let tree) = raw,
                  case .string("mandelboxSphereProjection")? = tree["fractalType"],
                  case .array(let formula)? = tree["formulaParamValues"], formula.count >= 6
            else { continue }
            func f(_ i: Int) -> Float? {
                if case .number(let n) = formula[i] { return Float(n) }
                return nil
            }
            let name = Comment(rawValue: file.lastPathComponent)
            let envelope = try SceneCodec.decode(try Data(contentsOf: file))
            let key = "mandelboxSphereProjection"
            #expect(envelope.fractalTypeKey == key, name)
            if let minDistance = f(0), let fractalScale = f(3), abs(minDistance) > 1e-9 {
                let scale = try #require(envelope.params["de.\(key).scale"]?.first, name)
                #expect(abs(scale - fractalScale / minDistance) < 1e-5, name)
            }
            if let sphereR = f(2) {
                let minRadius = try #require(envelope.params["de.\(key).minRadius"]?.first, name)
                #expect(abs(minRadius - sphereR) < 1e-5, name)
            }
            #expect(envelope.params["de.\(key).fixedRadius"] == [1], name)
            if let foldLimit = f(1) {
                #expect(envelope.params["de.\(key).foldLimit"]?.first == foldLimit, name)
            }
            if let blend = f(4) {
                #expect(envelope.params["de.\(key).projBlend"]?.first == blend, name)
            }
            if let radius = f(5) {
                #expect(envelope.params["de.\(key).projRadius"]?.first == radius, name)
            }
            return  // one exemplar suffices
        }
        Issue.record("no mandelboxSphereProjection scene in corpus")
    }
}
