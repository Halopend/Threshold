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
        #expect(throws: ThresholdFile.OpenError.unsupportedType("threshmp")) {
            _ = try ThresholdFile.decode(Data(), filename: "map.threshmp")
        }
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

    @Test func legacySceneMigratesThroughTheSamePath() throws {
        // A legacy (version-less, fractalType-keyed) file opens through the
        // same entry point — the migration walk is inside SceneCodec.
        let legacy = Data(#"{"fractalType": "mandelbox", "fractalScale": 2.5}"#.utf8)
        let file = try ThresholdFile.decode(legacy, filename: "old.threshscene")
        guard case .scene(let envelope) = file else {
            Issue.record("expected .scene")
            return
        }
        #expect(envelope.fractalTypeKey == "mandelbox")
        #expect(envelope.params["de.mandelbox.scale"] == [2.5])
    }
}
