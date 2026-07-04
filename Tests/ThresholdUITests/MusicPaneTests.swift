// MusicPaneTests.swift — the Motion ▸ Music surface: preset recipes resolve to
// valid music-lane bindings, the mirror surfaces live audio levels, seeds the
// Focus Band from a scene, and the route-replace helper is idempotent.

import Testing
@testable import ThresholdCore
import ThresholdRender
@testable import ThresholdUI

private func engineLayout() -> CatalogLayout {
    Catalog.withEngineDefaults().freeze()
}

@Suite("MusicPreset recipes")
struct MusicPresetTests {
    @Test("Every shipped preset resolves to non-empty, well-formed music routes")
    func presetsResolve() {
        let layout = engineLayout()
        let audioIDs = Set(ModulationSource.audio.map(\.id))
        #expect(!MusicPreset.builtIn.isEmpty)

        for preset in MusicPreset.builtIn {
            let bindings = preset.bindings(layout: layout)
            #expect(!bindings.isEmpty, "\(preset.id) resolved to nothing")
            for b in bindings {
                #expect(b.lane == .music)
                #expect(audioIDs.contains(b.signal))
                // Outputs are clamped into the target param's declared range.
                let entry = layout.entry(for: b.param)
                #expect(entry != nil)
                if let range = entry?.spec.range {
                    #expect(range.contains(b.mapping.outputLo))
                    #expect(range.contains(b.mapping.outputHi))
                }
            }
        }
    }

    @Test("A target the catalog lacks is skipped, not crashed")
    func missingTargetSkipped() {
        // makeTestLayout has none of the color/camera targets.
        let bindings = MusicPreset.builtIn
            .flatMap { $0.bindings(layout: makeTestLayout()) }
        #expect(bindings.isEmpty)
    }
}

@MainActor
@Suite("Music-pane mirror state")
struct MusicPaneMirrorTests {
    @Test("audioLevels ride the snapshot and diff like other readback")
    func audioLevelsMirrored() {
        let (mirror, snapshots, _) = makeMirror()
        #expect(mirror.audioLevels == .zero)

        let values = [Float](repeating: 0, count: mirror.layout.slotCount)
        let levels = AudioLevels(rms: 0.4, bandLow: 0.6, bandUser: 0.3)
        snapshots.publish(makeSnapshot(values: values, frameIndex: 1, time: 0.016, audioLevels: levels))
        mirror.refresh()
        #expect(mirror.audioLevels == levels)
        let gen = mirror.refreshGeneration

        // Same snapshot again → no new observable event.
        mirror.refresh()
        #expect(mirror.refreshGeneration == gen)
    }

    @Test("applyScene seeds the Focus Band (and defaults when absent)")
    func focusBandSeeded() {
        let (mirror, _, _) = makeMirror()
        #expect(mirror.focusBand == .default)

        let band = AudioFocusBand(lowHz: 300, highHz: 900, gain: 2, enabled: true)
        mirror.applyScene(SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "mandelbulb",
            focusBand: band), transition: nil)
        #expect(mirror.focusBand == band)

        // A scene without a band resets to the default.
        mirror.applyScene(SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: "mandelbulb"),
            transition: nil)
        #expect(mirror.focusBand == .default)
    }

    @Test("setBindings(replacing:) dedupes by target, not by identity")
    func replaceDedup() {
        let (mirror, _, _) = makeMirror()
        let first = ThresholdCore.Binding(
            signal: .audioRMS, param: .colorSaturation, lane: .music,
            mapping: SignalMapping(outputLo: 0, outputHi: 1))
        mirror.setBindings([first])

        // Same (signal, param, component) → replaces, count stays 1.
        let replacement = ThresholdCore.Binding(
            signal: .audioRMS, param: .colorSaturation, lane: .music,
            mapping: SignalMapping(outputLo: 0.2, outputHi: 0.8))
        mirror.setBindings(replacing: [replacement], in: mirror.bindings)
        #expect(mirror.bindings.count == 1)
        #expect(mirror.bindings.first?.id == replacement.id)

        // Different target → appends.
        let other = ThresholdCore.Binding(
            signal: .audioBandLow, param: .cameraDolly, lane: .music,
            mapping: SignalMapping(outputLo: 1, outputHi: 1.5))
        mirror.setBindings(replacing: [other], in: mirror.bindings)
        #expect(mirror.bindings.count == 2)
    }
}
