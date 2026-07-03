// Panels.swift — catalog-derived sections and the control sidebar
// (plan §2.2, phase 4). Every parameter row here comes from walking
// CatalogLayout; the only hand-built sections are the structural ones the
// catalog cannot describe (DE choice, warp stack, render stats).

import SwiftUI
import ThresholdCore
import ThresholdRender
import ThresholdShaderABI
import ThresholdShaderIR

// MARK: - CatalogSectionView

/// All rows of one UI group: `layout.entries` filtered by `spec.group`,
/// rendered by the generic `ParameterRow`. Zero per-param code.
public struct CatalogSectionView: View {
    let group: GroupID
    let layout: CatalogLayout
    let mirror: ParameterMirror
    /// Base slots rendered by a dedicated section elsewhere (e.g. the color
    /// mapping picker lives in PaletteSection) — skip them here to avoid
    /// duplicate controls.
    let excludedSlots: Set<Int>

    public init(
        group: GroupID, layout: CatalogLayout, mirror: ParameterMirror,
        excludedSlots: Set<Int> = []
    ) {
        self.group = group
        self.layout = layout
        self.mirror = mirror
        self.excludedSlots = excludedSlots
    }

    public var body: some View {
        Section(group.rawValue.capitalized) {
            ForEach(
                layout.entries.filter { $0.spec.group == group && !excludedSlots.contains($0.slot) },
                id: \.slot
            ) { entry in
                ParameterRow(entry: entry, mirror: mirror)
            }
        }
    }
}

// MARK: - ControlSidebar

/// The whole control surface: structural sections + one CatalogSectionView
/// per group present in the layout, in first-registration order.
public struct ControlSidebar: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout

    public init(mirror: ParameterMirror, layout: CatalogLayout) {
        self.mirror = mirror
        self.layout = layout
    }

    /// Groups present in the layout, ordered by first appearance
    /// (registration order is the stable, author-controlled order).
    nonisolated static func groupsInOrder(_ layout: CatalogLayout) -> [GroupID] {
        var seen = Set<GroupID>()
        var ordered: [GroupID] = []
        for entry in layout.entries where seen.insert(entry.spec.group).inserted {
            ordered.append(entry.spec.group)
        }
        return ordered
    }

    public var body: some View {
        Form {
            StatsSection(mirror: mirror)
            PipelineSection(mirror: mirror)
            DEPickerSection(mirror: mirror)
            CustomDESection(mirror: mirror)
            AnimationSection(mirror: mirror)
            #if os(visionOS)
            HandsSection(mirror: mirror)
            #endif
            WarpStackSection(mirror: mirror)
            PaletteSection(mirror: mirror, layout: layout)
            ForEach(Self.groupsInOrder(layout), id: \.self) { group in
                // The color mapping picker is rendered by PaletteSection, so
                // exclude its slot from the generic color group.
                CatalogSectionView(
                    group: group, layout: layout, mirror: mirror,
                    excludedSlots: group == .color ? Self.colorMappingSlots(layout) : [])
            }
        }
        .formStyle(.grouped)
    }

    /// The colorMapMode slot (if registered) — owned by PaletteSection.
    nonisolated static func colorMappingSlots(_ layout: CatalogLayout) -> Set<Int> {
        layout.slot(for: .colorMapMode).map { [$0] } ?? []
    }
}

// MARK: - DEPickerSection

/// Distance-estimator picker over `DERegistry.builtin` → `mirror.setDE`.
public struct DEPickerSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        Section("Distance Estimator") {
            Picker("Fractal", selection: SwiftUI.Binding(
                get: { mirror.deKey },
                set: { mirror.setDE(key: $0) }
            )) {
                // Before the first snapshot the mirror's deKey may not match
                // any registered DE; give it a placeholder tag so the Picker
                // stays consistent instead of logging selection warnings.
                if !DERegistry.builtin.contains(where: { $0.key == mirror.deKey }) {
                    Text("—").tag(mirror.deKey)
                }
                ForEach(DERegistry.builtin, id: \.key) { descriptor in
                    Text(descriptor.displayName).tag(descriptor.key)
                }
            }
        }
    }
}

// MARK: - AnimationSection

/// Transport for the loaded animation clip (play/pause/stop + scrub).
/// Renders nothing until a clip is loaded (the .threshanim open flow or a
/// scene-shipped clip). All state is snapshot readback; verbs go through the
/// command mailbox — the mirror computes no transport logic.
public struct AnimationSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        if mirror.animation.hasClip {
            Section("Animation") {
                LabeledContent("Clip", value: mirror.animation.clipName ?? "Untitled")
                HStack(spacing: 12) {
                    Button {
                        mirror.animationTransport(
                            mirror.animation.isPlaying ? .pause : .play)
                    } label: {
                        Image(systemName: mirror.animation.isPlaying
                            ? "pause.fill" : "play.fill")
                    }
                    Button {
                        mirror.animationTransport(.stop)
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    Button(role: .destructive) {
                        mirror.setAnimationClip(nil)
                    } label: {
                        Image(systemName: "trash")
                    }
                    Spacer()
                    Text(Self.timecode(mirror.animation.time)
                         + " / " + Self.timecode(mirror.animation.duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                if mirror.animation.duration > 0 {
                    Slider(value: SwiftUI.Binding(
                        get: { mirror.animation.time },
                        set: { mirror.animationTransport(.seek($0)) }
                    ), in: 0...mirror.animation.duration)
                }
            }
        }
    }

    static func timecode(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d.%d",
                      whole / 60, whole % 60,
                      Int((seconds - Double(whole)) * 10))
    }
}

// MARK: - CustomDESection

/// Rows for the active EXTERNAL DE's params — dynamic-arena entries from the
/// snapshot, rendered by the same generic `ParameterRow` as static entries
/// (external DEs are indistinguishable past registration — Invariant 5's
/// spirit, CPU-side). Renders nothing when no external DE is active.
public struct CustomDESection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        if !mirror.dynamicEntries.isEmpty {
            Section("Custom DE") {
                ForEach(mirror.dynamicEntries, id: \.slot) { entry in
                    ParameterRow(entry: entry, mirror: mirror)
                }
            }
        }
    }
}

// MARK: - StatsSection

/// fps / GPU ms / steps readout + the pause toggle.
public struct StatsSection: View {
    let mirror: ParameterMirror
    // On by default: the app shell enables the governor at startup (stutter
    // is the default-config failure mode, ADR-003); this mirrors that state.
    @State private var autoQuality = true

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        Section("Session") {
            LabeledContent("FPS", value: String(format: "%.1f", mirror.stats.fps))
            LabeledContent("GPU", value: String(format: "%.2f ms", mirror.stats.gpuMilliseconds))
            LabeledContent("Steps", value: "\(mirror.stats.totalSteps)")
            LabeledContent(
                "Zoom Depth",
                value: String(format: "%+.1f oct", mirror.zoomDepthOctaves))
            Toggle("Paused", isOn: SwiftUI.Binding(
                get: { mirror.paused },
                set: { mirror.setPaused($0) }
            ))
            // ADR-003 governor: quality sliders stay the user's CEILING; the
            // governor only modulates below them.
            Toggle("Auto Quality", isOn: $autoQuality)
                .onChange(of: autoQuality) { _, on in
                    mirror.setQualityGovernor(on ? .platformDefault : nil)
                }
        }
    }
}

// MARK: - PipelineSection

/// The shader-compilation readout + advanced render tuning. Shows which
/// pipeline the encoder actually used this frame (the "is it even compiling?"
/// answer) and lets the user flip specialization / iteration-baking live —
/// the effect lands in the GPU-ms readout of `StatsSection` right above it.
public struct PipelineSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    private var status: (text: String, color: Color) {
        let d = mirror.diagnostics
        if d.specializationPending { return ("Compiling…", .orange) }
        if d.pipeline.isSpecialized { return (d.pipeline.label, .green) }
        if d.pipeline == .external { return (d.pipeline.label, .blue) }
        return (d.pipeline.label, .secondary)
    }

    public var body: some View {
        Section("Shader Pipeline") {
            LabeledContent("Active") {
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.text)
                }
            }
            if !mirror.diagnostics.bakedConstants.isEmpty {
                LabeledContent("Baked", value: mirror.diagnostics.bakedConstants)
                    .font(.caption)
            }
            if mirror.diagnostics.renderScale < 0.999 {
                LabeledContent(
                    "Render scale",
                    value: String(format: "%.0f%%", mirror.diagnostics.renderScale * 100))
            }
            Toggle("Specialized Pipeline", isOn: tuning(\.specializationEnabled))
            Group {
                Toggle("Bake Iterations (unroll)", isOn: tuning(\.bakeIterations))
                Toggle("Bake Max Steps", isOn: tuning(\.bakeMaxSteps))
                Toggle("Gate Warp Ops (DCE)", isOn: tuning(\.gateWarpOps))
                Toggle("Bake Color Map Mode", isOn: tuning(\.bakeColorMapMode))
                Toggle("Gate AO", isOn: tuning(\.gateAO))
            }
            .disabled(!mirror.renderTuning.specializationEnabled)
        }
    }

    /// Binding onto one field of the mirror's RenderTuning; a write rebuilds
    /// the whole value and publishes it (setRenderTuning contract).
    private func tuning(
        _ keyPath: WritableKeyPath<RenderTuning, Bool>
    ) -> SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { mirror.renderTuning[keyPath: keyPath] },
            set: { newValue in
                var next = mirror.renderTuning
                next[keyPath: keyPath] = newValue
                mirror.setRenderTuning(next)
            })
    }
}

// MARK: - WarpStackEdit (pure, testable)

/// Pure warp-stack list edits. Each returns a NEW array (the UI publishes the
/// whole modified stack via `mirror.setWarpStack` — SessionCommand's
/// replace-the-authored-stack contract). Out-of-range indices return the
/// stack unchanged.
public enum WarpStackEdit {
    public static func settingStrength(
        _ stack: [WarpOpDTO], at index: Int, to strength: Float
    ) -> [WarpOpDTO] {
        guard stack.indices.contains(index) else { return stack }
        var edited = stack
        edited[index].strength = strength
        return edited
    }

    public static func deleting(_ stack: [WarpOpDTO], at index: Int) -> [WarpOpDTO] {
        guard stack.indices.contains(index) else { return stack }
        var edited = stack
        edited.remove(at: index)
        return edited
    }

    /// Move the op at `index` by `offset` positions (−1 = up, +1 = down).
    /// No-op if either end of the move is out of range.
    public static func moving(_ stack: [WarpOpDTO], from index: Int, by offset: Int) -> [WarpOpDTO] {
        let destination = index + offset
        guard stack.indices.contains(index), stack.indices.contains(destination) else {
            return stack
        }
        var edited = stack
        let op = edited.remove(at: index)
        edited.insert(op, at: destination)
        return edited
    }
}

// MARK: - Warp op display metadata

extension WarpKind {
    /// Human-readable op name for editor rows and the add menu.
    public var uiName: String {
        switch self {
        case .none: return "None"
        case .twist: return "Twist"
        case .bend: return "Bend"
        case .ripple: return "Ripple"
        case .mirror: return "Mirror"
        case .boxFold: return "Box Fold"
        case .planeFold: return "Plane Fold"
        case .kaleidoscope: return "Kaleidoscope"
        case .coxeter: return "Coxeter"
        case .mengerFold: return "Menger Fold"
        case .offsetFold: return "Offset Fold"
        case .sphereFold: return "Sphere Fold"
        case .sphereInvert: return "Sphere Invert"
        case .tubeFold: return "Tube Fold"
        case .shells: return "Shells"
        case .scaleRepeat: return "Scale Repeat"
        case .tiling: return "Tiling"
        case .scale: return "Scale"
        case .sphereProject: return "Sphere Project"
        case .handAttract: return "Hand Attract"
        case .forearmCarve: return "Forearm Carve"
        case .bounding: return "Bounding"
        }
    }
}

// MARK: - WarpMenu (add-menu catalog)

/// The add-menu structure: constructible op kinds grouped by family, each
/// with a default-payload builder that goes through the IR's typed
/// constructors (WarpOps.swift) and back through `WarpOpDTO(op:)`.
/// `none` and `bounding` are excluded — no constructor exists (reserved).
public enum WarpMenu {
    public struct Item: Identifiable, Sendable {
        public let name: String
        /// Raw `WarpKind` value (UInt32) — exposed raw so clients/tests can
        /// match against `WarpOpDTO.kind` without an IR import.
        public let kindRawValue: UInt32
        private let make: @Sendable () -> WarpOpDTO

        public var id: UInt32 { kindRawValue }

        init(_ kind: WarpKind, make: @escaping @Sendable () -> WarpOpDTO) {
            self.name = kind.uiName
            self.kindRawValue = kind.rawValue
            self.make = make
        }

        /// A fresh op with this kind's default payload.
        public func makeDefault() -> WarpOpDTO { make() }
    }

    public struct Family: Identifiable, Sendable {
        public let name: String
        public let items: [Item]
        public var id: String { name }
    }

    /// Families follow the WarpKind declaration grouping (WarpOps.swift).
    public static let families: [Family] = [
        Family(name: "Bend & Wave", items: [
            Item(.twist) { WarpOpDTO(op: .twist(axis: [0, 1, 0], strength: 1)) },
            Item(.bend) { WarpOpDTO(op: .bend(axis: [0, 1, 0], strength: 0.5)) },
            Item(.ripple) { WarpOpDTO(op: .ripple(axis: [0, 1, 0], frequency: 4, strength: 0.1)) },
        ]),
        Family(name: "Mirrors & Folds", items: [
            Item(.mirror) { WarpOpDTO(op: .mirror()) },
            Item(.boxFold) { WarpOpDTO(op: .boxFold(limit: 1, strength: 1)) },
            Item(.planeFold) {
                WarpOpDTO(op: .planeFold(normal: [0, 1, 0], distance: 0, strength: 1))
            },
            Item(.kaleidoscope) { WarpOpDTO(op: .kaleidoscope(segments: 6, strength: 1)) },
            Item(.coxeter) { WarpOpDTO(op: .coxeter(p: 4, q: 3, strength: 1)) },
            Item(.mengerFold) { WarpOpDTO(op: .mengerFold(strength: 1)) },
            Item(.offsetFold) { WarpOpDTO(op: .offsetFold(center: [0, 0, 0], strength: 1)) },
        ]),
        Family(name: "Spherical & Radial", items: [
            Item(.sphereFold) {
                WarpOpDTO(op: .sphereFold(minRadius: 0.25, fixedRadius: 1, strength: 1))
            },
            Item(.sphereInvert) { WarpOpDTO(op: .sphereInvert(radius: 1, strength: 1)) },
            Item(.tubeFold) {
                WarpOpDTO(op: .tubeFold(innerRadius: 0.5, outerRadius: 1, strength: 1))
            },
            Item(.shells) { WarpOpDTO(op: .shells(spacing: 0.5, strength: 1)) },
        ]),
        Family(name: "Self-Similar Repeats", items: [
            Item(.scaleRepeat) { WarpOpDTO(op: .scaleRepeat(factor: 2, strength: 1)) },
            Item(.tiling) { WarpOpDTO(op: .tiling(cellSize: 2, strength: 1)) },
            Item(.scale) { WarpOpDTO(op: .scale(factor: 1.5, strength: 1)) },
        ]),
        Family(name: "Space Projection", items: [
            Item(.sphereProject) { WarpOpDTO(op: .sphereProject(radius: 1, strength: 1)) },
        ]),
        Family(name: "Hand & Distance", items: [
            Item(.handAttract) {
                WarpOpDTO(op: .handAttract(
                    center: [0, 0, 0], radius: 0.5, ballScale: 1, softness: 0.25,
                    pocketSize: 0.2, pocketSoftness: 0.1, pocketEnabled: false,
                    strength: 1))
            },
            Item(.forearmCarve) {
                WarpOpDTO(op: .forearmCarve(
                    from: [0, 0, 0], to: [0, 1, 0], radius: 0.2, softness: 0.1,
                    strength: 1))
            },
        ]),
    ]
}

// MARK: - PaletteEdit (pure, testable)

/// Pure gradient-stop list edits. Each returns a NEW `Palette` (the UI publishes
/// the whole palette via `mirror.setPalette`). Out-of-range indices are no-ops.
/// The `Palette` initializer re-sorts/clamps, so callers need not.
public enum PaletteEdit {
    public static func setColor(
        _ palette: Palette, at index: Int, red: Float, green: Float, blue: Float
    ) -> Palette {
        var stops = palette.stops
        guard stops.indices.contains(index) else { return palette }
        stops[index] = GradientStop(
            position: stops[index].position, red: red, green: green, blue: blue)
        return Palette(stops: stops)
    }

    public static func setPosition(_ palette: Palette, at index: Int, to position: Float) -> Palette {
        var stops = palette.stops
        guard stops.indices.contains(index) else { return palette }
        let s = stops[index]
        stops[index] = GradientStop(position: position, red: s.red, green: s.green, blue: s.blue)
        return Palette(stops: stops)
    }

    public static func deleting(_ palette: Palette, at index: Int) -> Palette {
        var stops = palette.stops
        guard stops.indices.contains(index), stops.count > 1 else { return palette }
        stops.remove(at: index)
        return Palette(stops: stops)
    }

    /// Add a stop at the midpoint of the largest gap, colored by sampling the
    /// current gradient there (so the insertion is visually seamless).
    public static func addingStop(_ palette: Palette) -> Palette {
        let stops = palette.stops
        guard stops.count < Palette.maxStops else { return palette }
        var position: Float = 0.5
        if stops.count >= 2 {
            var widest: Float = -1
            for i in 0..<(stops.count - 1) {
                let gap = stops[i + 1].position - stops[i].position
                if gap > widest {
                    widest = gap
                    position = (stops[i].position + stops[i + 1].position) / 2
                }
            }
        } else if let only = stops.first {
            position = only.position < 0.5 ? min(only.position + 0.25, 1) : max(only.position - 0.25, 0)
        }
        let c = palette.sample(t: position)
        return Palette(stops: stops + [
            GradientStop(position: position, red: c.red, green: c.green, blue: c.blue)])
    }
}

// MARK: - PaletteSection

/// The gradient editor (plan §5.5 stage 2): preset menu, live preview bar,
/// per-stop color/position rows, and a named color-mapping picker. The palette
/// is scene content, so edits publish the whole `Palette` — the same
/// replace-the-content contract as the warp stack.
public struct PaletteSection: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout

    public init(mirror: ParameterMirror, layout: CatalogLayout) {
        self.mirror = mirror
        self.layout = layout
    }

    private var palette: Palette { mirror.palette }

    /// SwiftUI colors from the LINEAR stop rgb (correct-space preview/edit).
    private static func color(_ s: GradientStop) -> Color {
        Color(.sRGBLinear, red: Double(s.red), green: Double(s.green), blue: Double(s.blue))
    }

    private var previewGradient: LinearGradient {
        let stops = palette.stops.map { s in
            Gradient.Stop(color: Self.color(s), location: Double(s.position))
        }
        return LinearGradient(
            gradient: Gradient(stops: stops.isEmpty
                ? [Gradient.Stop(color: .gray, location: 0)] : stops),
            startPoint: .leading, endPoint: .trailing)
    }

    public var body: some View {
        Section("Palette") {
            RoundedRectangle(cornerRadius: 4)
                .fill(previewGradient)
                .frame(height: 22)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))

            Menu("Preset") {
                ForEach(PalettePreset.builtIn) { preset in
                    Button(preset.name) { mirror.setPalette(preset.palette) }
                }
            }

            if let slot = layout.slot(for: .colorMapMode) {
                Picker("Mapping", selection: mappingBinding(slot: slot)) {
                    ForEach(ColorMapMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            ForEach(Array(palette.stops.enumerated()), id: \.offset) { index, stop in
                StopRow(index: index, stop: stop, mirror: mirror, canDelete: palette.stops.count > 1)
            }

            if palette.stops.count < Palette.maxStops {
                Button {
                    mirror.setPalette(PaletteEdit.addingStop(palette))
                } label: {
                    Label("Add Stop", systemImage: "plus")
                }
            }
        }
    }

    private func mappingBinding(slot: Int) -> SwiftUI.Binding<ColorMapMode> {
        SwiftUI.Binding(
            get: {
                ColorMapMode(rawValue: Int(mirror.displayValue(slot: slot).rounded())) ?? .orbitTrap
            },
            set: { mirror.updateEdit(slot: slot, target: Float($0.rawValue)) }
        )
    }
}

/// One gradient-stop row: color well + position slider + delete.
struct StopRow: View {
    let index: Int
    let stop: GradientStop
    let mirror: ParameterMirror
    let canDelete: Bool

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
            Slider(value: positionBinding, in: 0...1)
            Text(ValueFormatting.format(stop.position))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Button(role: .destructive) {
                mirror.setPalette(PaletteEdit.deleting(mirror.palette, at: index))
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
        }
    }

    private var colorBinding: SwiftUI.Binding<Color> {
        SwiftUI.Binding(
            get: {
                Color(.sRGBLinear, red: Double(stop.red),
                      green: Double(stop.green), blue: Double(stop.blue))
            },
            set: { newColor in
                let r = newColor.resolve(in: EnvironmentValues())
                mirror.setPalette(PaletteEdit.setColor(
                    mirror.palette, at: index,
                    red: r.linearRed, green: r.linearGreen, blue: r.linearBlue))
            }
        )
    }

    private var positionBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(stop.position) },
            set: { mirror.setPalette(PaletteEdit.setPosition(mirror.palette, at: index, to: Float($0))) }
        )
    }
}

// MARK: - HandsSection (visionOS)

/// Toggles for the hand-DRIVEN warp ops (plan §4.3 spatial path): each
/// toggle adds/removes a drive-flagged op in the AUTHORED stack — it is an
/// ordinary warp op afterwards (visible in the Warp Stack section, strength
/// slider and all); the Compositor shell stamps its geometry from the live
/// hand each frame. Rendered only where a hand tracker runs.
public struct HandsSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    /// The right-hand attract template: palm-centered soft attract sphere.
    /// Center (a.xyz) is stamped; radius/softness are authored and editable.
    static func attractOp() -> WarpOpDTO {
        WarpOpDTO(
            kind: UInt32(ThreshWarpKindHandAttract.rawValue),
            flags: WarpFlags.driveRightHand.rawValue,
            strength: 0.7,
            a: [0, 0, 0, 0.15],       // stamped center; radius 0.15
            b: [1, 0.08, 0.5, 0.05])  // ballScale, blend, pocketSize, pocketSoft
    }

    /// The left-forearm carve template: wrist→forearm capsule, subtractive.
    static func carveOp() -> WarpOpDTO {
        WarpOpDTO(
            kind: UInt32(ThreshWarpKindForearmCarve.rawValue),
            flags: WarpFlags.driveLeftHand.rawValue,
            strength: 0.9,
            a: [0, 0, 0, 0.06],   // stamped capsule start; radius 0.06
            b: [0, 0, 0, 0.04])   // stamped capsule end; blend 0.04
    }

    private func hasOp(_ template: WarpOpDTO) -> Bool {
        mirror.warpStack.contains {
            $0.kind == template.kind && $0.flags == template.flags
        }
    }

    private func toggleOp(_ template: WarpOpDTO, on: Bool) {
        if on {
            guard !hasOp(template) else { return }
            mirror.setWarpStack(mirror.warpStack + [template])
        } else {
            mirror.setWarpStack(mirror.warpStack.filter {
                !($0.kind == template.kind && $0.flags == template.flags)
            })
        }
    }

    public var body: some View {
        Section("Hands") {
            Toggle("Right Hand Sculpts", isOn: SwiftUI.Binding(
                get: { hasOp(Self.attractOp()) },
                set: { toggleOp(Self.attractOp(), on: $0) }
            ))
            Toggle("Left Forearm Carves", isOn: SwiftUI.Binding(
                get: { hasOp(Self.carveOp()) },
                set: { toggleOp(Self.carveOp(), on: $0) }
            ))
        }
    }
}

// MARK: - WarpStackSection

/// Editor over the AUTHORED warp stack: per-op rows (name, strength slider,
/// reorder, delete) + the add menu. Every mutation builds a full modified
/// stack with the pure `WarpStackEdit` helpers and publishes it via
/// `mirror.setWarpStack`.
public struct WarpStackSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        Section("Warp Stack") {
            if mirror.warpStack.isEmpty {
                Text("No warp ops")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(mirror.warpStack.enumerated()), id: \.offset) { index, op in
                WarpOpRow(index: index, op: op, mirror: mirror)
            }
            Menu("Add Warp") {
                ForEach(WarpMenu.families) { family in
                    Menu(family.name) {
                        ForEach(family.items) { item in
                            Button(item.name) {
                                mirror.setWarpStack(mirror.warpStack + [item.makeDefault()])
                            }
                        }
                    }
                }
            }
        }
    }
}

struct WarpOpRow: View {
    let index: Int
    let op: WarpOpDTO
    let mirror: ParameterMirror

    private var kind: WarpKind? { WarpKind(rawValue: op.kind) }

    /// Distance ops use signed strength (attract vs repel); point ops blend.
    private var strengthRange: ClosedRange<Float> {
        (kind?.isDistanceOp ?? false) ? -2...2 : 0...2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kind?.uiName ?? "Unknown (\(op.kind))")
                    .font(.caption)
                Spacer()
                Button {
                    mirror.setWarpStack(WarpStackEdit.moving(mirror.warpStack, from: index, by: -1))
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                Button {
                    mirror.setWarpStack(WarpStackEdit.moving(mirror.warpStack, from: index, by: 1))
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index >= mirror.warpStack.count - 1)
                Button(role: .destructive) {
                    mirror.setWarpStack(WarpStackEdit.deleting(mirror.warpStack, at: index))
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
            HStack {
                Slider(value: SwiftUI.Binding(
                    get: { Double(op.strength) },
                    set: { newStrength in
                        mirror.setWarpStack(WarpStackEdit.settingStrength(
                            mirror.warpStack, at: index, to: Float(newStrength)))
                    }
                ), in: Double(strengthRange.lowerBound)...Double(strengthRange.upperBound))
                Text(ValueFormatting.format(op.strength))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
    }
}
