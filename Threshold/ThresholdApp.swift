// ThresholdApp.swift — the multiplatform app shell (Xcode target; plan §11
// phase 7). Wiring only, same rule as the SwiftPM dev shell
// (Sources/threshold-app): every panel is catalog-derived, every value flows
// through the session's mailboxes, the render loop lives on the session's
// dedicated thread. This file should stay boring.
//
// Platform split (ADR-001):
// - macOS + iPadOS: live CAMetalDisplayLink session into a RenderSurface.
// - visionOS: Compositor Services raster shell (CompositorSession) — a
//   control window plus an ImmersiveSpace whose CompositorLayer drives the
//   session render thread; hands publish signals + gesture-lane camera
//   control (HandTracker).

#if os(visionOS)
import CompositorServices
#endif
import SwiftUI
import ThresholdCore
import ThresholdInputs
import ThresholdRender
import ThresholdShaderIR
import ThresholdUI
import UniformTypeIdentifiers

// MARK: - Shared shell pieces (all platforms)

/// Constants shared by the desktop and visionOS composition roots.
enum AppModelShared {
    /// UTTypes the importer accepts, from ThresholdFile's extension list.
    static let openableTypes: [UTType] =
        ThresholdFile.supportedExtensions.compactMap { UTType(filenameExtension: $0) }

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

/// Export wrapper for the save flow — just bytes with a scene extension.
struct SceneFileDocument: FileDocument {
    static let sceneType = UTType(filenameExtension: "threshscene") ?? .json
    static var readableContentTypes: [UTType] { [sceneType] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

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
    /// Camera gestures → gesture-lane writes (plan §8.3).
    @ObservationIgnored let camera: CameraInteraction

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
        self.camera = CameraInteraction(layout: layout, mailbox: session.laneMailbox)
        #if os(macOS)
        surface.onScroll = { [camera] deltaY in camera.scroll(deltaY: deltaY) }
        #endif

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
                mirror.setBindings(AppModelShared.defaultAudioBindings)
            } catch {
                print("audio start failed: \(error)")
            }
        } else {
            audio.stop()
            mirror.setBindings([])
        }
    }

    // MARK: File open (plan §7.4)

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

    /// Capture the authored scene from the render thread (plan §7.1: save is
    /// a catalog walk — nothing hand-written to forget). The command lands on
    /// the next frame; polling covers a paused-but-stepping loop.
    func captureScene() async -> SceneEnvelope? {
        let slot = SceneCaptureSlot()
        session.commands.publish(.captureScene(into: slot))
        for _ in 0..<40 {
            if var envelope = slot.take() {
                // Migrated legacy formulas carry no hash — stamp one so the
                // saved file is a fully-formed native document.
                if var embedded = envelope.embeddedDE, embedded.hash.isEmpty {
                    embedded.hash = ExternalDELoader.sourceHash(embedded.source)
                    envelope.embeddedDE = embedded
                }
                return envelope
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        lastOpenError = "scene capture timed out — is the render loop running?"
        return nil
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

}

// MARK: - Main view (live-render platforms)

struct MainView: View {
    @Bindable var model: AppModel
    @State private var audioReactive = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: SceneFileDocument?

    var body: some View {
        HStack(spacing: 0) {
            RenderSurfaceView(surface: model.surface)
                .frame(minWidth: 320, minHeight: 320)
                .layoutPriority(1)
                // Orbit (drag) + dolly (pinch) → gesture lane (plan §8.3).
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { model.camera.dragChanged(translation: $0.translation) }
                        .onEnded { model.camera.dragEnded(translation: $0.translation) }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { model.camera.magnifyChanged($0.magnification) }
                        .onEnded { model.camera.magnifyEnded($0.magnification) }
                )
                // Drag a .threshscene/.threshanim/.threshmp onto the view.
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
                        Button("Save…") { saveScene() }
                        Button("Reset View") { model.camera.reset() }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    Toggle("React to Audio (mic)", isOn: $audioReactive)
                        .onChange(of: audioReactive) { _, on in
                            model.setAudioReactive(on)
                        }
                        .padding(.horizontal)
                    Divider()
                    ControlSidebar(mirror: model.mirror, layout: model.layout)
                }
            }
            .frame(width: 340)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: AppModelShared.openableTypes
        ) { result in
            if case .success(let url) = result {
                model.open(url: url)
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: SceneFileDocument.sceneType,
            defaultFilename: "Scene.threshscene"
        ) { _ in
            exportDocument = nil
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

    private func saveScene() {
        Task {
            guard let envelope = await model.captureScene() else { return }
            do {
                exportDocument = SceneFileDocument(data: try SceneCodec.encode(envelope))
                exporting = true
            } catch {
                model.lastOpenError = "save failed: \(error)"
            }
        }
    }
}

#endif  // os(macOS) || os(iOS)

#if os(visionOS)

// MARK: - Composition root (visionOS)

/// The Compositor-shell counterpart of AppModel: same catalog, mailboxes, and
/// mirror; the render loop lives in CompositorSession and comes to life when
/// the immersive space opens (the CompositorLayer hands us its LayerRenderer).
@MainActor
@Observable
final class VisionAppModel {
    @ObservationIgnored let layout: CatalogLayout
    @ObservationIgnored let signals: SignalTable
    @ObservationIgnored let session: CompositorSession
    @ObservationIgnored let mirror: ParameterMirror
    @ObservationIgnored let loader: ExternalDELoader
    @ObservationIgnored let audio: AudioAnalyzer
    @ObservationIgnored let hands: HandTracker
    var lastOpenError: String?

    init() throws {
        let catalog = Catalog.withEngineDefaults()
        for descriptor in DERegistry.builtin {
            _ = try descriptor.registerParams(into: catalog)
        }
        let layout = catalog.freeze()
        self.layout = layout

        let signals = SignalTable(ids: SignalID.standardSession)
        self.signals = signals

        let context = try GPUContext()
        let session = CompositorSession(
            context: context, layout: layout, signals: signals, initialScene: nil)
        self.session = session
        self.loader = try ExternalDELoader(context: context)

        let hands = HandTracker(
            layout: layout, mailbox: session.laneMailbox, signals: signals)
        self.hands = hands
        // Hands poll on the render loop's cadence, stamped with session time
        // (CompositorSession.onFrame contract) — set BEFORE the layer attaches.
        session.onFrame = { time in hands.update(sessionTime: time) }

        self.mirror = ParameterMirror(
            layout: layout, snapshots: session.snapshots, commands: session.commands)
        self.audio = AudioAnalyzer(signals: signals)
    }

    /// Called from the CompositorLayer content closure when the immersive
    /// space opens: spin up the render thread + hand tracking.
    func attach(_ layerRenderer: LayerRenderer) {
        session.start(layerRenderer)
        hands.start()
    }

    func setAudioReactive(_ on: Bool) {
        if on {
            do {
                try audio.start()
                if let now = session.snapshots.latest?.time {
                    audio.timebaseOffset = now
                }
                mirror.setBindings(AppModelShared.defaultAudioBindings)
            } catch {
                print("audio start failed: \(error)")
            }
        } else {
            audio.stop()
            mirror.setBindings([])
        }
    }

    /// Same open flow as the desktop shell (plan §7.4).
    func open(url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            switch try ThresholdFile.decode(data, filename: url.lastPathComponent) {
            case .scene(let envelope):
                guard envelope.embeddedDE != nil else {
                    mirror.applyScene(envelope)
                    return
                }
                let commands = session.commands
                let loader = loader
                let filename = url.lastPathComponent
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
            case .animation(let envelope):
                var clip = envelope.clip
                if clip.name == nil {
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

    func captureScene() async -> SceneEnvelope? {
        let slot = SceneCaptureSlot()
        session.commands.publish(.captureScene(into: slot))
        for _ in 0..<40 {
            if var envelope = slot.take() {
                if var embedded = envelope.embeddedDE, embedded.hash.isEmpty {
                    embedded.hash = ExternalDELoader.sourceHash(embedded.source)
                    envelope.embeddedDE = embedded
                }
                return envelope
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        lastOpenError = "scene capture needs the immersive space open"
        return nil
    }
}

// MARK: - Main view (visionOS)

struct VisionMainView: View {
    @Bindable var model: VisionAppModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var immersed = false
    @State private var audioReactive = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: SceneFileDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $immersed) {
                    Label(
                        immersed ? "Leave the Fractal" : "Enter the Fractal",
                        systemImage: "visionpro")
                }
                .toggleStyle(.button)
                .onChange(of: immersed) { _, on in
                    Task {
                        if on {
                            switch await openImmersiveSpace(id: ThresholdApp.immersiveSpaceID) {
                            case .opened: break
                            default: immersed = false
                            }
                        } else {
                            await dismissImmersiveSpace()
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                HStack {
                    Button("Open…") { importing = true }
                    Button("Save…") { saveScene() }
                }
                .padding(.horizontal)
                Toggle("React to Audio (mic)", isOn: $audioReactive)
                    .onChange(of: audioReactive) { _, on in
                        model.setAudioReactive(on)
                    }
                    .padding(.horizontal)
                Divider()
                ControlSidebar(mirror: model.mirror, layout: model.layout)
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: AppModelShared.openableTypes
        ) { result in
            if case .success(let url) = result {
                model.open(url: url)
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: SceneFileDocument.sceneType,
            defaultFilename: "Scene.threshscene"
        ) { _ in
            exportDocument = nil
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

    private func saveScene() {
        Task {
            guard let envelope = await model.captureScene() else { return }
            do {
                exportDocument = SceneFileDocument(data: try SceneCodec.encode(envelope))
                exporting = true
            } catch {
                model.lastOpenError = "save failed: \(error)"
            }
        }
    }
}

/// Layer configuration → CompositorSession's documented render contract.
struct ThresholdLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(
        capabilities: LayerRenderer.Capabilities,
        configuration: inout LayerRenderer.Configuration
    ) {
        CompositorSession.configure(
            capabilities: capabilities, configuration: &configuration)
    }
}

#endif  // os(visionOS)

// MARK: - App

@main
struct ThresholdApp: App {
    #if os(macOS) || os(iOS)
    @State private var model: AppModel? = nil
    #else
    static let immersiveSpaceID = "threshold.immersive"
    @State private var model: VisionAppModel? = nil
    #endif
    @State private var initError: String? = nil

    var body: some Scene {
        #if os(macOS) || os(iOS)
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
                            } catch {
                                initError = String(describing: error)
                            }
                        }
                }
            }
            #if os(macOS)
            .frame(minWidth: 960, minHeight: 600)
            #endif
        }
        #else
        WindowGroup("Threshold") {
            Group {
                if let model {
                    VisionMainView(model: model)
                } else if let initError {
                    Text("Threshold failed to start: \(initError)")
                        .padding()
                } else {
                    ProgressView("Starting…")
                        .task {
                            do {
                                let m = try VisionAppModel()
                                m.mirror.startPolling()
                                model = m
                            } catch {
                                initError = String(describing: error)
                            }
                        }
                }
            }
        }

        // The immersive render shell: the CompositorLayer closure hands the
        // live LayerRenderer to the session, which spawns its render thread
        // (CompositorSession). MIXED immersion: miss pixels are transparent
        // (the march composites over passthrough), and — critically — the
        // control window stays visible and reachable while immersed. The
        // progressive portal style is a follow-up pass slot (plan §6.4).
        ImmersiveSpace(id: Self.immersiveSpaceID) {
            CompositorLayer(configuration: ThresholdLayerConfiguration()) { layerRenderer in
                model?.attach(layerRenderer)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        #endif
    }
}
