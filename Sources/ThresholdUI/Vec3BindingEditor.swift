// Vec3BindingEditor.swift — the custom UI element the gesture system is built
// around: assign a parameter (or a named x/y/z triple) to one gesture source.
//
// Two goals shape it:
//   • assign a whole X/Y/Z group in ONE TAP — native `.float3` params and
//     auto-detected external triples appear as quick-pick chips, not buried in
//     a menu (the "just assign XYZ easily" requirement);
//   • per-axis assignment stays available under a "Split axes" disclosure.
// A scope control (This fractal / All fractals) decides whether the binding is
// fractal-specific or global. It degrades to a single-param picker for scalar
// sources (palm tap, fist). No parameter is named in here.

import SwiftUI
import ThresholdCore

// MARK: - Vec3BindingEditor

public struct Vec3BindingEditor: View {
    let source: GestureSource
    /// Fractal identity (`deKey`) — the per-fractal storage key.
    let fractal: String
    let params: BindableParams
    let store: GestureBindingStore

    /// Scope for NEW assignments while this source is unbound. Once bound, the
    /// store is authoritative (`isGlobal`).
    @State private var preferGlobalWhenUnbound = false

    public init(source: GestureSource, fractal: String,
                params: BindableParams, store: GestureBindingStore) {
        self.source = source
        self.fractal = fractal
        self.params = params
        self.store = store
    }

    private var binding: GestureBinding? { store.binding(for: source, fractal: fractal) }

    private var vec3Target: Vec3Target? {
        if case let .vector(target) = binding { return target }
        return nil
    }

    /// Whether the effective binding is (or new ones will be) global.
    private var isGlobal: Bool {
        store.scope(of: source, fractal: fractal).map { $0 == .global } ?? preferGlobalWhenUnbound
    }
    /// Where writes land, honoring the scope control.
    private var writeScope: GestureScope { isGlobal ? .global : .fractal(fractal) }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader(source.displayName, icon: source.iconName) {
                if binding != nil {
                    Button("Clear") { assign(nil) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            scopeControl
            summaryLine

            switch source.arity {
            case .vector: vectorControls
            case .scalar: scalarControls
            }
        }
        .moduleCard(source.accent)
    }

    // MARK: Scope

    private var scopeControl: some View {
        Picker("Applies to", selection: SwiftUI.Binding(
            get: { isGlobal },
            set: { newGlobal in
                if store.scope(of: source, fractal: fractal) != nil {
                    store.setScope(newGlobal ? .global : .fractal(fractal),
                                   for: source, fractal: fractal)
                }
                preferGlobalWhenUnbound = newGlobal
            })) {
            Text("This fractal").tag(false)
            Text("All fractals").tag(true)
        }
        .pickerStyle(.segmented)
    }

    // MARK: Summary

    private var summaryLine: some View {
        Text(summaryText)
            .font(.caption2)
            .foregroundStyle(binding == nil ? .tertiary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summaryText: String {
        switch binding {
        case nil: return "Unassigned"
        case let .vector(.native(key)): return "→ \(params.label(for: key)) · whole X/Y/Z"
        case let .vector(.grouped(x, y, z)):
            let parts = [("X", x), ("Y", y), ("Z", z)].compactMap { tag, key in
                key.map { "\(tag): \(params.label(for: $0))" }
            }
            return parts.isEmpty ? "No axes assigned" : parts.joined(separator: "  ·  ")
        case let .scalar(key): return "→ \(params.label(for: key))"
        case let .scalarAxis(key, axis): return "→ \(axis.rawValue.uppercased()): \(params.label(for: key))"
        case let .core(action): return "→ \(action.displayName)"
        }
    }

    // MARK: Vector source — quick group pick + split axes

    @ViewBuilder private var vectorControls: some View {
        if params.vectors.isEmpty && params.groups.isEmpty {
            Text("This fractal exposes no X/Y/Z parameters. Use Split axes to map "
                 + "individual dials, or bind a scalar action below.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Assign a group").font(.caption2).foregroundStyle(.secondary)
            FlowChips {
                ForEach(params.vectors) { item in
                    GroupChip(title: item.label, subtitle: "XYZ",
                              selected: isNative(item.key)) {
                        assign(.vector(.native(item.key)))
                    }
                }
                ForEach(params.groups, id: \.name) { group in
                    GroupChip(title: group.name, subtitle: "\(group.axisCount)/3",
                              selected: isGroup(group)) {
                        assign(.vector(group.target))
                    }
                }
            }
        }

        DisclosureGroup("Split axes") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(GestureAxis.allCases, id: \.self) { axis in
                    HStack(spacing: DS.Spacing.sm) {
                        RowLabel(icon: nil, label: axis.rawValue.uppercased(), labelWidth: 40)
                        axisMenu(axis)
                    }
                    .frame(minHeight: RowMetrics.height)
                    .disabled(isNativeBound)
                }
            }
            .padding(.top, 2)
        }
        .font(.caption2)

        coreMenu
    }

    private func isNative(_ key: ParamKey) -> Bool {
        if case .native(key) = vec3Target { return true }
        return false
    }
    private func isGroup(_ group: Vec3Group) -> Bool {
        vec3Target == group.target
    }
    private var isNativeBound: Bool {
        if case .vector(.native) = binding { return true }
        return false
    }

    private func axisMenu(_ axis: GestureAxis) -> some View {
        let current = vec3Target?.key(for: axis)
        return Menu {
            Button("None") { assignAxis(nil, to: axis) }
            ScalarMenuBody(scalars: params.scalars) { key in assignAxis(key, to: axis) }
        } label: {
            MenuLabel(text: current.map { params.label(for: $0) } ?? "—")
        }
    }

    /// Assign one axis, converting a native/absent binding into a grouped one.
    private func assignAxis(_ key: ParamKey?, to axis: GestureAxis) {
        let base: Vec3Target
        if case let .grouped(x, y, z) = vec3Target {
            base = .grouped(x: x, y: y, z: z)
        } else {
            base = .grouped(x: nil, y: nil, z: nil)
        }
        let updated = base.settingKey(key, for: axis)
        if case .grouped(nil, nil, nil) = updated {
            assign(nil)
        } else {
            assign(.vector(updated))
        }
    }

    // MARK: Scalar source

    @ViewBuilder private var scalarControls: some View {
        HStack(spacing: DS.Spacing.sm) {
            RowLabel(icon: "slider.horizontal.3", label: "Param", labelWidth: 56)
            Menu {
                Button("None") { assign(nil) }
                ScalarMenuBody(scalars: params.scalars) { key in assign(.scalar(key)) }
            } label: {
                MenuLabel(text: scalarMenuLabel)
            }
        }
        .frame(minHeight: RowMetrics.height)
        coreMenu
    }

    private var scalarMenuLabel: String {
        if case let .scalar(key) = binding { return params.label(for: key) }
        return "Choose…"
    }

    // MARK: Core actions

    private var coreMenu: some View {
        HStack(spacing: DS.Spacing.sm) {
            RowLabel(icon: "bolt", label: "Action", labelWidth: 56)
            Menu {
                Button("None") { if case .core = binding { assign(nil) } }
                ForEach(CoreGestureAction.allCases, id: \.self) { action in
                    Button(action.displayName) { assign(.core(action)) }
                }
            } label: {
                MenuLabel(text: coreMenuLabel)
            }
        }
        .frame(minHeight: RowMetrics.height)
    }

    private var coreMenuLabel: String {
        if case let .core(action) = binding { return action.displayName }
        return "—"
    }

    // MARK: Write

    /// All assignments funnel here so they land in the chosen scope.
    private func assign(_ binding: GestureBinding?) {
        store.setBinding(binding, for: source, scope: writeScope)
    }
}

// MARK: - Shared menu / chip pieces

/// Scalar params as menu sections grouped by `GroupID`, in stable order.
private struct ScalarMenuBody: View {
    let scalars: [BindableParams.Item]
    let onSelect: (ParamKey) -> Void

    var body: some View {
        let sections = Dictionary(grouping: scalars, by: \.group)
            .sorted { $0.key.rawValue < $1.key.rawValue }
        ForEach(sections, id: \.key) { group, items in
            Section(group.rawValue.capitalized) {
                ForEach(items) { item in
                    Button(item.label) { onSelect(item.key) }
                }
            }
        }
    }
}

/// A one-tap group assignment chip.
private struct GroupChip: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "cube").font(.system(size: 10))
                Text(title).font(.caption).lineLimit(1)
                Text(subtitle).font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .padding(.horizontal, DS.Spacing.sm).padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? Color.accentColor.opacity(0.20)
                                        : Color.secondary.opacity(0.08))
                    .overlay(Capsule().strokeBorder(
                        selected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: selected ? 1.5 : 1)))
        }
        .buttonStyle(.plain)
    }
}

/// A wrapping row of chips (SwiftUI has no native flow layout pre-iOS16 Layout,
/// so use the Layout protocol available on all our platforms).
private struct FlowChips<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        FlowLayout(spacing: DS.Spacing.xs) { content }
    }
}

/// Minimal flow layout: left-to-right, wrapping to new rows.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalWidth = max(totalWidth, rowWidth - spacing)
                totalHeight += rowHeight + spacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth - spacing)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A menu's label chrome: current value + a disclosure affordance.
private struct MenuLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, DS.Spacing.sm).padding(.vertical, 4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.6))
    }
}

// MARK: - GestureSource display metadata

extension GestureSource {
    /// Human title for the editor header.
    public var displayName: String {
        switch self {
        case let .tapThumb(hand, finger):
            return "\(hand.displayName) \(finger.rawValue.capitalized) · Tap Thumb"
        case let .tapPalm(hand, finger):
            return "\(hand.displayName) \(finger.rawValue.capitalized) · Tap Palm"
        case let .swipe(hand): return "\(hand.displayName) · Swipe"
        case let .fist(hand): return "\(hand.displayName) · Fist"
        }
    }

    /// SF Symbol for the header.
    public var iconName: String {
        switch self {
        case .tapThumb, .tapPalm: return "hand.point.up.left"
        case .swipe: return "hand.wave"
        case .fist: return "hand.raised.fill"
        }
    }

    /// Card accent, keyed by hand so left/right read at a glance.
    var accent: Color {
        switch self {
        case let .tapThumb(hand, _), let .tapPalm(hand, _): return hand.accent
        case let .swipe(hand), let .fist(hand): return hand.accent
        }
    }
}

extension GestureHand {
    public var displayName: String { self == .left ? "Left" : "Right" }
    var accent: Color { self == .left ? .teal : .orange }
}

extension CoreGestureAction {
    public var displayName: String {
        switch self {
        case .grabZoom: return "Grab Zoom"
        case .resetView: return "Reset View"
        }
    }
}
