// Settings.swift — the Settings tab (ports the legacy Settings ▸ Display /
// Gestures surfaces into the rebuild's structure) and the macOS keyboard
// camera navigation. Everything here is device-local UI state (UserDefaults /
// AppStorage), never scene content.

import SwiftUI
import ThresholdCore
import ThresholdRender

// MARK: - RenderBackendSection (visionOS)

#if os(visionOS)
/// Rendering-backend choice for the Compositor shell (ADR-001 compute phase
/// 2): fragment (foveated, the shipping default) vs the experimental per-view
/// compute march. Config-time: the layer must be built without foveation for
/// compute, so the choice applies the next time the immersive space opens.
public struct RenderBackendSection: View {
    @AppStorage(CompositorSession.renderBackendKey)
    private var backendRaw = CompositorSession.RenderBackend.fragment.rawValue

    public init() {}

    private var backend: SwiftUI.Binding<CompositorSession.RenderBackend> {
        SwiftUI.Binding(
            get: {
                CompositorSession.RenderBackend(rawValue: backendRaw) ?? .fragment
            },
            set: { backendRaw = $0.rawValue })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Rendering", icon: "cpu")
            Picker("Backend", selection: backend) {
                ForEach(CompositorSession.RenderBackend.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.segmented)
            Text("Fragment (foveated) is the shipping choice — compute loses "
                 + "foveated rendering and adds copy passes. Compute exists "
                 + "only for on-device A/B measurement. Applies the next time "
                 + "the immersive space opens.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .moduleCard(.orange)
    }
}
#endif

// MARK: - DisplaySettingsSection

/// Panel text size: an index slider over `DS.textSizeSteps`. The sidebar
/// applies the chosen `DynamicTypeSize` to its content, so text reflows
/// crisply without scaling icons or chrome (the legacy Display behavior).
public struct DisplaySettingsSection: View {
    @AppStorage(DS.textSizeStorageKey)
    private var textSizeIndex = DS.defaultTextSizeIndex

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Display", icon: "textformat.size") {
                Text(DS.textSizeLabel(forIndex: textSizeIndex))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Spacing.sm) {
                RowLabel(icon: "textformat.size", label: "Text Size")
                Slider(
                    value: SwiftUI.Binding(
                        get: { Double(textSizeIndex) },
                        set: { textSizeIndex = Int($0.rounded()) }),
                    in: 0...Double(DS.textSizeSteps.count - 1),
                    step: 1)
            }
        }
        .moduleCard(.gray)
    }
}

// MARK: - InputSettingsSection

/// Gesture feel: orbit/dolly sensitivity and scroll direction, backed by the
/// UserDefaults keys `CameraInteraction` reads per event — no plumbing
/// between this panel and the shells' camera object.
public struct InputSettingsSection: View {
    @AppStorage(CameraTuning.orbitScaleKey) private var orbitScale = 1.0
    @AppStorage(CameraTuning.dollyScaleKey) private var dollyScale = 1.0
    @AppStorage(CameraTuning.invertScrollKey) private var invertScroll = false
    #if os(macOS)
    @AppStorage(KeyboardCameraNav.enabledKey) private var keyboardNav = true
    #endif

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Input", icon: "hand.draw")
            EffectSliderRow(
                icon: "rotate.3d", label: "Orbit Speed",
                value: $orbitScale, in: 0.25...3)
            EffectSliderRow(
                icon: "arrow.up.left.and.arrow.down.right", label: "Zoom Speed",
                value: $dollyScale, in: 0.25...3)
            Toggle("Invert Scroll Zoom", isOn: $invertScroll)
            #if os(macOS)
            Toggle("Keyboard Navigation", isOn: $keyboardNav)
            if keyboardNav {
                Text("Click the view first — ← → orbit · ↑ ↓ pitch · W/S or +/− zoom · ⇧ moves faster · R resets the view")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
        .moduleCard(.green)
    }
}

// MARK: - KeyboardCameraNav (macOS)

#if os(macOS)
import AppKit

/// Keyboard camera control: nudges the camera rig through `CameraInteraction`
/// (gesture-lane writes, same as drag/pinch). Handled by the render view's
/// own `keyDown` — keys reach the camera ONLY while the render view is first
/// responder (the user clicked it). The previous design was an app-wide
/// NSEvent monitor, which stole arrows/W/S/R/+/− from every focused control
/// in every window and read as fields false-triggering on desktop.
@MainActor
public final class KeyboardCameraNav {
    public static let enabledKey = "threshold.input.keyboardNav"

    private weak var surface: RenderSurface?

    public init() {}

    public func install(surface: RenderSurface, camera: CameraInteraction) {
        self.surface = surface
        surface.onKeyDown = { event in
            MainActor.assumeIsolated { Self.handle(event, camera: camera) }
        }
    }

    public func remove() {
        surface?.onKeyDown = nil
        surface = nil
    }

    /// Orbit step per key press (radians, before user tuning); shift ×4.
    static let orbitStep: Float = 0.06
    /// Log-dolly step per key press (negative = in); shift ×4.
    static let dollyStep: Float = 0.12

    /// Returns true when the event was consumed as camera navigation.
    static func handle(_ event: NSEvent, camera: CameraInteraction) -> Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) == nil
            || UserDefaults.standard.bool(forKey: enabledKey) else { return false }
        // Leave command/option chords to menus and the system.
        if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            return false
        }

        let boost: Float = event.modifierFlags.contains(.shift) ? 4 : 1
        switch event.keyCode {
        case 123:  // ←
            camera.nudgeOrbit(yawDelta: -Self.orbitStep * boost, pitchDelta: 0)
        case 124:  // →
            camera.nudgeOrbit(yawDelta: Self.orbitStep * boost, pitchDelta: 0)
        case 126:  // ↑
            camera.nudgeOrbit(yawDelta: 0, pitchDelta: -Self.orbitStep * boost)
        case 125:  // ↓
            camera.nudgeOrbit(yawDelta: 0, pitchDelta: Self.orbitStep * boost)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w", "+", "=":
                camera.nudgeDolly(logStep: -Self.dollyStep * boost)
            case "s", "-":
                camera.nudgeDolly(logStep: Self.dollyStep * boost)
            case "r":
                camera.reset()
            default:
                return false
            }
        }
        return true
    }
}
#endif
