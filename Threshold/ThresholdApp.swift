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
import ImageIO
import os
import SwiftUI
import ThresholdCore
import ThresholdInputs
import ThresholdRender
import ThresholdShaderIR
import ThresholdUI
import UniformTypeIdentifiers

// MARK: - Shared shell pieces (all platforms)

/// Shell diagnostics (`log stream --predicate 'subsystem == "com.pupppower.threshold"'`).
let appLog = Logger(subsystem: "com.pupppower.threshold", category: "shell")

/// Constants shared by the desktop and visionOS composition roots.
enum AppModelShared {
    /// UTTypes the importer accepts, from ThresholdFile's extension list.
    static let openableTypes: [UTType] =
        ThresholdFile.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
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

/// Export wrapper for still-image capture (Export PNG).
struct PNGFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// RGBA8 render result → PNG bytes (ImageIO; same encode as the offscreen
/// CLI's writePNG, minus the file write).
func pngData(from result: RenderResult) -> Data? {
    let bytesPerRow = result.width * 4
    guard let provider = CGDataProvider(data: Data(result.rgba8) as CFData),
          let image = CGImage(
            width: result.width, height: result.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        out, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
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
    /// The on-disk scene library behind the Scenes tab.
    @ObservationIgnored let sceneLibrary = SceneLibrary()
    /// The on-disk clip library behind the Motion ▸ Animate sub-tab.
    @ObservationIgnored let animationLibrary = AnimationLibrary()
    #if os(macOS)
    /// Arrow-key / WASD camera control (Settings ▸ Input toggles it).
    @ObservationIgnored let keyboardNav = KeyboardCameraNav()
    #endif

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
        mirror.setQualityGovernor(.platformDefault)
        #if os(macOS)
        keyboardNav.install(surface: surface, camera: camera)
        #endif
    }

    func stop() {
        #if os(macOS)
        keyboardNav.remove()
        #endif
        audio.stop()
        mirror.stopPolling()
        session.stop()
    }

    /// Whether the mic is feeding the audio.* signals (Motion ▸ Music toggle).
    var audioEnabled = false

    /// Start/stop mic capture only. Routing is user-owned in Motion ▸ Routes —
    /// enabling audio no longer installs demo bindings.
    func setAudioEnabled(_ on: Bool) {
        if on {
            do {
                try audio.start()
                // Align the analyzer's sample clock with the session clock so
                // BindingEngine freshness compares like with like.
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

    /// Bridge a Focus Band edit to BOTH the mic analyzer (which computes it) and
    /// the mirror (the UI's observable copy). App-shell state, not render-session
    /// state (AudioFocusBand.swift).
    func setFocusBand(_ band: AudioFocusBand) {
        audio.setFocusBand(band)
        mirror.setFocusBand(band)
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
    /// the next frame; the deadline is wall-clock (a busy main actor can
    /// stretch individual sleeps well past their nominal 25 ms).
    func captureScene() async -> SceneEnvelope? {
        let slot = SceneCaptureSlot()
        session.commands.publish(.captureScene(into: slot))
        appLog.info("captureScene: published")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if var envelope = slot.take() {
                // Migrated legacy formulas carry no hash — stamp one so the
                // saved file is a fully-formed native document.
                if var embedded = envelope.embeddedDE, embedded.hash.isEmpty {
                    embedded.hash = ExternalDELoader.sourceHash(embedded.source)
                    envelope.embeddedDE = embedded
                }
                // Focus Band is app-shell-owned scene content — the render-side
                // capture doesn't know it. Persist it only when customized so
                // default scenes stay clean.
                if mirror.focusBand != .default { envelope.focusBand = mirror.focusBand }
                appLog.info("captureScene: landed")
                return envelope
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        appLog.error("captureScene: timed out after 4s")
        lastOpenError = "scene capture timed out — is the render loop running?"
        return nil
    }

    /// Capture the live scene and write it into the library under `name`.
    func saveCurrentScene(named name: String) async -> Bool {
        guard let envelope = await captureScene() else { return false }
        guard let url = sceneLibrary.save(envelope, name: name) else {
            appLog.error("library save failed: \(self.sceneLibrary.lastError ?? "?")")
            lastOpenError = sceneLibrary.lastError
            return false
        }
        appLog.info("library save: \(url.lastPathComponent)")
        return true
    }

    /// Render the current frame offscreen at export size → PNG bytes.
    /// The render thread services the capture on its next frame; large
    /// exports legitimately take a few seconds of polling.
    func exportImage(width: Int, height: Int) async -> Data? {
        let slot = ImageCaptureSlot()
        session.commands.publish(.captureImage(width: width, height: height, into: slot))
        appLog.info("exportImage: published \(width)x\(height)")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let result = slot.take() {
                guard let png = pngData(from: result) else {
                    appLog.error("exportImage: PNG encode failed")
                    lastOpenError = "PNG encode failed"
                    return nil
                }
                appLog.info("exportImage: landed (\(png.count) bytes)")
                return png
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        appLog.error("exportImage: timed out after 15s")
        lastOpenError = "image export timed out — is the render loop running?"
        return nil
    }

    private func apply(scene envelope: SceneEnvelope, from filename: String) {
        // Focus Band is app-shell/analyzer state — push it to the mic + UI for
        // BOTH the embedded and non-embedded paths (mirror.applyScene seeds the
        // observable in the non-embedded path, but the analyzer needs it either
        // way and the embedded path skips applyScene).
        setFocusBand(envelope.focusBand ?? .default)
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
                commands.publish(.applyScene(envelope, transition: .default))
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
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: SceneFileDocument?
    @State private var exportingImage = false
    @State private var imageDocument: PNGFileDocument?
    @State private var renderingExport = false

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
                // Presentation modifiers live on DIFFERENT nodes: several
                // stacked on one view is the classic silently-dropped-sheet
                // SwiftUI pitfall. PNG exporter here; scene file dialogs on
                // the sidebar; the error alert on the split container.
                .fileExporter(
                    isPresented: $exportingImage,
                    document: imageDocument,
                    contentType: .png,
                    defaultFilename: "Threshold.png"
                ) { _ in
                    imageDocument = nil
                }

            Divider()

            // The sidebar scrolls itself (tab strip stays fixed on top).
            VStack(spacing: 0) {
                HStack {
                    Button("Open…") { importing = true }
                    Button("Save…") { saveScene() }
                    Button {
                        exportImage()
                    } label: {
                        if renderingExport {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Export PNG")
                        }
                    }
                    .disabled(renderingExport)
                    .help("Render the current view to a PNG at 2× resolution")
                    Spacer()
                    Button {
                        model.camera.reset()
                    } label: {
                        Image(systemName: "camera.metering.center.weighted")
                    }
                    .help("Reset the view to the scene's camera")
                    Toggle(isOn: SwiftUI.Binding(
                        get: { model.audioEnabled },
                        set: { model.setAudioEnabled($0) })) {
                        Image(systemName: model.audioEnabled ? "waveform" : "waveform.slash")
                    }
                    .toggleStyle(.button)
                    .help("Listen to the microphone (route it in Motion ▸ Routes)")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
                ControlSidebar(
                    mirror: model.mirror, layout: model.layout,
                    sceneActions: SceneActions(
                        library: model.sceneLibrary,
                        load: { model.open(url: $0) },
                        saveCurrent: { await model.saveCurrentScene(named: $0) }),
                    animationActions: AnimationActions(
                        library: model.animationLibrary,
                        load: { model.open(url: $0) }),
                    audioActions: AudioActions(
                        isEnabled: { model.audioEnabled },
                        setEnabled: { model.setAudioEnabled($0) },
                        setFocusBand: { model.setFocusBand($0) }),
                    resetView: { model.camera.reset() })
            }
            .frame(width: 340)
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

    /// Export the live view at 2× the drawable, capped to 4K per side
    /// (drawable size is already backing-scale pixels).
    private func exportImage() {
        let drawable = model.surface.layer.drawableSize
        let width = min(max(Int(drawable.width) * 2, 640), 4096)
        let height = min(max(Int(drawable.height) * 2, 640), 4096)
        renderingExport = true
        Task {
            if let data = await model.exportImage(width: width, height: height) {
                imageDocument = PNGFileDocument(data: data)
                exportingImage = true
            }
            renderingExport = false
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
    @ObservationIgnored let sceneLibrary = SceneLibrary()
    @ObservationIgnored let animationLibrary = AnimationLibrary()
    /// Device-local gesture bindings, shared with the sidebar's Gestures tab
    /// and pushed into the HandTracker on edit / fractal change.
    @ObservationIgnored let gestureStore = GestureBindingStore()
    var lastOpenError: String?

    /// Install the current fractal's gesture bindings into the tracker. Called
    /// when the user edits a binding (store.onChange) and when the fractal
    /// changes (VisionMainView observes `mirror.deKey`).
    func refreshGestureBindings() {
        hands.setBindings(gestureStore.resolvedTable(forFractal: mirror.deKey))
    }

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
        // Cross-stack arbiter: while a two-hand world grab owns the motion,
        // the tracker suppresses its pinch-drives so grab and drives can't
        // both move things off one gesture.
        session.onFrame = { [weak session] time in
            hands.update(
                sessionTime: time,
                grabActive: session?.worldGrab.isGrabbing() ?? false)
        }

        self.mirror = ParameterMirror(
            layout: layout, snapshots: session.snapshots, commands: session.commands)
        self.audio = AudioAnalyzer(signals: signals)

        // Push binding edits straight into the render-thread tracker.
        gestureStore.onChange = { [weak self] in self?.refreshGestureBindings() }
    }

    /// Called from the CompositorLayer content closure when the immersive
    /// space opens: spin up the render thread + hand tracking, and arm the
    /// quality governor that drives the compositor's renderQuality lever.
    func attach(_ layerRenderer: LayerRenderer) {
        session.start(layerRenderer)
        hands.start()
        // governorDefault drops the resolution floor to 0.35 when temporal
        // reconstruction is armed (it holds quality there — the point).
        mirror.setQualityGovernor(CompositorSession.governorDefault)
    }

    /// Whether the mic is feeding the audio.* signals (Motion ▸ Music toggle).
    var audioEnabled = false

    /// Start/stop mic capture only; routing is user-owned in Motion ▸ Routes.
    func setAudioEnabled(_ on: Bool) {
        if on {
            do {
                try audio.start()
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

    /// Bridge a Focus Band edit to the mic analyzer + the mirror (app-shell
    /// state, not render-session state — AudioFocusBand.swift).
    func setFocusBand(_ band: AudioFocusBand) {
        audio.setFocusBand(band)
        mirror.setFocusBand(band)
    }

    /// Same open flow as the desktop shell (plan §7.4).
    func open(url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            switch try ThresholdFile.decode(data, filename: url.lastPathComponent) {
            case .scene(let envelope):
                // Focus Band → mic + UI for both the embedded and non-embedded
                // paths (see the desktop shell's apply(scene:)).
                setFocusBand(envelope.focusBand ?? .default)
                // Drop in-flight camera/grab state so the new scene starts from
                // its authored pose, not the previous scene's orbit/grab (the
                // "gesture lane persists after scene load" footgun).
                hands.reset()
                session.worldGrab.reset()
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
                        commands.publish(.applyScene(envelope, transition: .default))
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
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if var envelope = slot.take() {
                if var embedded = envelope.embeddedDE, embedded.hash.isEmpty {
                    embedded.hash = ExternalDELoader.sourceHash(embedded.source)
                    envelope.embeddedDE = embedded
                }
                if mirror.focusBand != .default { envelope.focusBand = mirror.focusBand }
                return envelope
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        lastOpenError = "scene capture needs the immersive space open"
        return nil
    }

    /// Capture the live scene and write it into the library under `name`.
    func saveCurrentScene(named name: String) async -> Bool {
        guard let envelope = await captureScene() else { return false }
        guard sceneLibrary.save(envelope, name: name) != nil else {
            lastOpenError = sceneLibrary.lastError
            return false
        }
        return true
    }
}

// MARK: - Main view (visionOS)

struct VisionMainView: View {
    @Bindable var model: VisionAppModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var immersed = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: SceneFileDocument?

    var body: some View {
        // The sidebar scrolls itself (tab strip stays fixed on top).
        VStack(spacing: 0) {
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
            .task {
                // Headless-capture seam (fps-testing "Path B" autopilot,
                // step 1): open the immersive space on launch so simulator/
                // device profiling runs need no UI interaction. Env-gated,
                // inert otherwise. Retries because a launch-time open can
                // race scene activation (the toggle's onChange reverts
                // `immersed` on failure — that revert is the retry signal).
                guard ProcessInfo.processInfo.environment["THRESHOLD_AUTO_IMMERSIVE"] == "1"
                else { return }
                for attempt in 0..<5 where !immersed {
                    try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 2))
                    if !immersed {
                        ThresholdLog.session.notice(
                            "auto-immersive: opening (attempt \(attempt + 1))")
                        immersed = true
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            HStack {
                Button("Open…") { importing = true }
                Button("Save…") { saveScene() }
                Spacer()
                Toggle(isOn: SwiftUI.Binding(
                    get: { model.audioEnabled },
                    set: { model.setAudioEnabled($0) })) {
                    Image(systemName: model.audioEnabled ? "waveform" : "waveform.slash")
                }
                .toggleStyle(.button)
                .help("Listen to the microphone (route it in Motion ▸ Routes)")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            ControlSidebar(
                mirror: model.mirror, layout: model.layout,
                sceneActions: SceneActions(
                    library: model.sceneLibrary,
                    load: { model.open(url: $0) },
                    saveCurrent: { await model.saveCurrentScene(named: $0) }),
                animationActions: AnimationActions(
                    library: model.animationLibrary,
                    load: { model.open(url: $0) }),
                audioActions: AudioActions(
                    isEnabled: { model.audioEnabled },
                    setEnabled: { model.setAudioEnabled($0) },
                    setFocusBand: { model.setFocusBand($0) }),
                gestureStore: model.gestureStore)
                // Keep the tracker's bindings in sync with the active fractal.
                .onAppear { model.refreshGestureBindings() }
                .onChange(of: model.mirror.deKey) { model.refreshGestureBindings() }
                // Distinct nodes for each presentation modifier (stacking
                // several on one view silently drops some of them).
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
