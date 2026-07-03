// LiveCaptureTests.swift — captureScene/captureImage through a RUNNING
// InteractiveSession (render thread + CAMetalDisplayLink), the exact path the
// app shells poll. SessionCoreTests cover the core's handling with manual
// step(); these cover the live-loop plumbing the shells depend on.

#if os(macOS)
import Foundation
import QuartzCore
import Testing
import ThresholdCore
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("Live session capture", .serialized)
struct LiveCaptureTests {
    /// Build the app-shell composition (catalog + layer + session), run the
    /// live loop, and hand it to `body`.
    private func withLiveSession(
        _ body: (InteractiveSession) throws -> Void
    ) throws {
        let catalog = Catalog.withEngineDefaults()
        for descriptor in DERegistry.builtin {
            _ = try descriptor.registerParams(into: catalog)
        }
        let layout = catalog.freeze()
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 128, height: 128)
        InteractiveSession.configure(layer: layer)
        let context = try GPUContext()
        let session = InteractiveSession(
            context: context, layout: layout, layer: layer,
            signals: SignalTable(ids: SignalID.standardSession), initialScene: nil)
        session.start()
        defer { session.stop() }
        try body(session)
    }

    /// Poll a take() closure the way the shells do (bounded wall-clock).
    private func poll<T>(seconds: Double, _ take: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = take() { return value }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return take()
    }

    @Test func captureSceneLandsFromTheLiveLoop() throws {
        try withLiveSession { session in
            let slot = SceneCaptureSlot()
            session.commands.publish(.captureScene(into: slot))
            let envelope = poll(seconds: 5) { slot.take() }
            #expect(envelope != nil, "captureScene must land within 5s of live loop")
        }
    }

    @Test func captureImageLandsFromTheLiveLoop() throws {
        try withLiveSession { session in
            let slot = ImageCaptureSlot()
            session.commands.publish(.captureImage(width: 96, height: 64, into: slot))
            let result = poll(seconds: 5) { slot.take() }
            let image = try #require(result, "captureImage must land within 5s of live loop")
            #expect(image.width == 96 && image.height == 64)
            #expect(image.rgba8.count == 96 * 64 * 4)
            // The march produced SOMETHING (not all-zero black).
            #expect(image.rgba8.contains { $0 != 0 })
        }
    }
}
#endif
