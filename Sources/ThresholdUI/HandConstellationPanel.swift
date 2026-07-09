// HandConstellationPanel.swift — the gesture assignment hero, ported from the
// legacy "Constellation Hands" and extended for the rebuild's larger gesture
// vocabulary.
//
// Two mirrored HandShape silhouettes face a center channel. Each hand carries:
//   • four fingertip orbs   → `.tapThumb` sources (a pinched finger's 3D drag);
//   • four palm drop-points → `.tapPalm` sources (finger-to-palm touch);
//   • swipe + fist chips     → `.swipe` / `.fist` sources.
// Fingertip orbs use the legacy direct-assignment menu: bind whole XYZ groups
// or claim X/Y/Z axes without leaving the hand diagram. Palm/fist/swipe still
// use the richer editor, because those sources do not need per-axis claiming.
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
    @State private var showingAdvancedEditor = false

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
            assignmentsSummary
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
            Text("Tap a fingertip to assign X/Y/Z directly. Tap a palm point or hand action to edit below.")
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

    @ViewBuilder
    private func orb(_ source: GestureSource, at center: CGPoint, diameter: CGFloat) -> some View {
        if case let .tapThumb(hand, finger) = source {
            tapThumbMenu(hand: hand, finger: finger)
                .position(center)
        } else {
            selectorOrb(source, at: center, diameter: diameter)
        }
    }

    private func selectorOrb(_ source: GestureSource, at center: CGPoint, diameter: CGFloat) -> some View {
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

    private func tapThumbMenu(hand: GestureHand, finger: GestureFinger) -> some View {
        let source = GestureSource.tapThumb(hand: hand, finger: finger)
        let binding = store.binding(for: source, fractal: fractal)
        let count = axisClaimCount(binding)
        let icon = tapThumbIcon(binding)
        return Menu {
            if !params.vectors.isEmpty || !params.groups.isEmpty {
                Section("Whole X/Y/Z") {
                    ForEach(params.vectors) { item in
                        Button {
                            assign(.vector(.native(item.key)), to: source)
                        } label: {
                            Label(item.label, systemImage: isVectorNative(binding, item.key) ? "checkmark" : "cube")
                        }
                    }
                    ForEach(params.groups, id: \.name) { group in
                        Button {
                            assign(.vector(group.target), to: source)
                        } label: {
                            Label(group.name, systemImage: isVectorGroup(binding, group) ? "checkmark" : "cube")
                        }
                    }
                }
            }

            Section("Single-axis dials") {
                ForEach(params.scalars) { item in
                    Menu {
                        axisClaimButton(source: source, item: item, axis: .x)
                        axisClaimButton(source: source, item: item, axis: .y)
                        axisClaimButton(source: source, item: item, axis: .z)
                    } label: {
                        Label(item.label, systemImage: "slider.horizontal.3")
                    }
                }
            }

            Section("Action") {
                ForEach(CoreGestureAction.allCases, id: \.self) { action in
                    Button {
                        assign(.core(action), to: source)
                    } label: {
                        Label(action.displayName, systemImage: isCore(binding, action) ? "checkmark" : "bolt")
                    }
                }
            }

            if binding != nil {
                Divider()
                Button("Clear Finger", role: .destructive) { assign(nil, to: source) }
            }
            Divider()
            Button("Open Advanced Editor") {
                selected = source
                showingAdvancedEditor = true
            }
        } label: {
            ZStack {
                Circle()
                    .fill(binding == nil ? Color.secondary.opacity(0.08) : source.accent.opacity(0.20))
                    .overlay(Circle().strokeBorder(
                        binding == nil ? Color.secondary.opacity(0.4) : source.accent.opacity(0.75),
                        lineWidth: binding == nil ? 1 : 1.6))
                    .frame(width: HandStage.orbDiameter, height: HandStage.orbDiameter)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(binding == nil ? Color.secondary : source.accent)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(source.accent)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(.background)
                            .overlay(Circle().strokeBorder(source.accent.opacity(0.55), lineWidth: 1)))
                        .offset(x: HandStage.orbDiameter / 2 - 3, y: HandStage.orbDiameter / 2 - 3)
                }
            }
            .frame(width: max(HandStage.orbDiameter, 44), height: max(HandStage.orbDiameter, 44))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Editor

    @ViewBuilder private var editorOrHint: some View {
        if let selected, showingAdvancedEditor || selected.arity == .scalar {
            Vec3BindingEditor(source: selected, fractal: fractal, params: params, store: store)
                .id(selected)   // rebuild cleanly when the selection changes
        } else {
            Text("Fingertips assign directly from the diagram. Select a palm point or hand action for detailed settings.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .moduleCard(.gray)
        }
    }

    // MARK: Legacy-style direct assignment

    private func axisClaimButton(
        source: GestureSource, item: BindableParams.Item, axis: GestureAxis
    ) -> some View {
        let current = store.binding(for: source, fractal: fractal)
        let isCurrent = isScalarAxis(current, item.key, axis)
        return Button {
            if isCurrent {
                assignAxis(nil, axis: axis, source: source)
            } else {
                assignAxis(item.key, axis: axis, source: source)
            }
        } label: {
            Label(
                isCurrent ? "Remove \(axisLabel(axis))" : "Claim \(axisLabel(axis))",
                systemImage: isCurrent ? "checkmark" : axisIcon(axis))
        }
    }

    private func assign(_ binding: GestureBinding?, to source: GestureSource) {
        store.setBinding(binding, for: source, fractal: fractal)
        selected = source
        showingAdvancedEditor = false
    }

    private func assignAxis(_ key: ParamKey?, axis: GestureAxis, source: GestureSource) {
        let current = store.binding(for: source, fractal: fractal)
        var grouped = axisTarget(from: current)
        grouped[axis] = key
        let target = Vec3Target.grouped(x: grouped[.x], y: grouped[.y], z: grouped[.z])
        if case .grouped(nil, nil, nil) = target {
            assign(nil, to: source)
        } else {
            assign(.vector(target), to: source)
        }
    }

    private func axisTarget(from binding: GestureBinding?) -> [GestureAxis: ParamKey] {
        guard case let .vector(.grouped(x, y, z)) = binding else { return [:] }
        var out: [GestureAxis: ParamKey] = [:]
        if let x { out[.x] = x }
        if let y { out[.y] = y }
        if let z { out[.z] = z }
        return out
    }

    private func isScalarAxis(_ binding: GestureBinding?, _ key: ParamKey, _ axis: GestureAxis) -> Bool {
        if case let .vector(.grouped(x, y, z)) = binding {
            switch axis {
            case .x: return x == key
            case .y: return y == key
            case .z: return z == key
            }
        }
        if case let .scalarAxis(k, a) = binding { return k == key && a == axis }
        return false
    }

    private func isVectorNative(_ binding: GestureBinding?, _ key: ParamKey) -> Bool {
        if case let .vector(.native(current)) = binding { return current == key }
        return false
    }

    private func isVectorGroup(_ binding: GestureBinding?, _ group: Vec3Group) -> Bool {
        if case let .vector(target) = binding { return target == group.target }
        return false
    }

    private func isCore(_ binding: GestureBinding?, _ action: CoreGestureAction) -> Bool {
        if case let .core(current) = binding { return current == action }
        return false
    }

    private func axisClaimCount(_ binding: GestureBinding?) -> Int {
        switch binding {
        case .vector(.native): return 3
        case let .vector(.grouped(x, y, z)): return [x, y, z].compactMap { $0 }.count
        case .scalar, .scalarAxis, .core: return 1
        case nil: return 0
        }
    }

    private func tapThumbIcon(_ binding: GestureBinding?) -> String {
        switch binding {
        case .vector(.native), .vector(.grouped): return "move.3d"
        case .scalar, .scalarAxis: return "slider.horizontal.3"
        case .core(.grabZoom): return "hand.pinch"
        case .core(.resetView): return "arrow.counterclockwise"
        case nil: return "plus"
        }
    }

    private func axisLabel(_ axis: GestureAxis) -> String {
        switch axis {
        case .x: return "X / Horizontal"
        case .y: return "Y / Vertical"
        case .z: return "Z / Depth"
        }
    }

    private func axisIcon(_ axis: GestureAxis) -> String {
        switch axis {
        case .x: return "arrow.left.and.right"
        case .y: return "arrow.up.and.down"
        case .z: return "arrow.up.left.and.arrow.down.right"
        }
    }

    // MARK: Summary

    private var assignmentsSummary: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            SectionHeader("Assigned", icon: "list.bullet.rectangle")
            let sources = assignedSources
            if sources.isEmpty {
                Text("No hand assignments yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(sources, id: \.self) { source in
                    if let binding = store.binding(for: source, fractal: fractal) {
                        assignmentRow(source: source, binding: binding)
                    }
                }
            }
        }
        .moduleCard(.gray)
    }

    private var assignedSources: [GestureSource] {
        var out: [GestureSource] = []
        for hand in [GestureHand.left, .right] {
            for finger in fingers {
                let source = GestureSource.tapThumb(hand: hand, finger: finger)
                if store.binding(for: source, fractal: fractal) != nil { out.append(source) }
                let palm = GestureSource.tapPalm(hand: hand, finger: finger)
                if store.binding(for: palm, fractal: fractal) != nil { out.append(palm) }
            }
            for source in [GestureSource.swipe(hand: hand), .fist(hand: hand)] {
                if store.binding(for: source, fractal: fractal) != nil { out.append(source) }
            }
        }
        return out
    }

    private func assignmentRow(source: GestureSource, binding: GestureBinding) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: source.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(source.accent)
                .frame(width: 18)
            Text(shortName(source))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 94, alignment: .leading)
            Text(bindingSummary(binding))
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(source.accent.opacity(0.08)))
    }

    private func shortName(_ source: GestureSource) -> String {
        switch source {
        case let .tapThumb(hand, finger): return "\(hand.displayName) \(finger.rawValue)"
        case let .tapPalm(hand, finger): return "\(hand.displayName) \(finger.rawValue) palm"
        case let .swipe(hand): return "\(hand.displayName) swipe"
        case let .fist(hand): return "\(hand.displayName) fist"
        }
    }

    private func bindingSummary(_ binding: GestureBinding) -> String {
        switch binding {
        case let .vector(.native(key)): return "XYZ -> \(params.label(for: key))"
        case let .vector(.grouped(x, y, z)):
            let parts = [("X", x), ("Y", y), ("Z", z)].compactMap { label, key in
                key.map { "\(label): \(params.label(for: $0))" }
            }
            return parts.joined(separator: "  ")
        case let .scalar(key): return "Magnitude -> \(params.label(for: key))"
        case let .scalarAxis(key, axis): return "\(axis.rawValue.uppercased()) -> \(params.label(for: key))"
        case let .core(action): return action.displayName
        }
    }
}
