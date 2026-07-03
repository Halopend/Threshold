// ThresholdApp.swift — the multiplatform app shell (Xcode target; plan §11
// phase 7). Wiring only, same rule as the SwiftPM dev shell
// (Sources/threshold-app): every panel is catalog-derived, every value flows
// through the session's mailboxes, the render loop lives on the session's
// dedicated thread. This file should stay boring.
//
// Platform split (ADR-001):
// - macOS + iPadOS: live CAMetalDisplayLink session into a RenderSurface.
// - visionOS: catalog UI only for now — the immersive render path is the
//   Compositor Services compute shell, gated on ADR-001's device spike
//   (rate-map sampling + drawable compute-write validation).

import SwiftUI
import ThresholdCore
import ThresholdInputs
import ThresholdRender
import ThresholdShaderIR
import ThresholdUI

#if os(macOS) || os(iOS)

// MARK: - Composition root (live-render platforms)

@MainActor
final class AppModel {
    let layout: CatalogLayout
    let surface: RenderSurface
    let session: InteractiveSession
    let signals: SignalTable
    let mirror: ParameterMirror
    let audio: AudioAnalyzer

    init() throws {
        // Catalog: engine params + every built-in DE's params — one
        // declaration site shared with the headless harness and dev shell.
        let catalog = Catalog.withEngineDefaults()
        for descriptor in DERegistry.builtin {
            _ = try descriptor.registerParams(into: catalog)
        }
        let layout = catalog.freeze()
        self.layout = layout

        let signals = SignalTable(ids: SignalID.standardSession)
        self.signals = signals

        let surface = RenderSurface()
        self.surface = surface

        let context = try GPUContext()
        let session = InteractiveSession(
            context: context, layout: layout, layer: surface.layer,
            signals: signals, initialScene: nil)
        self.session = session

        self.mirror = ParameterMirror(
            layout: layout, snapshots: session.snapshots, commands: session.commands)

        self.audio = AudioAnalyzer(signals: signals)
    }

    func start() {
        session.start()
        mirror.startPolling()
    }

    func stop() {
        audio.stop()
        mirror.stopPolling()
        session.stop()
    }

    func setAudioReactive(_ on: Bool) {
        if on {
            do {
                try audio.start()
                // Align the analyzer's sample clock with the session clock so
                // BindingEngine freshness compares like with like.
                if let now = session.snapshots.latest?.time {
                    audio.timebaseOffset = now
                }
                mirror.setBindings(Self.defaultAudioBindings)
            } catch {
                print("audio start failed: \(error)")
            }
        } else {
            audio.stop()
            mirror.setBindings([])
        }
    }

    /// Same demo set as the dev shell: bass → bulb power, level → AO.
    static let defaultAudioBindings: [ThresholdCore.Binding] = [
        ThresholdCore.Binding(
            signal: .audioBandLow,
            param: ParamKey.de("mandelbulb", "power"),
            lane: .music,
            mapping: SignalMapping(
                inputLo: 0, inputHi: 1, outputLo: 0, outputHi: 2.5,
                curve: .exponential(k: 1.6), deadzone: 0.02),
            policy: .momentary,
            scale: 1),
        ThresholdCore.Binding(
            signal: .audioRMS,
            param: .engineAOStrength,
            lane: .music,
            mapping: SignalMapping(
                inputLo: 0, inputHi: 0.7, outputLo: 0, outputHi: 0.8,
                curve: .smooth, deadzone: 0.01),
            policy: .momentary,
            scale: 1),
    ]
}

// MARK: - Main view (live-render platforms)

struct MainView: View {
    let model: AppModel
    @State private var audioReactive = false

    var body: some View {
        HStack(spacing: 0) {
            RenderSurfaceView(surface: model.surface)
                .frame(minWidth: 320, minHeight: 320)
                .layoutPriority(1)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("React to Audio (mic)", isOn: $audioReactive)
                        .onChange(of: audioReactive) { _, on in
                            model.setAudioReactive(on)
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    Divider()
                    ControlSidebar(mirror: model.mirror, layout: model.layout)
                }
            }
            .frame(width: 340)
        }
    }
}

#endif  // os(macOS) || os(iOS)

// MARK: - App

@main
struct ThresholdApp: App {
    #if os(macOS) || os(iOS)
    @State private var model: AppModel? = nil
    @State private var initError: String? = nil
    #endif

    var body: some Scene {
        WindowGroup("Threshold") {
            #if os(macOS) || os(iOS)
            Group {
                if let model {
                    MainView(model: model)
                } else if let initError {
                    Text("Threshold failed to start: \(initError)")
                        .padding()
                } else {
                    ProgressView("Starting…")
                        .task {
                            do {
                                let m = try AppModel()
                                m.start()
                                model = m
                            } catch {
                                initError = String(describing: error)
                            }
                        }
                }
            }
            #if os(macOS)
            .frame(minWidth: 960, minHeight: 600)
            #endif
            #else
            // visionOS: the immersive Compositor shell is the next phase
            // (ADR-001 action items). The catalog/persistence stack runs; the
            // march path does not yet.
            VStack(spacing: 12) {
                Text("Threshold")
                    .font(.largeTitle)
                Text("The visionOS immersive render shell (Compositor Services) is pending its on-device spike — see ADR-001.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            #endif
        }
    }
}
