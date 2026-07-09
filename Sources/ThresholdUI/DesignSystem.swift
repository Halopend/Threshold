// DesignSystem.swift — spacing / corner-radius tokens and the shared card
// chrome, ported from the legacy app's DesignSystem + ModuleSectionView
// (Polinate/TEMP/MetalRaymarch-main). The tokens mirror the dominant numeric
// literals of that UI so panels read the same without a redesign.

import SwiftUI

/// Namespaced design tokens. Use `DS.Spacing.md`, `DS.Radius.card`, etc.
public enum DS {

    // MARK: - Spacing

    /// Layout spacing scale (points).
    public enum Spacing {
        /// 4 pt — hairline gaps between tightly-coupled elements.
        public static let xxs: CGFloat = 4
        /// 6 pt — compact control padding.
        public static let xs: CGFloat = 6
        /// 8 pt — small padding / inter-item spacing.
        public static let sm: CGFloat = 8
        /// 10 pt — the most common panel/row padding.
        public static let md: CGFloat = 10
        /// 12 pt — section padding.
        public static let lg: CGFloat = 12
        /// 16 pt — large container padding.
        public static let xl: CGFloat = 16
        /// 20 pt — page-level padding.
        public static let xxl: CGFloat = 20
    }

    // MARK: - Corner Radius

    /// Corner-radius scale (points).
    public enum Radius {
        /// 4 pt — chips / tiny tags.
        public static let xs: CGFloat = 4
        /// 6 pt — small controls.
        public static let sm: CGFloat = 6
        /// 8 pt — inset rows.
        public static let inset: CGFloat = 8
        /// 10 pt — standard control/row radius.
        public static let control: CGFloat = 10
        /// 12 pt — standard card/section radius.
        public static let card: CGFloat = 12
        /// 16 pt — large panels.
        public static let panel: CGFloat = 16
        /// 20 pt — prominent containers / sheets.
        public static let prominent: CGFloat = 20
    }

    // MARK: - Glass surfaces

    public enum Surface {
        /// Main floating control surface: the legacy dark glass plate.
        public static let panelDark = Color.black.opacity(0.78)
        public static let panelLight = Color.white.opacity(0.72)
        public static let strokeDark = Color.white.opacity(0.10)
        public static let strokeLight = Color.black.opacity(0.12)
        /// Content cards sit slightly above the panel, with accent color in
        /// the edge and a dark liquid-glass fill underneath.
        public static let cardDark = Color.black.opacity(0.34)
        public static let cardLight = Color.white.opacity(0.30)
        public static let innerStrokeDark = Color.white.opacity(0.07)
        public static let innerStrokeLight = Color.black.opacity(0.08)
    }
}

// MARK: - Panel text size (Dynamic Type)

extension DS {
    /// AppStorage key backing the "Text Size" slider in Settings ▸ Display.
    /// Stores an index into `textSizeSteps`.
    public static let textSizeStorageKey = "threshold.ui.textSizeIndex"

    /// Curated Dynamic Type steps for the control panel, from the system
    /// default upward. Larger steps make the TEXT bigger (crisp, reflowed)
    /// without scaling icons or chrome; capped below the largest
    /// accessibility sizes so the dense panels keep their layout.
    public static let textSizeSteps: [DynamicTypeSize] = [
        .large,          // system default — no change
        .xLarge,
        .xxLarge,
        .xxxLarge,
        .accessibility1,
        .accessibility2,
    ]

    /// Default step index. One notch up on visionOS so panel text reads
    /// comfortably at headset distance; system default on Mac/iPad.
    public static var defaultTextSizeIndex: Int {
        #if os(visionOS)
        return 1
        #else
        return 0
        #endif
    }

    /// The Dynamic Type size for a stored index (clamped to the valid range).
    public static func textSize(forIndex index: Int) -> DynamicTypeSize {
        textSizeSteps[min(max(index, 0), textSizeSteps.count - 1)]
    }

    /// Friendly label for a stored index, shown next to the slider.
    public static func textSizeLabel(forIndex index: Int) -> String {
        switch textSize(forIndex: index) {
        case .large: return "Default"
        case .xLarge: return "Large"
        case .xxLarge: return "Larger"
        case .xxxLarge: return "Largest"
        case .accessibility1: return "XL"
        case .accessibility2: return "XXL"
        default: return "Custom"
        }
    }
}

// MARK: - Module card chrome

extension View {
    /// Floating dark glass panel used by the control sidebar and top chrome.
    public func panelGlass(cornerRadius: CGFloat = DS.Radius.prominent) -> some View {
        modifier(PanelGlassModifier(cornerRadius: cornerRadius))
    }

    /// The shared "module card" chrome: padded rounded rect tinted by an
    /// accent. One box per section — the wrapper the legacy control tabs
    /// used for every titled group of controls.
    public func moduleCard(_ accent: Color, opacity: Double = 0.06) -> some View {
        modifier(ModuleCardModifier(accent: accent, opacity: opacity))
    }
}

private struct PanelGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(
                shape.fill(colorScheme == .dark ? DS.Surface.panelDark : DS.Surface.panelLight))
            .overlay(
                shape.strokeBorder(
                    colorScheme == .dark ? DS.Surface.strokeDark : DS.Surface.strokeLight,
                    lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10),
                    radius: 18, x: 0, y: 10)
    }
}

private struct ModuleCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let accent: Color
    let opacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        content
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: shape)
            .background(shape.fill(colorScheme == .dark ? DS.Surface.cardDark : DS.Surface.cardLight))
            .overlay(
                shape.strokeBorder(accent.opacity(opacity + 0.18), lineWidth: 0.8))
            .overlay(
                shape.strokeBorder(
                    colorScheme == .dark ? DS.Surface.innerStrokeDark : DS.Surface.innerStrokeLight,
                    lineWidth: 0.5))
            .shadow(color: accent.opacity(colorScheme == .dark ? 0.10 : 0.05),
                    radius: 10, x: 0, y: 4)
    }
}

// MARK: - SectionHeader

/// Card header: icon + title, with an optional trailing accessory slot
/// (reset button, enable toggle, badge).
public struct SectionHeader<Accessory: View>: View {
    let title: String
    let icon: String
    let accessory: Accessory

    public init(
        _ title: String, icon: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.accessory = accessory()
    }

    public var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.headline)
            Spacer()
            accessory
        }
    }
}
