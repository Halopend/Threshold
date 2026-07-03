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

    @Test("mandelboxSphereProjection maps to mandelbox + sphereProject op")
    func sphereProjectionUnification() throws {
        for file in try corpusFiles() {
            let raw = try JSONDecoder().decode(
                JSONValue.self, from: Data(contentsOf: file))
            guard case .object(let tree) = raw,
                  case .string("mandelboxSphereProjection")? = tree["fractalType"]
            else { continue }
            let envelope = try SceneCodec.decode(try Data(contentsOf: file))
            #expect(envelope.fractalTypeKey == "mandelbox", Comment(rawValue: file.lastPathComponent))
            if case .bool(true)? = tree["sphereProjectionEnabled"] {
                #expect(
                    envelope.warpStack.contains { $0.kind == 18 },
                    "\(file.lastPathComponent): sphereProject op missing")
            }
            return  // one exemplar suffices
        }
        Issue.record("no mandelboxSphereProjection scene in corpus")
    }
}
