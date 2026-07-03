// Components.swift — reusable presentation components ported from the legacy
// app's control-panel vocabulary (EffectSliderRow, StatBox, tab chips,
// gradient preview). Presentation only: nothing here knows the mirror or the
// catalog — these are the pieces the catalog-bound rows are built from.

import SwiftUI
import ThresholdCore

// MARK: - TabStrip

/// A horizontal strip of icon-over-label tab chips (the legacy top-dock
/// pattern). Generic over the selection value so panels and sub-tabs can
/// reuse it.
public struct TabStrip<T: Hashable>: View {
    public struct Item {
        public let value: T
        public let label: String
        public let icon: String

        public init(_ value: T, label: String, icon: String) {
            self.value = value
            self.label = label
            self.icon = icon
        }
    }

    let items: [Item]
    /// Compact sub-tab styling: icon inline with the label on one line, less
    /// vertical padding — the second-level strip under the primary tabs.
    let compact: Bool
    @SwiftUI.Binding var selection: T

    public init(
        items: [Item], selection: SwiftUI.Binding<T>, compact: Bool = false
    ) {
        self.items = items
        self.compact = compact
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    chipLabel(item)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.inset)
                        .fill(selected ? Color.accentColor.opacity(0.12) : .clear))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func chipLabel(_ item: Item) -> some View {
        if compact {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: item.icon)
                    .font(.caption2)
                Text(item.label)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.xxs)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.inset))
        } else {
            VStack(spacing: 2) {
                Image(systemName: item.icon)
                    .font(.body)
                Text(item.label)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.inset))
        }
    }
}

// MARK: - StatBox

/// Compact stat tile: value (mono, colored) over a caption label.
public struct StatBox: View {
    let label: String
    let value: String
    let color: Color

    public init(label: String, value: String, color: Color) {
        self.label = label
        self.value = value
        self.color = color
    }

    public var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.sm)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.Radius.inset))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - EffectSliderRow

/// Single-line control row: icon + fixed-width label | slider | trailing
/// slot (live value, on/off switch, or nothing). The workhorse row of the
/// legacy effect panels. Value binding is LINEAR in `range` — catalog rows
/// with a response curve go through `FloatSlotRow` instead, which shares
/// this row's geometry.
public struct EffectSliderRow: View {
    public enum Trailing {
        /// Formatted live value text.
        case value
        /// An enable switch; the slider dims when off.
        case toggle(SwiftUI.Binding<Bool>)
        /// Fixed-width empty slot (keeps columns aligned).
        case none
    }

    let icon: String?
    let label: String
    @SwiftUI.Binding var value: Double
    let range: ClosedRange<Double>
    let trailing: Trailing
    let onEditingChanged: (Bool) -> Void

    public init(
        icon: String? = nil,
        label: String,
        value: SwiftUI.Binding<Double>,
        in range: ClosedRange<Double>,
        trailing: Trailing = .value,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.icon = icon
        self.label = label
        self._value = value
        self.range = range
        self.trailing = trailing
        self.onEditingChanged = onEditingChanged
    }

    private var enabled: Bool {
        if case .toggle(let binding) = trailing { return binding.wrappedValue }
        return true
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            RowLabel(icon: icon, label: label, enabled: enabled)
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .disabled(!enabled)
            switch trailing {
            case .value:
                RowValueText(text: ValueFormatting.format(Float(value)))
            case .toggle(let binding):
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .frame(width: RowMetrics.trailingWidth, alignment: .trailing)
            case .none:
                Spacer().frame(width: RowMetrics.trailingWidth)
            }
        }
        .frame(minHeight: RowMetrics.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(ValueFormatting.format(Float(value)))
    }
}

/// Shared geometry for slider rows so catalog rows and ad-hoc rows align.
enum RowMetrics {
    static let iconWidth: CGFloat = 16
    static let labelWidth: CGFloat = 104
    static let trailingWidth: CGFloat = 48
    static let height: CGFloat = 28
}

/// The icon + fixed-width label leading cell of a slider row.
struct RowLabel: View {
    let icon: String?
    let label: String
    var enabled: Bool = true
    var labelWidth: CGFloat = RowMetrics.labelWidth

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: RowMetrics.iconWidth)
            }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: labelWidth, alignment: .leading)
        }
    }
}

/// The trailing live-value cell of a slider row.
struct RowValueText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: RowMetrics.trailingWidth, alignment: .trailing)
    }
}

// MARK: - GradientPreviewBar

/// A rounded gradient swatch for a `Palette` — the preview bar of the palette
/// editor and the face of every preset card.
public struct GradientPreviewBar: View {
    let palette: Palette
    let height: CGFloat

    public init(palette: Palette, height: CGFloat = 22) {
        self.palette = palette
        self.height = height
    }

    /// SwiftUI colors from the LINEAR stop rgb (correct-space preview).
    static func color(_ s: GradientStop) -> Color {
        Color(.sRGBLinear, red: Double(s.red), green: Double(s.green), blue: Double(s.blue))
    }

    public var body: some View {
        let stops = palette.stops.map { s in
            Gradient.Stop(color: Self.color(s), location: Double(s.position))
        }
        RoundedRectangle(cornerRadius: DS.Radius.xs)
            .fill(LinearGradient(
                gradient: Gradient(stops: stops.isEmpty
                    ? [Gradient.Stop(color: .gray, location: 0)] : stops),
                startPoint: .leading, endPoint: .trailing))
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs).strokeBorder(.separator))
    }
}

// MARK: - Display icons

/// SF Symbol names for renderer concepts the catalog does not describe.
/// Purely decorative — a missing key falls back to a generic symbol.
public enum DisplayIcons {
    /// Icon for a built-in DE key (fractal switcher grid).
    public static func fractal(_ deKey: String) -> String {
        switch deKey {
        case "mandelbox": return "cube.fill"
        case "mandelbulb": return "globe"
        case "kleinian": return "circle.grid.cross.fill"
        case "menger": return "square.grid.3x3.fill"
        case "quaternionJulia": return "atom"
        case "mandelbulbJulia": return "moon.stars.fill"
        default: return "cube.transparent"
        }
    }

    /// Icon for a warp-menu family name (add menu + op rows).
    public static func warpFamily(_ name: String) -> String {
        switch name {
        case "Bend & Wave": return "water.waves"
        case "Mirrors & Folds": return "square.on.square"
        case "Spherical & Radial": return "circle.circle"
        case "Self-Similar Repeats": return "square.grid.3x3"
        case "Space Projection": return "globe"
        case "Hand & Distance": return "hand.raised"
        default: return "square.stack.3d.up"
        }
    }

    /// Icon for well-known engine parameter keys (per-row icons in the
    /// hand-arranged cards). Unknown keys get a neutral slider glyph.
    public static func param(_ key: ParamKey) -> String {
        switch key {
        case .colorGradientRepeat: return "repeat"
        case .colorGradientOffset: return "arrow.left.and.right"
        case .colorGradientSmoothing: return "wand.and.rays"
        case .colorSaturation: return "drop.fill"
        case .colorContrast: return "circle.lefthalf.filled"
        case .colorVibrance: return "sparkles"
        case .colorBrightness: return "sun.max"
        case .colorGamma: return "function"
        case .colorTonemap: return "camera.filters"
        case .scaleZoomSpeed: return "plus.magnifyingglass"
        case .scaleZoom: return "magnifyingglass"
        case .cameraOrbitYaw: return "arrow.triangle.2.circlepath"
        case .cameraOrbitPitch: return "arrow.up.and.down"
        case .cameraDolly: return "move.3d"
        default: return "slider.horizontal.3"
        }
    }
}
