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
import UniformTypeIdentifiers

#if os(macOS) || os(iOS)

// MARK: - Composition root (live-render platforms)

@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let layout: CatalogLayout
    @ObservationIgnored let surface: RenderSurface
    @ObservationIgnored let session: InteractiveSession
    @ObservationIgnored let signals: SignalTable
    @ObservationIgnored let mirror: ParameterMirror
    @ObservationIgnored let audio: AudioAnalyzer
    /// Compiles + probes embedded DEs OFF the render thread (plan §7.2);
    /// programs land via the setExternalDE command.
    @ObservationIgnored let loader: ExternalDELoader
    /// The last file-open failure, shown as an alert (compile diagnostics
    /// surface verbatim — plan §7.2 "never trust-and-crash").
    var lastOpenError: String?

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
        self.loader = try ExternalDELoader(context: context)

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

    // MARK: File open (plan §7.4)

    /// UTTypes the importer accepts, from ThresholdFile's extension list.
    static let openableTypes: [UTType] =
        ThresholdFile.supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    /// Open a .threshscene / .threshanim from a security-scoped URL.
    /// Decode is synchronous (files are small); an embedded DE compiles on a
    /// background task, and BOTH commands publish together after it passes —
    /// a rejected DE means the scene does not half-apply (ExternalDE.swift).
    func open(url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            switch try ThresholdFile.decode(data, filename: url.lastPathComponent) {
            case .scene(let envelope):
                apply(scene: envelope, from: url.lastPathComponent)
            case .animation(let envelope):
                var clip = envelope.clip
                if clip.name == nil {
                    // Legacy files carry no display name — the filename is it.
                    clip.name = url.deletingPathExtension().lastPathComponent
                }
                mirror.setAnimationClip(clip)
                mirror.animationTransport(.play)
            case .bindings(let envelope):
                mirror.setBindings(envelope.bindings)
            }
        } catch {
            lastOpenError = "\(url.lastPathComponent): \(error)"
        }
    }

    private func apply(scene envelope: SceneEnvelope, from filename: String) {
        guard envelope.embeddedDE != nil else {
            mirror.applyScene(envelope)
            return
        }
        // Compile off the main actor; loader + mailbox are Sendable. The
        // cache makes reopening the same DE instant.
        let commands = session.commands
        let loader = loader
        Task.detached(priority: .userInitiated) {
            do {
                let program = try envelope.embeddedDE.map { try loader.load($0) }
                commands.publish(.applyScene(envelope))
                commands.publish(.setExternalDE(program))
            } catch {
                let message = "\(filename): \(error)"
                await MainActor.run { self.lastOpenError = message }
            }
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
    @Bindable var model: AppModel
    @State private var audioReactive = false
    @State private var importing = false

    var body: some View {
        HStack(spacing: 0) {
            RenderSurfaceView(surface: model.surface)
                .frame(minWidth: 320, minHeight: 320)
                .layoutPriority(1)
                // Drag a .threshscene/.threshanim onto the render view.
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    model.open(url: url)
                    return true
                }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Open…") { importing = true }
                        Toggle("React to Audio (mic)", isOn: $audioReactive)
                            .onChange(of: audioReactive) { _, on in
                                model.setAudioReactive(on)
                            }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    Divider()
                    ControlSidebar(mirror: model.mirror, layout: model.layout)
                }
            }
            .frame(width: 340)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: AppModel.openableTypes
        ) { result in
            if case .success(let url) = result {
                model.open(url: url)
            }
        }
        .alert(
            "Could not open file",
            isPresented: SwiftUI.Binding(
                get: { model.lastOpenError != nil },
                set: { if !$0 { model.lastOpenError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastOpenError ?? "")
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
