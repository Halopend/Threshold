// Vec3BindingEditor.swift — the custom UI element the gesture system is built
// around: assign a parameter (or a named x/y/z triple) to a single gesture
// source. It offers BOTH affordances the design calls for —
//   • bind a whole `.float3` (or an auto-detected external triple) in one pick;
//   • assign individual scalar params to x / y / z independently —
// and degrades to a single-param picker for scalar sources (palm tap, fist).
//
// It is a thin view over `BindableParams` (menu contents) and
// `GestureBindingStore` (the binding). No parameter is named in here; the same
// editor serves built-in and external scenes.

import SwiftUI
import ThresholdCore

// MARK: - Vec3BindingEditor

public struct Vec3BindingEditor: View {
    let source: GestureSource
    /// Fractal identity (`deKey`) — the per-fractal storage key.
    let fractal: String
    let params: BindableParams
    let store: GestureBindingStore

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

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader(source.displayName, icon: source.iconName) {
                if binding != nil {
                    Button("Clear") { store.setBinding(nil, for: source, fractal: fractal) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            summaryLine

            switch source.arity {
            case .vector: vectorControls
            case .scalar: scalarControls
            }
        }
        .moduleCard(source.accent)
    }

    // MARK: Summary

    @ViewBuilder private var summaryLine: some View {
        Text(summaryText)
            .font(.caption2)
            .foregroundStyle(binding == nil ? .tertiary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summaryText: String {
        switch binding {
        case nil:
            return "Unassigned"
        case let .vector(.native(key)):
            return "→ \(params.label(for: key)) · whole X/Y/Z"
        case let .vector(.grouped(x, y, z)):
            let parts = [("X", x), ("Y", y), ("Z", z)].compactMap { tag, key in
                key.map { "\(tag): \(params.label(for: $0))" }
            }
            return parts.isEmpty ? "No axes assigned" : parts.joined(separator: "  ·  ")
        case let .scalar(key):
            return "→ \(params.label(for: key))"
        case let .core(action):
            return "→ \(action.displayName)"
        }
    }

    // MARK: Vector source controls

    @ViewBuilder private var vectorControls: some View {
        // "Bind whole" — native float3 params and auto-detected external triples.
        if !params.vectors.isEmpty || !params.groups.isEmpty {
            HStack(spacing: DS.Spacing.sm) {
                RowLabel(icon: "cube", label: "Grouped", labelWidth: 56)
                wholeMenu
            }
            .frame(minHeight: RowMetrics.height)
        }

        // Per-axis assignment.
        ForEach(GestureAxis.allCases, id: \.self) { axis in
            HStack(spacing: DS.Spacing.sm) {
                RowLabel(icon: nil, label: axis.rawValue.uppercased(), labelWidth: 56)
                axisMenu(axis)
            }
            .frame(minHeight: RowMetrics.height)
            .disabled(isNativeBound)   // a whole float3 owns all axes
        }

        coreMenu
    }

    /// True when a native `.float3` claims all three axes (per-axis is moot).
    private var isNativeBound: Bool {
        if case .vector(.native) = binding { return true }
        return false
    }

    private var wholeMenu: some View {
        Menu {
            Button("None") { store.setBinding(nil, for: source, fractal: fractal) }
            if !params.vectors.isEmpty {
                Section("Vector params") {
                    ForEach(params.vectors) { item in
                        Button(item.label) {
                            store.setBinding(.vector(.native(item.key)),
                                             for: source, fractal: fractal)
                        }
                    }
                }
            }
            if !params.groups.isEmpty {
                Section("Detected X/Y/Z groups") {
                    ForEach(params.groups, id: \.name) { group in
                        Button("\(group.name) (\(group.axisCount)/3)") {
                            store.setBinding(.vector(group.target),
                                             for: source, fractal: fractal)
                        }
                    }
                }
            }
        } label: { MenuLabel(text: wholeMenuLabel) }
    }

    private var wholeMenuLabel: String {
        switch binding {
        case let .vector(.native(key)): return params.label(for: key)
        default: return "Choose…"
        }
    }

    private func axisMenu(_ axis: GestureAxis) -> some View {
        let current = vec3Target?.key(for: axis)
        return Menu {
            Button("None") { assign(nil, to: axis) }
            ScalarMenuBody(scalars: params.scalars) { key in assign(key, to: axis) }
        } label: {
            MenuLabel(text: current.map { params.label(for: $0) } ?? "—")
        }
    }

    /// Assign one axis, converting a native/absent binding into a grouped one.
    private func assign(_ key: ParamKey?, to axis: GestureAxis) {
        let base: Vec3Target
        if case let .grouped(x, y, z) = vec3Target {
            base = .grouped(x: x, y: y, z: z)
        } else {
            base = .grouped(x: nil, y: nil, z: nil)   // native or unbound → fresh
        }
        let updated = base.settingKey(key, for: axis)
        // An all-nil grouped target is just "unbound".
        if case .grouped(nil, nil, nil) = updated {
            store.setBinding(nil, for: source, fractal: fractal)
        } else {
            store.setBinding(.vector(updated), for: source, fractal: fractal)
        }
    }

    // MARK: Scalar source controls

    @ViewBuilder private var scalarControls: some View {
        HStack(spacing: DS.Spacing.sm) {
            RowLabel(icon: "slider.horizontal.3", label: "Param", labelWidth: 56)
            Menu {
                Button("None") { store.setBinding(nil, for: source, fractal: fractal) }
                ScalarMenuBody(scalars: params.scalars) { key in
                    store.setBinding(.scalar(key), for: source, fractal: fractal)
                }
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

    // MARK: Core actions (both arities)

    private var coreMenu: some View {
        HStack(spacing: DS.Spacing.sm) {
            RowLabel(icon: "bolt", label: "Action", labelWidth: 56)
            Menu {
                Button("None") {
                    if case .core = binding { store.setBinding(nil, for: source, fractal: fractal) }
                }
                ForEach(CoreGestureAction.allCases, id: \.self) { action in
                    Button(action.displayName) {
                        store.setBinding(.core(action), for: source, fractal: fractal)
                    }
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
}

// MARK: - Shared menu pieces

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
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
