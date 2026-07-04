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
    /// Whether the mic is currently feeding the audio.* signals (Music tab
    /// toggle). Routing is independent — see `setAudioEnabled`.
    var audioEnabled = false

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
        var config = QualityGovernorConfig.platformDefault
        if let target = ProcessInfo.processInfo.environment["THRESHOLD_GOVERNOR"]
            .flatMap(Double.init) {
            config.targetMilliseconds = target
        }
        mirror.setQualityGovernor(config)
    }

    func stop() {
        audio.stop()
        mirror.stopPolling()
        session.stop()
    }

    // MARK: Audio input

    /// Start/stop the mic feeding the audio.* signals. This ONLY controls
    /// capture — what the audio features do is decided by the routes the user
    /// builds in Motion ▸ Routes (or the Music tab's quick-adds). Enabling audio
    /// no longer installs demo bindings; routing is fully user-owned.
    func setAudioEnabled(_ on: Bool) {
        if on {
            do {
                try audio.start()
                // Align the analyzer's sample clock with the session clock so
                // freshness checks in the BindingEngine compare like with like.
                if let now = session.snapshots.latest?.time {
                    audio.timebaseOffset = now
                }
                audioEnabled = true
            } catch {
                print("audio start failed: \(error)")
                audioEnabled = false
            }
        } else {
            audio.stop()
            audioEnabled = false
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
            let d = end.diagnostics
            print("SMOKE OK: frames=\(end.frameIndex) fps=\(String(format: "%.1f", fps)) "
                + "gpuMs=\(String(format: "%.2f", end.gpuMilliseconds)) steps=\(end.totalSteps) "
                + "de=\(end.deKey) params=\(end.resolved.values.count) "
                + "pipeline=\(d.pipeline.rawValue)"
                + (d.specializationPending ? " (compiling)" : "")
                + (d.bakedConstants.isEmpty ? "" : " baked[\(d.bakedConstants)]")
                + " renderScale=\(String(format: "%.2f", d.renderScale))")
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

    var body: some View {
        HSplitView {
            RenderSurfaceView(surface: model.surface)
                .frame(minWidth: 480, minHeight: 480)
                .layoutPriority(1)

            // The sidebar scrolls itself (tab strip stays fixed on top). Audio
            // input lives in Motion ▸ Music now (AudioActions), so the shell no
            // longer needs its own toggle.
            ControlSidebar(
                mirror: model.mirror, layout: model.layout,
                audioActions: AudioActions(
                    isEnabled: { model.audioEnabled },
                    setEnabled: { model.setAudioEnabled($0) }))
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
        }
    }
}
