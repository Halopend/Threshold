// Panels.swift — catalog-derived sections and the control sidebar
// (plan §2.2, phase 4). Every parameter row here comes from walking
// CatalogLayout; the only hand-built sections are the structural ones the
// catalog cannot describe (DE choice, warp stack, render stats).
//
// Navigation and card styling port the legacy app's control panel (tab strip
// → tinted module cards → compact slider rows); the data flow is unchanged:
// read the mirror, publish commands.

import SwiftUI
import ThresholdCore
import ThresholdRender
import ThresholdShaderABI
import ThresholdShaderIR

// MARK: - ControlTab

/// Top-level control panel tabs (the legacy sidebar-tab taxonomy fitted to
/// the rebuild's structure; Music and Transition await their features).
/// Tabs with more than one `subtabs` entry get a second selector row (the
/// legacy top-dock → section-rail two-level pattern).
public enum ControlTab: String, CaseIterable, Sendable {
    case scenes
    case fractal
    case warps
    case color
    case motion
    case setup

    public var label: String {
        switch self {
        case .scenes: return "Scenes"
        case .fractal: return "Fractal"
        case .warps: return "Warps"
        case .color: return "Color"
        case .motion: return "Motion"
        case .setup: return "Setup"
        }
    }

    public var icon: String {
        switch self {
        case .scenes: return "photo.on.rectangle.angled"
        case .fractal: return "cube.fill"
        case .warps: return "square.stack.3d.up"
        case .color: return "paintpalette.fill"
        case .motion: return "film.stack"
        case .setup: return "gearshape.fill"
        }
    }

    /// One entry per second-row section. Empty or single → no second row
    /// (the tab renders its one section list directly).
    public var subtabs: [SubTab] {
        switch self {
        case .color:
            return [
                SubTab("palette", "Palette", "paintpalette.fill"),
                SubTab("mapping", "Mapping", "swatchpalette.fill"),
                SubTab("grading", "Grading", "camera.filters"),
            ]
        case .motion:
            return [
                SubTab("zoom", "Zoom", "plus.magnifyingglass"),
                SubTab("animation", "Animate", "film.stack"),
                SubTab("camera", "Camera", "move.3d"),
            ]
        case .setup:
            return [
                SubTab("prefs", "Prefs", "slider.horizontal.3"),
                SubTab("performance", "Performance", "speedometer"),
            ]
        default:
            return []
        }
    }
}

/// One second-row section under a `ControlTab`.
public struct SubTab: Hashable, Sendable {
    public let id: String
    public let label: String
    public let icon: String

    public init(_ id: String, _ label: String, _ icon: String) {
        self.id = id
        self.label = label
        self.icon = icon
    }
}

// MARK: - ControlSidebar

/// The whole control surface: a tab strip over per-tab card stacks. Tab
/// selection persists across launches (AppStorage, device-local UI state —
/// not scene content).
public struct ControlSidebar: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout
    /// Scene-library verbs from the shell; nil hides the Scenes tab (the
    /// SwiftPM dev shell passes nothing and keeps its lean surface).
    let sceneActions: SceneActions?
    /// Clip-library verbs from the shell; nil drops the clip list from the
    /// Motion ▸ Animate sub-tab (transport still shows).
    let animationActions: AnimationActions?

    @AppStorage("threshold.ui.controlTab")
    private var storedTab = ControlTab.fractal.rawValue
    @AppStorage(DS.textSizeStorageKey)
    private var textSizeIndex = DS.defaultTextSizeIndex
    // Second-row selection per tab that has one (device-local, persisted).
    @AppStorage("threshold.ui.subtab.color") private var colorSub = "palette"
    @AppStorage("threshold.ui.subtab.motion") private var motionSub = "zoom"
    @AppStorage("threshold.ui.subtab.setup") private var setupSub = "prefs"

    public init(
        mirror: ParameterMirror, layout: CatalogLayout,
        sceneActions: SceneActions? = nil,
        animationActions: AnimationActions? = nil
    ) {
        self.mirror = mirror
        self.layout = layout
        self.sceneActions = sceneActions
        self.animationActions = animationActions
    }

    private var tabs: [ControlTab] {
        ControlTab.allCases.filter { $0 != .scenes || sceneActions != nil }
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

    /// Groups a dedicated tab already renders. Anything else (a future
    /// registration) falls through to a generic card on the Fractal tab so
    /// no parameter can silently vanish from the UI.
    nonisolated static let placedGroups: Set<GroupID> = [
        .shape, .color, .camera, .performance,
    ]

    private var tabBinding: SwiftUI.Binding<ControlTab> {
        SwiftUI.Binding(
            get: {
                // A stored tab this shell does not offer (e.g. .scenes in the
                // dev shell) falls back rather than rendering nothing.
                let tab = ControlTab(rawValue: storedTab) ?? .fractal
                return tabs.contains(tab) ? tab : .fractal
            },
            set: { storedTab = $0.rawValue })
    }

    /// The persisted second-row selection for `tab` (only tabs with subtabs
    /// have backing storage; others return an empty binding never read).
    private func subtabBinding(for tab: ControlTab) -> SwiftUI.Binding<String> {
        switch tab {
        case .color: return $colorSub
        case .motion: return $motionSub
        case .setup: return $setupSub
        default: return .constant("")
        }
    }

    /// The selected subtab id for `tab`, snapped to a valid entry (a stored id
    /// that no longer exists falls back to the first subtab).
    private func selectedSubtab(for tab: ControlTab) -> String {
        let subs = tab.subtabs
        let stored = subtabBinding(for: tab).wrappedValue
        return subs.contains { $0.id == stored } ? stored : (subs.first?.id ?? "")
    }

    public var body: some View {
        let tab = tabBinding.wrappedValue
        VStack(spacing: 0) {
            TabStrip(
                items: tabs.map {
                    TabStrip.Item($0, label: $0.label, icon: $0.icon)
                },
                selection: tabBinding
            )
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)

            // Second row: appears only for tabs that declare subtabs.
            if tab.subtabs.count > 1 {
                Divider()
                TabStrip(
                    items: tab.subtabs.map {
                        TabStrip.Item($0.id, label: $0.label, icon: $0.icon)
                    },
                    selection: SwiftUI.Binding(
                        get: { selectedSubtab(for: tab) },
                        set: { subtabBinding(for: tab).wrappedValue = $0 })
                )
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background(.quaternary.opacity(0.4))
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    content(for: tab, subtab: selectedSubtab(for: tab))
                }
                .padding(DS.Spacing.md)
                // Setup ▸ Prefs ▸ Display drives the PANEL's text size only —
                // reflowed Dynamic Type, chrome untouched.
                .dynamicTypeSize(DS.textSize(forIndex: textSizeIndex))
            }
        }
    }

    @ViewBuilder
    private func content(for tab: ControlTab, subtab: String) -> some View {
        switch tab {
        case .scenes:
            if let sceneActions {
                ScenesSection(actions: sceneActions)
            }
        case .fractal:
            FractalSwitcherSection(mirror: mirror)
            CustomDESection(mirror: mirror)
            ShapeParamsSection(mirror: mirror, layout: layout)
            ForEach(
                Self.groupsInOrder(layout).filter { !Self.placedGroups.contains($0) },
                id: \.self
            ) { group in
                CatalogSectionView(group: group, layout: layout, mirror: mirror)
            }
        case .warps:
            #if os(visionOS)
            HandsSection(mirror: mirror)
            #endif
            WarpStackSection(mirror: mirror)
        case .color:
            switch subtab {
            case "mapping":
                ColorMappingSection(mirror: mirror, layout: layout)
            case "grading":
                KeyedParamsSection(
                    title: "Grading", icon: "camera.filters", accent: .orange,
                    keys: [
                        .colorSaturation, .colorContrast, .colorVibrance,
                        .colorBrightness, .colorGamma, .colorTonemap,
                    ],
                    mirror: mirror, layout: layout)
            default:
                PaletteSection(mirror: mirror, layout: layout)
            }
        case .motion:
            switch subtab {
            case "animation":
                if let animationActions {
                    AnimationLibrarySection(actions: animationActions)
                }
                AnimationSection(mirror: mirror)
            case "camera":
                KeyedParamsSection(
                    title: "Camera", icon: "move.3d", accent: .cyan,
                    keys: [.cameraOrbitYaw, .cameraOrbitPitch, .cameraDolly],
                    mirror: mirror, layout: layout,
                    footer: "Drag the view to orbit · pinch or scroll to dolly.")
            default:
                ZoomSection(mirror: mirror, layout: layout)
            }
        case .setup:
            switch subtab {
            case "performance":
                StatsSection(mirror: mirror)
                PipelineSection(mirror: mirror)
                CatalogSectionView(group: .performance, layout: layout, mirror: mirror)
            default:
                DisplaySettingsSection()
                InputSettingsSection()
            }
        }
    }
}

// MARK: - CatalogSectionView

/// All rows of one UI group: `layout.entries` filtered by `spec.group`,
/// rendered by the generic `ParameterRow`. Zero per-param code.
public struct CatalogSectionView: View {
    let group: GroupID
    let layout: CatalogLayout
    let mirror: ParameterMirror
    /// Base slots rendered by a dedicated section elsewhere — skip them here
    /// to avoid duplicate controls.
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
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader(group.rawValue.capitalized, icon: "slider.horizontal.3")
            ForEach(
                layout.entries.filter { $0.spec.group == group && !excludedSlots.contains($0.slot) },
                id: \.slot
            ) { entry in
                ParameterRow(entry: entry, mirror: mirror)
            }
        }
        .moduleCard(.gray)
    }
}

// MARK: - KeyedParamsSection

/// A titled card over an explicit list of catalog keys — the hand-arranged
/// counterpart of `CatalogSectionView` for tabs that split one group across
/// several cards (mapping vs grading, zoom vs camera). Rows still come from
/// the catalog; only membership and ordering are hand-picked. Keys missing
/// from the layout are skipped; an all-missing card renders nothing.
public struct KeyedParamsSection: View {
    let title: String
    let icon: String
    let accent: Color
    let keys: [ParamKey]
    let mirror: ParameterMirror
    let layout: CatalogLayout
    let footer: String?

    public init(
        title: String, icon: String, accent: Color,
        keys: [ParamKey], mirror: ParameterMirror, layout: CatalogLayout,
        footer: String? = nil
    ) {
        self.title = title
        self.icon = icon
        self.accent = accent
        self.keys = keys
        self.mirror = mirror
        self.layout = layout
        self.footer = footer
    }

    public var body: some View {
        let entries = keys.compactMap { layout.entry(for: $0) }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                SectionHeader(title, icon: icon)
                KeyedParamRows(entries: entries, mirror: mirror)
                if let footer {
                    Text(footer)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .moduleCard(accent)
        }
    }
}

/// The rows of a keyed card: float entries get an icon slider row; other
/// kinds fall through to the generic `ParameterRow`.
struct KeyedParamRows: View {
    let entries: [CatalogEntry]
    let mirror: ParameterMirror

    var body: some View {
        ForEach(entries, id: \.slot) { entry in
            if case .float = entry.spec.kind {
                FloatSlotRow(
                    label: entry.spec.label,
                    slot: entry.slot,
                    range: entry.spec.range,
                    curve: entry.spec.curve,
                    mirror: mirror,
                    icon: DisplayIcons.param(entry.spec.key))
            } else {
                ParameterRow(entry: entry, mirror: mirror)
            }
        }
    }
}

// MARK: - FractalSwitcherSection

/// A prominent, tappable fractal (DE) switcher — a grid of big icon buttons
/// with the active one highlighted. Far easier to hit in a headset than a
/// dropdown and shows the current fractal at a glance. Built-ins only; an
/// active external DE leaves none highlighted (and tapping a built-in
/// switches to it, clearing the external — setDE contract).
public struct FractalSwitcherSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: DS.Spacing.xs)]

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Fractal", icon: "cube.fill")
            LazyVGrid(columns: columns, spacing: DS.Spacing.xs) {
                ForEach(DERegistry.builtin, id: \.key) { descriptor in
                    let active = mirror.deKey == descriptor.key
                    Button {
                        mirror.setDE(key: descriptor.key)
                    } label: {
                        VStack(spacing: DS.Spacing.xxs) {
                            Image(systemName: DisplayIcons.fractal(descriptor.key))
                                .font(.title3)
                            Text(descriptor.displayName)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                    .tint(active ? .accentColor : .secondary)
                    .overlay(alignment: .topTrailing) {
                        if active {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .padding(3)
                        }
                    }
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
        .moduleCard(.purple)
    }
}

// MARK: - DEPickerSection

/// Distance-estimator picker over `DERegistry.builtin` → `mirror.setDE`.
/// (Compact alternative to the switcher grid; not in the default sidebar.)
public struct DEPickerSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
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

// MARK: - ShapeParamsSection

/// The ACTIVE fractal's parameters (the legacy formula editor): rows for the
/// current DE's declared params only — inactive DEs' entries stay registered
/// but are not shown — plus a reset-to-defaults button. Renders nothing when
/// an external DE is active (CustomDESection owns that case).
public struct ShapeParamsSection: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout

    public init(mirror: ParameterMirror, layout: CatalogLayout) {
        self.mirror = mirror
        self.layout = layout
    }

    private var descriptor: DEDescriptor? {
        DERegistry.descriptor(forKey: mirror.deKey)
    }

    /// "minRadius" → "Min Radius" (labels registered as "Mandelbox minRadius"
    /// read poorly inside a card already titled with the fractal's name).
    nonisolated static func prettify(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase && !current.isEmpty {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    public var body: some View {
        if let descriptor {
            let entries = descriptor.paramLayout.compactMap { param in
                layout.entry(for: .de(descriptor.key, param.name)).map { (param.name, $0) }
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                SectionHeader("Shape", icon: "slider.horizontal.3") {
                    Button {
                        reset(entries.map(\.1))
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Text(descriptor.equation)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                ForEach(entries, id: \.1.slot) { name, entry in
                    FloatSlotRow(
                        label: Self.prettify(name),
                        slot: entry.slot,
                        range: entry.spec.range,
                        curve: entry.spec.curve,
                        mirror: mirror)
                }
            }
            .moduleCard(.purple)
        }
    }

    /// Write every entry back to its spec default through the normal edit
    /// path (begin → update → end commits to the scene lane).
    private func reset(_ entries: [CatalogEntry]) {
        for entry in entries {
            for component in 0..<entry.spec.kind.slotWidth {
                let slot = entry.slot + component
                mirror.beginEdit(slot: slot)
                mirror.updateEdit(slot: slot, target: entry.spec.defaultValue[component])
                mirror.endEdit(slot: slot)
            }
        }
    }
}

// MARK: - AnimationSection

/// Transport for the loaded animation clip (play/pause/stop + scrub) with an
/// empty-state hint when nothing is loaded. All state is snapshot readback;
/// verbs go through the command mailbox — the mirror computes no transport
/// logic.
public struct AnimationSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Animation", icon: "film.stack")
            if mirror.animation.hasClip {
                LabeledContent("Clip", value: mirror.animation.clipName ?? "Untitled")
                HStack(spacing: DS.Spacing.lg) {
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
            } else {
                Text("No animation loaded — open a .threshanim or a scene that ships a clip.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .moduleCard(.blue)
    }

    static func timecode(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d.%d",
                      whole / 60, whole % 60,
                      Int((seconds - Double(whole)) * 10))
    }
}

// MARK: - ZoomSection

/// Infinite zoom (plan §6.3): the zoom-speed integrator rate, the zoom phase,
/// and the live rebase-aware depth readout.
public struct ZoomSection: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout

    public init(mirror: ParameterMirror, layout: CatalogLayout) {
        self.mirror = mirror
        self.layout = layout
    }

    public var body: some View {
        let entries = [ParamKey.scaleZoomSpeed, .scaleZoom].compactMap { layout.entry(for: $0) }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                SectionHeader("Infinite Zoom", icon: "plus.magnifyingglass") {
                    Text(String(format: "%+.1f oct", mirror.zoomDepthOctaves))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                KeyedParamRows(entries: entries, mirror: mirror)
                Text("Speed keeps zooming; Zoom scrubs the current depth.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .moduleCard(.blue)
        }
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
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                SectionHeader("Custom DE", icon: "chevron.left.forwardslash.chevron.right")
                ForEach(mirror.dynamicEntries, id: \.slot) { entry in
                    ParameterRow(entry: entry, mirror: mirror)
                }
            }
            .moduleCard(.indigo)
        }
    }
}

// MARK: - StatsSection

/// fps / GPU ms / steps / zoom-depth tiles + the pause and governor toggles.
public struct StatsSection: View {
    let mirror: ParameterMirror
    // On by default: the app shell enables the governor at startup (stutter
    // is the default-config failure mode, ADR-003); this mirrors that state.
    @State private var autoQuality = true

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Session", icon: "gauge.with.dots.needle.67percent")
            HStack(spacing: DS.Spacing.xs) {
                StatBox(
                    label: "FPS",
                    value: String(format: "%.0f", mirror.stats.fps),
                    color: .green)
                StatBox(
                    label: "GPU ms",
                    value: String(format: "%.2f", mirror.stats.gpuMilliseconds),
                    color: .orange)
                StatBox(
                    label: "Steps",
                    value: "\(mirror.stats.totalSteps)",
                    color: .blue)
                StatBox(
                    label: "Zoom",
                    value: String(format: "%+.1f", mirror.zoomDepthOctaves),
                    color: .purple)
            }
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
        .moduleCard(.green)
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
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Shader Pipeline", icon: "cpu") {
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            // Manual upscaling: march at reduced internal resolution and
            // MetalFX-upscale to full res. Applies when Auto Quality (the fps
            // governor) is OFF; otherwise the governor drives the scale.
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Quality")
                    Slider(value: renderScale, in: 0.1...1.0)
                    Text(String(format: "%.0f%%", mirror.renderTuning.manualRenderScale * 100))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                }
                // The manual render-resolution lever. On Mac this feeds MetalFX
                // upscaling; on Vision Pro it drives the compositor renderQuality
                // (the drawable shrinks, the compositor upscales natively). Only
                // takes effect with Auto Quality OFF — otherwise the governor
                // owns the scale. This is the independent variable for profiling.
                Text("render resolution — Auto Quality must be off")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Toggle("Specialized Pipeline", isOn: tuning(\.specializationEnabled))
            Group {
                Toggle("Bake Iterations (unroll)", isOn: tuning(\.bakeIterations))
                Toggle("Bake Max Steps", isOn: tuning(\.bakeMaxSteps))
                Toggle("Gate Warp Ops (DCE)", isOn: tuning(\.gateWarpOps))
                Toggle("Bake Color Map Mode", isOn: tuning(\.bakeColorMapMode))
                Toggle("Gate AO", isOn: tuning(\.gateAO))

                // Hierarchical cone-march prepass: the big step-count win, but
                // its tile-shared start depths shimmer at silhouettes. Stability
                // trades that shimmer back for a few steps (higher = smoother).
                Divider().padding(.vertical, 2)
                Toggle("Cone Prepass (hierarchical)", isOn: tuning(\.conePrepass))
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Cone Stability", selection: coneStability) {
                        ForEach(ConeStability.allCases, id: \.self) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!mirror.renderTuning.conePrepass)
                    Text("higher = less silhouette shimmer, slightly slower")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(!mirror.renderTuning.specializationEnabled)
        }
        .moduleCard(.orange)
    }

    /// Binding onto the RenderTuning cone-stability level (segmented picker).
    private var coneStability: SwiftUI.Binding<ConeStability> {
        SwiftUI.Binding(
            get: { mirror.renderTuning.coneStability },
            set: { newValue in
                var next = mirror.renderTuning
                next.coneStability = newValue
                mirror.setRenderTuning(next)
            })
    }

    /// Binding onto one Bool field of the mirror's RenderTuning; a write
    /// rebuilds the whole value and publishes it (setRenderTuning contract).
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

    /// The manual render-scale slider binding (Float ↔ Double).
    private var renderScale: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(mirror.renderTuning.manualRenderScale) },
            set: { newValue in
                var next = mirror.renderTuning
                next.manualRenderScale = Float(newValue)
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

    /// The family a constructible op kind belongs to (display metadata for
    /// op rows). Reserved kinds (`none`, `bounding`) have no family.
    public static func familyName(forKindRaw raw: UInt32) -> String? {
        families.first { $0.items.contains { $0.kindRawValue == raw } }?.name
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

/// The gradient editor (plan §5.5 stage 2): live preview bar, a tappable
/// preset grid (the legacy browse pattern — the active preset is outlined),
/// and per-stop color/position rows. The palette is scene content, so edits
/// publish the whole `Palette` — the same replace-the-content contract as the
/// warp stack.
public struct PaletteSection: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout

    public init(mirror: ParameterMirror, layout: CatalogLayout) {
        self.mirror = mirror
        self.layout = layout
    }

    private var palette: Palette { mirror.palette }

    private let presetColumns = [GridItem(.adaptive(minimum: 64), spacing: DS.Spacing.xxs)]

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Palette", icon: "paintpalette.fill")
            GradientPreviewBar(palette: palette)

            LazyVGrid(columns: presetColumns, spacing: DS.Spacing.xs) {
                ForEach(PalettePreset.builtIn) { preset in
                    let active = preset.palette == palette
                    Button {
                        mirror.setPalette(preset.palette)
                    } label: {
                        VStack(spacing: 2) {
                            GradientPreviewBar(palette: preset.palette, height: 14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Radius.xs)
                                        .strokeBorder(
                                            active ? Color.accentColor : .clear,
                                            lineWidth: 2))
                            Text(preset.name)
                                .font(.caption2)
                                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }

            HStack {
                Text("Stops")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if palette.stops.count < Palette.maxStops {
                    Button {
                        mirror.setPalette(PaletteEdit.addingStop(palette))
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, DS.Spacing.xxs)

            ForEach(Array(palette.stops.enumerated()), id: \.offset) { index, stop in
                StopRow(index: index, stop: stop, mirror: mirror, canDelete: palette.stops.count > 1)
            }
        }
        .moduleCard(.pink)
    }
}

/// One gradient-stop row: color well + position slider + delete.
struct StopRow: View {
    let index: Int
    let stop: GradientStop
    let mirror: ParameterMirror
    let canDelete: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
            Slider(value: positionBinding, in: 0...1)
            RowValueText(text: ValueFormatting.format(stop.position))
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

// MARK: - ColorMappingSection

/// How geometry becomes gradient position: the named color-mapping picker
/// plus the palette-sampling transforms (repeat / offset / smoothing).
public struct ColorMappingSection: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout

    public init(mirror: ParameterMirror, layout: CatalogLayout) {
        self.mirror = mirror
        self.layout = layout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Mapping", icon: "swatchpalette.fill")
            if let slot = layout.slot(for: .colorMapMode) {
                Picker("Mapping", selection: mappingBinding(slot: slot)) {
                    ForEach(ColorMapMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            KeyedParamRows(
                entries: [
                    ParamKey.colorGradientRepeat, .colorGradientOffset,
                    .colorGradientSmoothing,
                ].compactMap { layout.entry(for: $0) },
                mirror: mirror)
        }
        .moduleCard(.teal)
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
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Hands", icon: "hand.raised.fingers.spread")
            Toggle("Right Hand Sculpts", isOn: SwiftUI.Binding(
                get: { hasOp(Self.attractOp()) },
                set: { toggleOp(Self.attractOp(), on: $0) }
            ))
            Toggle("Left Forearm Carves", isOn: SwiftUI.Binding(
                get: { hasOp(Self.carveOp()) },
                set: { toggleOp(Self.carveOp(), on: $0) }
            ))
            Text("Each toggle adds a live hand-driven op to the warp stack below.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .moduleCard(.green)
    }
}

// MARK: - WarpStackSection

/// Editor over the AUTHORED warp stack: per-op cards (index badge, family
/// icon, name, reorder, delete, strength) + the add menu. Every mutation
/// builds a full modified stack with the pure `WarpStackEdit` helpers and
/// publishes it via `mirror.setWarpStack`.
public struct WarpStackSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Warp Stack", icon: "square.stack.3d.up") {
                Menu {
                    ForEach(WarpMenu.families) { family in
                        Menu(family.name) {
                            ForEach(family.items) { item in
                                Button(item.name) {
                                    mirror.setWarpStack(mirror.warpStack + [item.makeDefault()])
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if mirror.warpStack.isEmpty {
                Text("No warp ops — Add stacks space transforms that reshape the fractal.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(mirror.warpStack.enumerated()), id: \.offset) { index, op in
                WarpOpRow(index: index, op: op, mirror: mirror)
            }
        }
        .moduleCard(.indigo)
    }
}

/// One warp-op card: index badge + family icon + name + reorder/delete row,
/// over the strength slider.
struct WarpOpRow: View {
    let index: Int
    let op: WarpOpDTO
    let mirror: ParameterMirror

    private var kind: WarpKind? { WarpKind(rawValue: op.kind) }

    /// Distance ops use signed strength (attract vs repel); point ops blend.
    private var strengthRange: ClosedRange<Float> {
        (kind?.isDistanceOp ?? false) ? -2...2 : 0...2
    }

    private var familyIcon: String {
        DisplayIcons.warpFamily(WarpMenu.familyName(forKindRaw: op.kind) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.quaternary))
                Image(systemName: familyIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(kind?.uiName ?? "Unknown (\(op.kind))")
                    .font(.subheadline.weight(.medium))
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
            HStack(spacing: DS.Spacing.sm) {
                Slider(value: SwiftUI.Binding(
                    get: { Double(op.strength) },
                    set: { newStrength in
                        mirror.setWarpStack(WarpStackEdit.settingStrength(
                            mirror.warpStack, at: index, to: Float(newStrength)))
                    }
                ), in: Double(strengthRange.lowerBound)...Double(strengthRange.upperBound))
                RowValueText(text: ValueFormatting.format(op.strength))
            }
        }
        .padding(DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.inset)
                .fill(.quaternary.opacity(0.5)))
    }
}
