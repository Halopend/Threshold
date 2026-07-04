// HandConstellationPanel.swift — the gesture assignment hero, ported from the
// legacy "Constellation Hands" and extended for the rebuild's larger gesture
// vocabulary.
//
// Two mirrored HandShape silhouettes face a center channel. Each hand carries:
//   • four fingertip orbs   → `.tapThumb` sources (a pinched finger's 3D drag);
//   • four palm drop-points → `.tapPalm` sources (finger-to-palm touch);
//   • swipe + fist chips     → `.swipe` / `.fist` sources.
// Tapping any of these SELECTS it; the `Vec3BindingEditor` for the selection
// renders below, so one editor serves every source (the legacy per-orb Menu is
// replaced by the richer editor the rebuild needs for xyz grouping).
//
// Purely a selector + host: it derives nothing and owns no binding state — it
// reads `BindableParams` and drives `GestureBindingStore`.

import SwiftUI
import ThresholdCore

// MARK: - Layout

private enum HandStage {
    /// HandSilhouette viewBox 1000×729 (fingers → +x).
    static let handAspect: CGFloat = 1000.0 / 729.0
    static let stageHeight: CGFloat = 340
    /// Center gap kept clear so the two hands never overlap the channel.
    static let channelMin: CGFloat = 200
    static let handWidthCap: CGFloat = 420
    static let orbDiameter: CGFloat = 34
    static let palmDiameter: CGFloat = 22

    /// Fingertip anchors (UnitPoint in the un-mirrored right hand). Index/middle
    /// /ring inherited from the legacy art; pinky estimated on the same viewBox.
    static let tipAnchors: [GestureFinger: CGPoint] = [
        .index:  CGPoint(x: 0.93,  y: 0.25),
        .middle: CGPoint(x: 0.965, y: 0.44),
        .ring:   CGPoint(x: 0.93,  y: 0.69),
        .pinky:  CGPoint(x: 0.85,  y: 0.87),
    ]
    /// Palm drop-points, one under each finger (estimated; tune to taste).
    static let palmAnchors: [GestureFinger: CGPoint] = [
        .index:  CGPoint(x: 0.52, y: 0.31),
        .middle: CGPoint(x: 0.55, y: 0.46),
        .ring:   CGPoint(x: 0.52, y: 0.61),
        .pinky:  CGPoint(x: 0.46, y: 0.73),
    ]

    static func handWidth(_ W: CGFloat) -> CGFloat {
        max(120, min((W - channelMin) / 2, handWidthCap, (stageHeight - 24) * handAspect))
    }
    static func handCenterX(_ hand: GestureHand, _ W: CGFloat) -> CGFloat {
        let hw = handWidth(W)
        return hand == .left ? hw / 2 : W - hw / 2
    }
    /// Map an anchor into stage coordinates, accounting for the right hand's
    /// horizontal mirror (its fingers point back toward the channel).
    static func point(_ hand: GestureHand, _ anchor: CGPoint, _ W: CGFloat) -> CGPoint {
        let hw = handWidth(W)
        let hh = hw / handAspect
        let top = stageHeight / 2 - hh / 2
        let x = hand == .left ? anchor.x * hw : (W - hw) + (1 - anchor.x) * hw
        return CGPoint(x: x, y: top + anchor.y * hh)
    }
}

// MARK: - Panel

public struct HandConstellationPanel: View {
    let params: BindableParams
    /// Fractal identity (`deKey`) — the per-fractal storage key.
    let fractal: String
    let store: GestureBindingStore

    @State private var selected: GestureSource?
    @State private var showingSavePreset = false
    @State private var newPresetName = ""

    public init(params: BindableParams, fractal: String, store: GestureBindingStore) {
        self.params = params
        self.fractal = fractal
        self.store = store
    }

    private let fingers = GestureFinger.allCases

    public var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            presetBar
            stageCard
            editorOrHint
        }
        .alert("Save gesture preset", isPresented: $showingSavePreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") {
                store.saveCurrentAsPreset(named: newPresetName)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Captures every gesture binding — global and per-fractal.")
        }
    }

    // MARK: Presets

    private var presetBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Label("Gesture Presets", systemImage: "hand.point.up.left")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                if store.presets.isEmpty {
                    Text("No presets saved")
                } else {
                    Section("Apply") {
                        ForEach(store.presets) { preset in
                            Button(preset.name) { store.applyPreset(named: preset.name) }
                        }
                    }
                    Menu("Delete") {
                        ForEach(store.presets) { preset in
                            Button(preset.name, role: .destructive) {
                                store.deletePreset(named: preset.name)
                            }
                        }
                    }
                }
                Divider()
                Button("Save Current…", systemImage: "plus") { showingSavePreset = true }
            } label: {
                Label("Presets", systemImage: "tray.full")
                    .font(.caption)
            }
        }
        .padding(.horizontal, DS.Spacing.xs)
    }

    // MARK: Stage

    private var stageCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Hand Assignments", icon: "hand.point.up.left")

            GeometryReader { geo in
                let W = geo.size.width
                ZStack {
                    hand(.left, W)
                    hand(.right, W)
                    handLabel("LEFT", .left, W)
                    handLabel("RIGHT", .right, W)

                    ForEach([GestureHand.left, .right], id: \.self) { hand in
                        ForEach(fingers, id: \.self) { finger in
                            orb(.tapThumb(hand: hand, finger: finger),
                                at: HandStage.point(hand, HandStage.tipAnchors[finger]!, W),
                                diameter: HandStage.orbDiameter)
                            orb(.tapPalm(hand: hand, finger: finger),
                                at: HandStage.point(hand, HandStage.palmAnchors[finger]!, W),
                                diameter: HandStage.palmDiameter)
                        }
                    }
                }
            }
            .frame(height: HandStage.stageHeight)

            handActionChips
            Text("Tap a fingertip (pinch-drag → X/Y/Z), a palm point (finger→palm), "
                 + "or a hand action to assign it.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .moduleCard(.blue)
    }

    @ViewBuilder private func hand(_ hand: GestureHand, _ W: CGFloat) -> some View {
        let hw = HandStage.handWidth(W)
        let hh = hw / HandStage.handAspect
        HandShape()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: hw, height: hh)
            .scaleEffect(x: hand == .left ? 1 : -1, y: 1)
            .position(x: HandStage.handCenterX(hand, W), y: HandStage.stageHeight / 2)
            .allowsHitTesting(false)
    }

    private func handLabel(_ text: String, _ hand: GestureHand, _ W: CGFloat) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold)).tracking(1.5)
            .foregroundStyle(.secondary)
            .position(x: HandStage.handCenterX(hand, W), y: 8)
    }

    // MARK: Swipe / fist chips

    private var handActionChips: some View {
        HStack {
            actionChipGroup(.left)
            Spacer(minLength: DS.Spacing.md)
            actionChipGroup(.right)
        }
    }

    private func actionChipGroup(_ hand: GestureHand) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(hand.displayName.uppercased())
                .font(.system(size: 9, weight: .bold)).tracking(1)
                .foregroundStyle(.secondary)
            actionChip(.swipe(hand: hand), title: "Swipe", icon: "hand.wave")
            actionChip(.fist(hand: hand), title: "Fist", icon: "hand.raised.fill")
        }
    }

    private func actionChip(_ source: GestureSource, title: String, icon: String) -> some View {
        let bound = store.binding(for: source, fractal: fractal) != nil
        let isSelected = selected == source
        return Button { selected = source } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(bound ? source.accent : Color.secondary)
            .background(
                Capsule().fill(bound ? source.accent.opacity(0.14) : Color.secondary.opacity(0.06))
                    .overlay(Capsule().strokeBorder(
                        isSelected ? source.accent : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Orb / palm point

    private func orb(_ source: GestureSource, at center: CGPoint, diameter: CGFloat) -> some View {
        let bound = store.binding(for: source, fractal: fractal) != nil
        let isSelected = selected == source
        return Button { selected = source } label: {
            ZStack {
                Circle()
                    .fill(bound ? source.accent.opacity(0.20) : Color.secondary.opacity(0.08))
                    .overlay(Circle().strokeBorder(
                        isSelected ? source.accent
                            : (bound ? source.accent.opacity(0.7) : Color.secondary.opacity(0.4)),
                        lineWidth: isSelected ? 2.5 : (bound ? 1.6 : 1)))
                    .frame(width: diameter, height: diameter)
                if bound {
                    Image(systemName: "checkmark")
                        .font(.system(size: diameter * 0.4, weight: .bold))
                        .foregroundStyle(source.accent)
                }
            }
            .frame(width: max(diameter, 44), height: max(diameter, 44))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .position(center)
    }

    // MARK: Editor

    @ViewBuilder private var editorOrHint: some View {
        if let selected {
            Vec3BindingEditor(source: selected, fractal: fractal, params: params, store: store)
                .id(selected)   // rebuild cleanly when the selection changes
        } else {
            Text("Select a fingertip, palm point, or hand action above to assign a parameter.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .moduleCard(.gray)
        }
    }
}
