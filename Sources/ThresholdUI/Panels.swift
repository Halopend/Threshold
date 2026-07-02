// Panels.swift — catalog-derived sections and the control sidebar
// (plan §2.2, phase 4). Every parameter row here comes from walking
// CatalogLayout; the only hand-built sections are the structural ones the
// catalog cannot describe (DE choice, warp stack, render stats).

import SwiftUI
import ThresholdCore
import ThresholdShaderIR

// MARK: - CatalogSectionView

/// All rows of one UI group: `layout.entries` filtered by `spec.group`,
/// rendered by the generic `ParameterRow`. Zero per-param code.
public struct CatalogSectionView: View {
    let group: GroupID
    let layout: CatalogLayout
    let mirror: ParameterMirror

    public init(group: GroupID, layout: CatalogLayout, mirror: ParameterMirror) {
        self.group = group
        self.layout = layout
        self.mirror = mirror
    }

    public var body: some View {
        Section(group.rawValue.capitalized) {
            ForEach(layout.entries.filter { $0.spec.group == group }, id: \.slot) { entry in
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
            DEPickerSection(mirror: mirror)
            WarpStackSection(mirror: mirror)
            ForEach(Self.groupsInOrder(layout), id: \.self) { group in
                CatalogSectionView(group: group, layout: layout, mirror: mirror)
            }
        }
        .formStyle(.grouped)
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

// MARK: - StatsSection

/// fps / GPU ms / steps readout + the pause toggle.
public struct StatsSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        Section("Session") {
            LabeledContent("FPS", value: String(format: "%.1f", mirror.stats.fps))
            LabeledContent("GPU", value: String(format: "%.2f ms", mirror.stats.gpuMilliseconds))
            LabeledContent("Steps", value: "\(mirror.stats.totalSteps)")
            Toggle("Paused", isOn: SwiftUI.Binding(
                get: { mirror.paused },
                set: { mirror.setPaused($0) }
            ))
        }
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
