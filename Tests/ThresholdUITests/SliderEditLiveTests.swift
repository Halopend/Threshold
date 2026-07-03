// SliderEditLiveTests.swift — the slider edit path end-to-end through a
// RUNNING InteractiveSession: ParameterMirror.beginEdit/updateEdit/endEdit
// (exactly what FloatSlotRow's binding calls) must move the resolved value
// the next snapshot reports. This is the "do the sliders actually work"
// capability test.

#if os(macOS)
import Foundation
import QuartzCore
import Testing
import ThresholdCore
import ThresholdShaderIR
import ThresholdRender
@testable import ThresholdUI

@MainActor
@Suite("Slider edits over a live session", .serialized)
struct SliderEditLiveTests {
    /// A live session + a mirror wired to it, the app-shell composition.
    @MainActor
    final class Rig {
        let layout: CatalogLayout
        let session: InteractiveSession
        let mirror: ParameterMirror

        init() throws {
            let catalog = Catalog.withEngineDefaults()
            for descriptor in DERegistry.builtin {
                _ = try descriptor.registerParams(into: catalog)
            }
            layout = catalog.freeze()
            let layer = CAMetalLayer()
            layer.drawableSize = CGSize(width: 96, height: 96)
            InteractiveSession.configure(layer: layer)
            let context = try GPUContext()
            session = InteractiveSession(
                context: context, layout: layout, layer: layer,
                signals: SignalTable(ids: SignalID.standardSession), initialScene: nil)
            mirror = ParameterMirror(
                layout: layout, snapshots: session.snapshots, commands: session.commands)
            session.start()
        }

        deinit { session.stop() }

        /// Poll the snapshot for `slot` to settle near `target`, refreshing the
        /// mirror each tick (the app's 30 Hz poll). Returns the final resolved
        /// value seen.
        func settle(slot: Int, near target: Float, seconds: Double = 4) -> Float {
            let deadline = Date().addingTimeInterval(seconds)
            var last = mirror.displayValue(slot: slot)
            while Date() < deadline {
                mirror.refresh()
                last = session.snapshots.latest?.resolved.values[slot]
                    ?? mirror.displayValue(slot: slot)
                if abs(last - target) < 0.02 { return last }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return last
        }

        /// One full slider interaction: grab, drag to target, release —
        /// exactly the sequence FloatSlotRow issues.
        func dragSlider(slot: Int, to target: Float) {
            mirror.beginEdit(slot: slot)
            mirror.updateEdit(slot: slot, target: target)
            mirror.endEdit(slot: slot)
        }
    }

    @Test func replaceCompositionSliderMovesResolvedValue() throws {
        let rig = try Rig()
        let slot = try #require(rig.layout.slot(for: .engineAOStrength))  // .replace
        _ = rig.settle(slot: slot, near: 0.5)  // default

        rig.dragSlider(slot: slot, to: 1.4)
        let settled = rig.settle(slot: slot, near: 1.4)
        #expect(abs(settled - 1.4) < 0.02,
                "AO Strength slider should drive the resolved value to 1.4, got \(settled)")
    }

    @Test func multiplicativeCompositionSliderMovesResolvedValue() throws {
        let rig = try Rig()
        // DE Iterations is .multiplicative — the riskier inversion path.
        let slot = try #require(rig.layout.slot(for: .engineIterations))
        _ = rig.settle(slot: slot, near: 12)

        rig.dragSlider(slot: slot, to: 40)
        let settled = rig.settle(slot: slot, near: 40, seconds: 4)
        #expect(abs(settled - 40) < 1,
                "DE Iterations slider should drive the resolved value to 40, got \(settled)")
    }

    @Test func deShapeParamSliderMovesResolvedValue() throws {
        // The active DE's own param — the Shape card path. The default DE is
        // Mandelbulb (power, range 2…16). Publish the edit IMMEDIATELY: the
        // offscreen CAMetalDisplayLink throttles to ~1 fps and can stall the
        // render loop within seconds (memory: threshold-build-quirks), so a
        // test must not idle before it publishes the command it wants drained.
        let rig = try Rig()
        let slot = try #require(rig.layout.slot(for: .de("mandelbulb", "power")))
        let target: Float = 5.0

        rig.dragSlider(slot: slot, to: target)
        let settled = rig.settle(slot: slot, near: target)
        #expect(abs(settled - target) < 0.05,
                "Mandelbulb power slider should move the resolved value to \(target), got \(settled)")
    }

    @Test func liveEchoTracksDuringDragBeforeCommit() throws {
        let rig = try Rig()
        let slot = try #require(rig.layout.slot(for: .engineAOStrength))
        _ = rig.settle(slot: slot, near: 0.5)

        // Mid-drag: displayValue must echo the in-flight target immediately
        // (pendingEdits), not wait for the snapshot round-trip.
        rig.mirror.beginEdit(slot: slot)
        rig.mirror.updateEdit(slot: slot, target: 1.1)
        #expect(rig.mirror.displayValue(slot: slot) == 1.1,
                "the thumb must track the drag locally before the render round-trip")
        rig.mirror.endEdit(slot: slot)
    }
}
#endif
