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
#if os(macOS)
import AppKit
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
    @ObservationIgnored lazy var sceneLoads = SceneLoadCoordinator(mirror: mirror, loader: loader)
    /// The last file-open failure, shown as an alert (compile diagnostics
    /// surface verbatim — plan §7.2 "never trust-and-crash").
    var lastOpenError: String?
    /// Camera gestures → gesture-lane writes (plan §8.3).
    @ObservationIgnored let camera: CameraInteraction
    /// The on-disk scene library behind the Scenes tab.
    @ObservationIgnored let sceneLibrary = SceneLibrary()
    /// The on-disk clip library behind the Motion ▸ Animate sub-tab.
    @ObservationIgnored let animationLibrary = AnimationLibrary()
    /// Reusable warp-stack recipes behind the Warps tab.
    @ObservationIgnored let transformationLibrary = TransformationLibrary()
    #if os(macOS)
    /// Arrow-key / WASD camera control (Settings ▸ Input toggles it).
    @ObservationIgnored let keyboardNav = KeyboardCameraNav()
    /// Opt-in, Debug-only live-path soak task. It drives the same public
    /// camera and quality APIs as the controls, while the real app window and
    /// CAMetalDisplayLink remain active (`THRESHOLD_SOAK_SECONDS=<seconds>`).
    @ObservationIgnored private var soakTask: Task<Void, Never>?
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
        startDebugSoakIfRequested()
        #endif
    }

    func stop() {
        #if os(macOS)
        soakTask?.cancel()
        keyboardNav.remove()
        #endif
        audio.stop()
        mirror.stopPolling()
        session.stop()
    }

    #if DEBUG && os(macOS)
    /// Scripted liveness/stress seam for the actual app shell. Accessibility
    /// automation is often unavailable in CI/agent sessions, so this asks the
    /// app to exercise its own UI-facing command surfaces instead of creating
    /// a parallel renderer test harness.
    private func startDebugSoakIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["THRESHOLD_SOAK_SECONDS"],
              let seconds = Double(raw), seconds > 0
        else { return }

        NSApp.activate(ignoringOtherApps: true)
        mirror.setQualityGovernor(nil)
        let scales: [Float] = [0.20, 0.35, 0.50, 0.75, 1.00, 0.30, 0.90, 0.45]
        let startFrame = session.snapshots.latest?.frameIndex ?? 0
        let deadline = Date().addingTimeInterval(seconds)

        soakTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var phase = 0
            var previousFrame = startFrame
            var consecutiveStaticSamples = 0
            var maximumStaticSamples = 0
            var sawSpatial = false
            var sawNative = false
            var lastSnapshot: RenderSnapshot?

            while Date() < deadline, !Task.isCancelled {
                var tuning = mirror.renderTuning
                tuning.manualRenderScale = scales[phase % scales.count]
                mirror.setRenderTuning(tuning)

                // Deliberately change pose while resolution buckets churn:
                // this is the user interaction pattern that exposed the old
                // temporal-scaler queue wedge.
                let direction: Float = phase.isMultiple(of: 2) ? 1 : -1
                camera.nudgeOrbit(
                    yawDelta: 0.09 * direction,
                    pitchDelta: 0.025 * Float((phase % 3) - 1))
                if phase.isMultiple(of: 3) {
                    camera.nudgeDolly(logStep: 0.025 * direction)
                }

                try? await Task.sleep(for: .milliseconds(250))
                guard let snapshot = session.snapshots.latest else {
                    consecutiveStaticSamples += 1
                    maximumStaticSamples = max(
                        maximumStaticSamples, consecutiveStaticSamples)
                    phase += 1
                    continue
                }
                lastSnapshot = snapshot
                sawSpatial = sawSpatial || snapshot.diagnostics.upscaling
                sawNative = sawNative || !snapshot.diagnostics.upscaling
                if snapshot.frameIndex > previousFrame {
                    consecutiveStaticSamples = 0
                } else {
                    consecutiveStaticSamples += 1
                    maximumStaticSamples = max(
                        maximumStaticSamples, consecutiveStaticSamples)
                }
                previousFrame = snapshot.frameIndex

                if phase.isMultiple(of: 4) {
                    print(String(
                        format: "SOAK tick frame=%llu gpu=%.2fms scale=%.2f spatial=%@ steps=%llu",
                        snapshot.frameIndex,
                        snapshot.gpuMilliseconds,
                        snapshot.diagnostics.renderScale,
                        snapshot.diagnostics.upscaling ? "yes" : "no",
                        snapshot.totalSteps))
                    fflush(stdout)
                }
                phase += 1
            }

            let endFrame = lastSnapshot?.frameIndex ?? startFrame
            let advanced = endFrame > startFrame
            let didGPUWork = (lastSnapshot?.gpuMilliseconds ?? 0) > 0
                && (lastSnapshot?.totalSteps ?? 0) > 0
            let remainedLive = maximumStaticSamples < 8 // <2 seconds at 4 Hz
            let passed = advanced && didGPUWork && remainedLive
                && sawSpatial && sawNative
            print(
                "SOAK \(passed ? "OK" : "FAIL"): frames=\(startFrame)→\(endFrame) "
                + "maxStatic=\(maximumStaticSamples) spatial=\(sawSpatial) "
                + "native=\(sawNative)")
            fflush(stdout)
            exit(passed ? 0 : 1)
        }
    }
    #elseif os(macOS)
    private func startDebugSoakIfRequested() {}
    #endif

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

    /// Open a Threshold scene, clip, binding map, or transformation recipe
    /// from a security-scoped URL.
    /// Decode is synchronous (files are small); an embedded DE compiles on a
    /// background task, and one prepared-scene command publishes after it passes —
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
                mirror.noteStructuralEdit()
                mirror.setAnimationClip(clip)
                mirror.animationTransport(.play)
            case .bindings(let envelope):
                mirror.noteStructuralEdit()
                mirror.setBindings(envelope.bindings)
            case .warpRecipe(let envelope):
                guard mirror.setWarpStack(envelope.warpStack) else {
                    throw SessionSubmissionError.commandMailboxFull
                }
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
        guard session.commands.publish(.captureScene(into: slot)) else {
            appLog.error("captureScene: command mailbox full")
            lastOpenError = SessionSubmissionError.commandMailboxFull.description
            return nil
        }
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

    /// Persist exactly the authored warp stack currently shown by the editor.
    /// No render-thread capture is needed: structural commands echo into the
    /// mirror immediately and snapshots keep it authoritative.
    func saveCurrentTransformation(named name: String) -> Bool {
        let recipe = WarpRecipeEnvelope(name: name, warpStack: mirror.warpStack)
        guard transformationLibrary.save(recipe, name: name) != nil else {
            lastOpenError = transformationLibrary.lastError
            return false
        }
        return true
    }

    /// Render the current frame offscreen at export size → PNG bytes.
    /// The render thread services the capture on its next frame; large
    /// exports legitimately take a few seconds of polling.
    func exportImage(width: Int, height: Int) async -> Data? {
        let slot = ImageCaptureSlot()
        guard session.commands.publish(
            .captureImage(width: width, height: height, into: slot))
        else {
            appLog.error("exportImage: command mailbox full")
            lastOpenError = SessionSubmissionError.commandMailboxFull.description
            return nil
        }
        appLog.info("exportImage: published \(width)x\(height)")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let outcome = slot.take() {
                let result: RenderResult
                switch outcome {
                case .success(let captured):
                    result = captured
                case .failure(let failure):
                    appLog.error("exportImage: \(failure.message, privacy: .public)")
                    lastOpenError = failure.message
                    return nil
                }
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
        sceneLoads.load(envelope, onSubmitted: { [weak self] in
            self?.setFocusBand(envelope.focusBand ?? .default)
        }, onFailure: { [weak self] error in
            self?.lastOpenError = "\(filename): \(error)"
        })
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
                    transformationActions: TransformationActions(
                        library: model.transformationLibrary,
                        load: { model.open(url: $0) },
                        saveCurrent: { model.saveCurrentTransformation(named: $0) }),
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
    @ObservationIgnored lazy var sceneLoads = SceneLoadCoordinator(mirror: mirror, loader: loader)
    @ObservationIgnored let audio: AudioAnalyzer
    @ObservationIgnored let hands: HandTracker
    @ObservationIgnored let sceneLibrary = SceneLibrary()
    @ObservationIgnored let animationLibrary = AnimationLibrary()
    @ObservationIgnored let transformationLibrary = TransformationLibrary()
    /// Device-local gesture bindings, shared with the sidebar's Gestures tab
    /// and pushed into the HandTracker on edit / fractal change.
    @ObservationIgnored let gestureStore = GestureBindingStore()
    var handControlsPaused = false

    func setHandControlsPaused(_ paused: Bool) {
        handControlsPaused = paused
        hands.setUISuppressed(paused)
        session.worldGrab.setSuppressed(paused)
    }

    func resetHandControls() {
        hands.reset()
        session.worldGrab.reset()
    }

    var lastOpenError: String?
    enum ImmersionState { case closed, opening, open, closing }
    var immersionState: ImmersionState = .closed
    var immersionError: String?

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

        session.onRenderLoopEnded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hands.stop()
                self.hands.reset()
                self.session.worldGrab.reset()
                self.immersionState = .closed
            }
        }

        // Push binding edits straight into the render-thread tracker.
        gestureStore.onChange = { [weak self] in self?.refreshGestureBindings() }
    }

    /// Called from the CompositorLayer content closure when the immersive
    /// space opens: spin up the render thread + hand tracking, and arm the
    /// quality governor that drives the compositor's renderQuality lever.
    func attach(_ layerRenderer: LayerRenderer) {
        hands.reset()
        session.worldGrab.reset()
        refreshGestureBindings()
        session.start(layerRenderer)
        hands.start()
        immersionState = .open
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
                sceneLoads.load(envelope, onSubmitted: { [weak self] in
                    guard let self else { return }
                    self.setFocusBand(envelope.focusBand ?? .default)
                    self.hands.reset()
                    self.session.worldGrab.reset()
                }, onFailure: { [weak self] error in
                    self?.lastOpenError = "\(url.lastPathComponent): \(error)"
                })
            case .animation(let envelope):
                var clip = envelope.clip
                if clip.name == nil {
                    clip.name = url.deletingPathExtension().lastPathComponent
                }
                mirror.noteStructuralEdit()
                mirror.setAnimationClip(clip)
                mirror.animationTransport(.play)
            case .bindings(let envelope):
                mirror.noteStructuralEdit()
                mirror.setBindings(envelope.bindings)
            case .warpRecipe(let envelope):
                guard mirror.setWarpStack(envelope.warpStack) else {
                    throw SessionSubmissionError.commandMailboxFull
                }
            }
        } catch {
            lastOpenError = "\(url.lastPathComponent): \(error)"
        }
    }

    func captureScene() async -> SceneEnvelope? {
        let slot = SceneCaptureSlot()
        guard session.commands.publish(.captureScene(into: slot)) else {
            lastOpenError = SessionSubmissionError.commandMailboxFull.description
            return nil
        }
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

    func saveCurrentTransformation(named name: String) -> Bool {
        let recipe = WarpRecipeEnvelope(name: name, warpStack: mirror.warpStack)
        guard transformationLibrary.save(recipe, name: name) != nil else {
            lastOpenError = transformationLibrary.lastError
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
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: SceneFileDocument?

    var body: some View {
        // The sidebar scrolls itself (tab strip stays fixed on top).
        VStack(spacing: 0) {
            Button {
                Task { await toggleImmersion() }
            } label: {
                Label(
                    model.immersionState == .open ? "Leave the Fractal" : "Enter the Fractal",
                    systemImage: "visionpro")
            }
            .disabled(model.immersionState == .opening || model.immersionState == .closing)
            .task {
                guard ProcessInfo.processInfo.environment["THRESHOLD_AUTO_IMMERSIVE"] == "1"
                else { return }
                for attempt in 0..<5 {
                    guard model.immersionState == .closed else { return }
                    do {
                        try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 2))
                    } catch { return }
                    guard model.immersionState == .closed else { return }
                    await toggleImmersion()
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .alert("Could not open immersive space", isPresented: SwiftUI.Binding(
                get: { model.immersionError != nil },
                set: { if !$0 { model.immersionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.immersionError ?? "")
            }

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
            HStack {
                Toggle("Pause Gestures", isOn: SwiftUI.Binding(
                    get: { model.handControlsPaused },
                    set: { model.setHandControlsPaused($0) }))
                Button("Reset Hand Adjustments") { model.resetHandControls() }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
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
                transformationActions: TransformationActions(
                    library: model.transformationLibrary,
                    load: { model.open(url: $0) },
                    saveCurrent: { model.saveCurrentTransformation(named: $0) }),
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

    @MainActor
    private func toggleImmersion() async {
        switch model.immersionState {
        case .closed:
            model.immersionError = nil
            model.immersionState = .opening
            switch await openImmersiveSpace(id: ThresholdApp.immersiveSpaceID) {
            case .opened:
                break // attach(_:) confirms the live renderer.
            case .userCancelled:
                model.immersionState = .closed
            case .error:
                model.immersionState = .closed
                model.immersionError = "Vision Pro could not open the immersive space. Please try again."
            @unknown default:
                model.immersionState = .closed
                model.immersionError = "The immersive space is unavailable."
            }
        case .open:
            model.immersionState = .closing
            await dismissImmersiveSpace()
            // Render-loop completion closes the state after teardown, so a
            // second tap cannot attach a layer while the old loop is alive.
        case .opening, .closing:
            break
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
