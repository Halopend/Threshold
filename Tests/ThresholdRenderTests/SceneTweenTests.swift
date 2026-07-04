// SceneTweenTests.swift — the SessionCore half of ADR-005 scene transitions:
// the camera pose and palette tween on the AppClock while the engine eases the
// scene-lane params. Self-contained harness (SessionCoreTests' is file-private).

import Foundation
import Testing
import ThresholdCore
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("Scene transition camera & palette tweens (ADR-005)")
struct SceneTweenTests {
    /// A SessionCore plus its command channel, stepped with synthetic
    /// display-link timestamps (origin 500 s — nothing depends on a zero base).
    private struct Rig {
        let commands = CommandMailbox<SessionCommand>()
        let core: SessionCore
        private(set) var now: Double = 500

        init() {
            let catalog = Catalog.withEngineDefaults()
            for d in DERegistry.builtin { try! d.registerParams(into: catalog) }
            let layout = catalog.freeze()
            core = SessionCore(
                layout: layout, signals: SignalTable(ids: SignalID.standardSession),
                laneMailbox: LaneMailbox(), commands: commands, initialScene: nil)
        }

        @discardableResult
        mutating func step(dt: Double = 1.0 / 60.0) -> SessionFrame {
            now += dt
            return core.step(now: now, width: 32, height: 32)
        }
    }

    private func sceneWithCameraZ(_ z: Float) -> SceneEnvelope {
        SceneEnvelope(
            version: SceneCodec.currentVersion,
            fractalTypeKey: "mandelbox",
            camera: CameraDTO(position: [0, 0, z], orientation: [0, 0, 0, 1],
                              fovYRadians: Float.pi / 3))
    }

    @Test("A transition eases the camera position and lands exactly")
    func cameraEasesAndLands() {
        var r = Rig()
        let startZ = r.step().request.uniforms.camPosFov.z
        #expect(abs(startZ - 3) < 1e-4, "default camera z = 3")

        r.commands.publish(.applyScene(sceneWithCameraZ(10),
                                       transition: SceneTransition(duration: 0.5)))
        let midZ = r.step().request.uniforms.camPosFov.z
        #expect(midZ > 3 && midZ < 10, "camera eases from 3 toward 10, got \(midZ)")

        for _ in 0..<45 { r.step() }  // past 0.5 s (45 frames = 0.75 s)
        #expect(abs(r.step().request.uniforms.camPosFov.z - 10) < 1e-3,
                "camera lands exactly on the authored pose")
    }

    @Test("transition: nil snaps the camera in one frame")
    func cameraSnapsWithoutTransition() {
        var r = Rig()
        r.step()
        r.commands.publish(.applyScene(sceneWithCameraZ(10), transition: nil))
        #expect(abs(r.step().request.uniforms.camPosFov.z - 10) < 1e-4,
                "no transition → the camera jumps immediately")
    }

    @Test("A mid-flight camera transition freezes while paused")
    func cameraTweenFreezesWhilePaused() {
        var r = Rig()
        r.step()
        r.commands.publish(.applyScene(sceneWithCameraZ(10),
                                       transition: SceneTransition(duration: 0.5)))
        r.step()
        r.commands.publish(.setPaused(true))
        let held = r.step().request.uniforms.camPosFov.z
        for _ in 0..<10 {
            #expect(abs(r.step().request.uniforms.camPosFov.z - held) < 1e-5,
                    "the camera tween is content-time, frozen while paused")
        }
    }

    @Test("A transition crossfades the palette and lands on the target stops")
    func paletteCrossfadesAndLands() {
        var r = Rig()
        r.step()

        var scene = sceneWithCameraZ(3)
        let target = Palette(stops: [
            GradientStop(position: 0, rgb: (1, 0, 0)),
            GradientStop(position: 1, rgb: (1, 0, 0)),
        ])
        scene.palette = target
        r.commands.publish(.applyScene(scene, transition: SceneTransition(duration: 0.5)))

        let mid = r.step()
        #expect(mid.request.palette != target.stops,
                "the palette is still crossfading, not yet the target")

        for _ in 0..<45 { r.step() }
        #expect(r.step().request.palette == target.stops,
                "the GPU palette lands on the authored target stops")
    }
}
