// AudioFocusBandTests.swift — the Focus Band value type + its scene round-trip.
// The band is app-shell/analyzer state, but it persists inside the scene
// envelope (SceneEnvelope.focusBand) so a scene stays a self-contained
// audio-visual preset.

import Foundation
import Testing

@testable import ThresholdCore

@Suite("AudioFocusBand")
struct AudioFocusBandTests {
    @Test("A customized band round-trips through the scene codec")
    func sceneRoundTrip() throws {
        let band = AudioFocusBand(lowHz: 120, highHz: 480, gain: 1.5, enabled: true)
        let envelope = SceneEnvelope(
            version: SceneCodec.currentVersion,
            fractalTypeKey: "mandelbulb",
            focusBand: band)

        let data = try SceneCodec.encode(envelope)
        let decoded = try SceneCodec.decode(data)
        #expect(decoded.focusBand == band)
    }

    @Test("No band → the key is omitted and decodes back to nil")
    func absentByDefault() throws {
        let envelope = SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "mandelbulb")
        let data = try SceneCodec.encode(envelope)
        #expect(!String(decoding: data, as: UTF8.self).contains("focusBand"))
        let decoded = try SceneCodec.decode(data)
        #expect(decoded.focusBand == nil)
    }

    @Test("Forward-compatible decode: missing fields fall back to defaults")
    func partialDecode() throws {
        // A writer that only recorded the low edge — everything else defaults.
        let json = Data(#"{"lowHz": 200}"#.utf8)
        let band = try JSONDecoder().decode(AudioFocusBand.self, from: json)
        #expect(band.lowHz == 200)
        #expect(band.highHz == AudioFocusBand.default.highHz)
        #expect(band.gain == 1)
        #expect(band.enabled)
    }
}
