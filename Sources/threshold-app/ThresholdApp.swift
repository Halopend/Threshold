// threshold-app — the interactive Mac dev shell (plan §11 phase 4).
//
// Wiring only: every panel is catalog-derived (ThresholdUI), every value
// flows through the session's mailboxes, and the render loop lives on the
// session's dedicated thread. This file should stay boring.

import SwiftUI
import ThresholdCore
import ThresholdShaderIR
import ThresholdRender
import ThresholdUI
import ThresholdInputs

// MARK: - Composition root

@MainActor
final class AppModel {
    let layout: CatalogLayout
    let surface: RenderSurface
    let session: InteractiveSession
    let signals: SignalTable
    let mirror: ParameterMirror
    let audio: AudioAnalyzer

    init() throws {
        // Catalog: engine params + every built-in DE's params (same wiring as
        // the headless harness — one declaration site, two shells).
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
        InteractiveSession.configure(layer: surface.layer)

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
        // Quality governor ON by default (ADR-003): without it, any scene
        // heavier than the refresh budget misses vsyncs and the app reads as
        // "stuttering" out of the box (docs/perf-notes.md, stutter block).
        // THRESHOLD_GOVERNOR=<targetMs> overrides the target (profiling seam);
        // the sidebar's Auto Quality toggle turns it off.
        let target = ProcessInfo.processInfo.environment["THRESHOLD_GOVERNOR"]
            .flatMap(Double.init)
        mirror.setQualityGovernor(QualityGovernorConfig(
            targetMilliseconds: target ?? QualityGovernorConfig().targetMilliseconds))
    }

    func stop() {
        audio.stop()
        mirror.stopPolling()
        session.stop()
    }

    // MARK: Music reactivity demo set

    /// Default bindings installed by the "React to Audio" toggle: bass drives
    /// the bulb's power, overall level drives AO. Ordinary `Binding` data —
    /// the same mechanism a scene-shipped mapping uses (plan §4.2).
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

    func setAudioReactive(_ on: Bool) {
        if on {
            do {
                try audio.start()
                // Align the analyzer's sample clock with the session clock so
                // freshness checks in the BindingEngine compare like with like.
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
}

// MARK: - App

@main
struct ThresholdApp: App {
    @State private var model: AppModel? = nil
    @State private var initError: String? = nil

    /// THRESHOLD_SMOKE=<seconds>: run the real display-link loop in the real
    /// window for N seconds, print snapshot stats, exit 0 if frames advanced.
    /// CI/agent verification of the live path without screen capture.
    static let smokeSeconds: Double? = ProcessInfo.processInfo
        .environment["THRESHOLD_SMOKE"].flatMap(Double.init)

    static func runSmokeCheck(model: AppModel, seconds: Double) {
        let start = model.session.snapshots.latest
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let end = model.session.snapshots.latest
            let startFrame = start?.frameIndex ?? 0
            // NOTE: CAMetalDisplayLink throttles to ~1fps when the window is
            // off-screen/occluded (the terminal owns the foreground here), so
            // the frame COUNT is not the proof of a live render — non-zero GPU
            // work is. We assert: the loop advanced at all, the GPU actually
            // marched the fractal (steps > 0), and a frame took real GPU time.
            guard let end, end.frameIndex > startFrame else {
                print("SMOKE FAIL: frames did not advance (start \(startFrame), end \(String(describing: end?.frameIndex)))")
                exit(1)
            }
            guard end.totalSteps > 0, end.gpuMilliseconds > 0 else {
                print("SMOKE FAIL: no GPU work (steps=\(end.totalSteps) gpuMs=\(end.gpuMilliseconds)) — kernel did not march")
                exit(1)
            }
            let dt = end.time - (start?.time ?? 0)
            let fps = dt > 0 ? Double(end.frameIndex - startFrame) / dt : 0
            print("SMOKE OK: frames=\(end.frameIndex) fps=\(String(format: "%.1f", fps)) "
                + "gpuMs=\(String(format: "%.2f", end.gpuMilliseconds)) steps=\(end.totalSteps) "
                + "de=\(end.deKey) params=\(end.resolved.values.count)")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Threshold") {
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
                                if let seconds = Self.smokeSeconds {
                                    Self.runSmokeCheck(model: m, seconds: seconds)
                                }
                            } catch {
                                initError = String(describing: error)
                            }
                        }
                }
            }
            .frame(minWidth: 960, minHeight: 600)
        }
    }
}

struct MainView: View {
    let model: AppModel
    @State private var audioReactive = false

    var body: some View {
        HSplitView {
            RenderSurfaceView(surface: model.surface)
                .frame(minWidth: 480, minHeight: 480)
                .layoutPriority(1)

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
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
        }
    }
}
