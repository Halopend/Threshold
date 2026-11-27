// PostProcessPanel.swift — ordered full-frame filter stack editor.

import SwiftUI
import ThresholdCore

// MARK: - Display metadata

extension PostProcessKind {
    var uiName: String {
        switch self {
        case .bloom: return "Bloom"
        case .gaussianBlur: return "Gaussian Blur"
        case .sharpen: return "Sharpen"
        case .vignette: return "Vignette"
        case .chromaticAberration: return "Chromatic Aberration"
        case .filmGrain: return "Film Grain"
        case .colorGrade: return "Color Grade"
        case .posterize: return "Posterize"
        case .invert: return "Invert"
        }
    }

    var uiIcon: String {
        switch self {
        case .bloom: return "sun.max.fill"
        case .gaussianBlur: return "aqi.medium"
        case .sharpen: return "camera.aperture"
        case .vignette: return "circle.dashed.inset.filled"
        case .chromaticAberration: return "circle.hexagongrid.fill"
        case .filmGrain: return "circle.grid.cross.fill"
        case .colorGrade: return "slider.horizontal.3"
        case .posterize: return "square.grid.3x3.fill"
        case .invert: return "circle.lefthalf.filled"
        }
    }
}

private struct PostProcessControlSpec: Identifiable {
    enum Field: Hashable {
        case strength
        case a(Int)
    }

    let field: Field
    let label: String
    let icon: String
    let range: ClosedRange<Double>

    var id: Field { field }
}

private extension PostProcessKind {
    var controls: [PostProcessControlSpec] {
        typealias Spec = PostProcessControlSpec
        switch self {
        case .bloom:
            return [
                Spec(field: .strength, label: "Intensity", icon: "sun.max.fill", range: 0...3),
                Spec(field: .a(0), label: "Threshold", icon: "dial.medium", range: 0...2),
                Spec(field: .a(1), label: "Soft Knee", icon: "waveform.path", range: 0.01...1),
                Spec(field: .a(2), label: "Radius", icon: "arrow.up.left.and.arrow.down.right", range: 0.5...32),
                Spec(field: .a(3), label: "Scatter", icon: "sparkles", range: 0...1),
            ]
        case .gaussianBlur:
            return [
                Spec(field: .strength, label: "Mix", icon: "circle.lefthalf.filled", range: 0...1),
                Spec(field: .a(0), label: "Radius", icon: "aqi.medium", range: 0.5...32),
                Spec(field: .a(1), label: "Sigma", icon: "waveform.path", range: 0.25...16),
            ]
        case .sharpen:
            return [
                Spec(field: .strength, label: "Amount", icon: "camera.aperture", range: 0...2),
                Spec(field: .a(0), label: "Radius", icon: "smallcircle.filled.circle", range: 0.5...4),
            ]
        case .vignette:
            return [
                Spec(field: .strength, label: "Amount", icon: "circle.dashed.inset.filled", range: 0...1),
                Spec(field: .a(0), label: "Inner", icon: "circle", range: 0...1),
                Spec(field: .a(1), label: "Outer", icon: "largecircle.fill.circle", range: 0.05...1.5),
            ]
        case .chromaticAberration:
            return [
                Spec(field: .strength, label: "Mix", icon: "circle.lefthalf.filled", range: 0...1),
                Spec(field: .a(0), label: "Offset", icon: "arrow.left.and.right", range: 0...20),
                Spec(field: .a(1), label: "Angle", icon: "rotate.right", range: -Double.pi...Double.pi),
            ]
        case .filmGrain:
            return [
                Spec(field: .strength, label: "Amount", icon: "circle.grid.cross.fill", range: 0...0.5),
                Spec(field: .a(0), label: "Grain Size", icon: "square.grid.3x3", range: 0.5...8),
            ]
        case .colorGrade:
            return [
                Spec(field: .strength, label: "Mix", icon: "circle.lefthalf.filled", range: 0...1),
                Spec(field: .a(0), label: "Saturation", icon: "drop.halffull", range: 0...2),
                Spec(field: .a(1), label: "Contrast", icon: "circle.lefthalf.filled", range: 0...2),
                Spec(field: .a(2), label: "Brightness", icon: "sun.max", range: 0...3),
                Spec(field: .a(3), label: "Gamma", icon: "chart.line.uptrend.xyaxis", range: 0.2...3),
            ]
        case .posterize:
            return [
                Spec(field: .strength, label: "Mix", icon: "circle.lefthalf.filled", range: 0...1),
                Spec(field: .a(0), label: "Levels", icon: "square.grid.3x3.fill", range: 2...32),
            ]
        case .invert:
            return [
                Spec(field: .strength, label: "Mix", icon: "circle.lefthalf.filled", range: 0...1),
            ]
        }
    }
}

// MARK: - Stack section

/// Scene-owned ordered filter editor. Each row's output becomes the next
/// row's input; duplicate kinds are intentionally allowed.
public struct PostProcessStackSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Post Processing", icon: "camera.filters") {
                Menu {
                    ForEach(PostProcessKind.allCases, id: \.rawValue) { kind in
                        Button {
                            mirror.setPostProcessStack(
                                PostProcessStackEdit.adding(kind, to: mirror.postProcessStack))
                        } label: {
                            Label(kind.uiName, systemImage: kind.uiIcon)
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(mirror.postProcessStack.count >= PostProcessStackEdit.maximumCount)
            }

            Text("Filters run top to bottom. Reordering changes the image; disabled filters stay in the scene without using a GPU pass.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if mirror.postProcessStack.isEmpty {
                Text("No filters — Add an effect to build a full-frame processing chain.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(mirror.postProcessStack.enumerated()), id: \.element.id) {
                index, filter in
                PostProcessFilterRow(
                    index: index, filter: filter, mirror: mirror)
            }
        }
        .moduleCard(.purple)
    }
}

private struct PostProcessFilterRow: View {
    let index: Int
    let filter: PostProcessFilterDTO
    let mirror: ParameterMirror

    private var kind: PostProcessKind? { filter.knownKind }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.quaternary))
                Image(systemName: kind?.uiIcon ?? "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(filter.enabled ? .purple : .secondary)
                Text(kind?.uiName ?? "Unknown Filter (\(filter.kind))")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Toggle("Enabled", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Button {
                    publish(PostProcessStackEdit.moving(
                        mirror.postProcessStack, id: filter.id, by: -1))
                } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button {
                    publish(PostProcessStackEdit.moving(
                        mirror.postProcessStack, id: filter.id, by: 1))
                } label: { Image(systemName: "chevron.down") }
                    .disabled(index >= mirror.postProcessStack.count - 1)
                Button(role: .destructive) {
                    publish(PostProcessStackEdit.deleting(
                        mirror.postProcessStack, id: filter.id))
                } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)

            if let kind {
                ForEach(kind.controls) { spec in
                    EffectSliderRow(
                        icon: spec.icon,
                        label: spec.label,
                        value: valueBinding(spec.field),
                        in: spec.range)
                }
                .disabled(!filter.enabled)
                .opacity(filter.enabled ? 1 : 0.5)
            } else {
                Text("This filter was created by a newer version. It is preserved but not rendered here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.sm)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .background(
            Color.black.opacity(0.22),
            in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.22), lineWidth: 0.7))
    }

    private var enabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: {
                mirror.postProcessStack.first(where: { $0.id == filter.id })?.enabled
                    ?? filter.enabled
            },
            set: { enabled in
                publish(PostProcessStackEdit.settingEnabled(
                    mirror.postProcessStack, id: filter.id, to: enabled))
            })
    }

    private func valueBinding(
        _ field: PostProcessControlSpec.Field
    ) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: {
                guard let current = mirror.postProcessStack.first(where: { $0.id == filter.id })
                else { return 0 }
                switch field {
                case .strength:
                    return Double(current.strength)
                case .a(let component):
                    return current.a.indices.contains(component)
                        ? Double(current.a[component]) : 0
                }
            },
            set: { value in
                let next: [PostProcessFilterDTO]
                switch field {
                case .strength:
                    next = PostProcessStackEdit.settingStrength(
                        mirror.postProcessStack, id: filter.id, to: Float(value))
                case .a(let component):
                    next = PostProcessStackEdit.settingA(
                        mirror.postProcessStack, id: filter.id,
                        component: component, to: Float(value))
                }
                publish(next)
            })
    }

    private func publish(_ stack: [PostProcessFilterDTO]) {
        mirror.setPostProcessStack(stack)
    }
}
