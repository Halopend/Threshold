// Controls.swift — generic parameter rows keyed by ParamKind (plan §2.2:
// "Zero per-param UI code"). Every control is (CatalogEntry, ParameterMirror);
// nothing in this file knows any particular parameter.
//
// Slider geometry goes through `ResponseCurveMapping` — pure static functions
// (position ↔ value through the spec's ResponseCurve) that are unit-tested
// directly. The curve is UI/binding metadata ONLY (ParamTypes.swift); it is
// never applied during lane resolution.

import SwiftUI
import ThresholdCore

// MARK: - ResponseCurveMapping (pure, testable)

/// Maps a normalized slider position (0…1) to a parameter value inside the
/// spec's clamp range and back, through a `ResponseCurve`.
///
/// Contract (unit-tested):
///   - endpoints are EXACT: position 0 ↔ range.lowerBound, 1 ↔ upperBound;
///   - monotonic in between for every curve;
///   - `position(forValue: value(forPosition: t)) ≈ t` (Float tolerance).
public enum ResponseCurveMapping {
    /// Below this |k|, `.exp(k)` is numerically linear — treat it as such
    /// (the k→0 limit of (e^kt − 1)/(e^k − 1) IS t).
    private static let linearKThreshold: Float = 1e-4

    /// Normalized slider position → parameter value in `range`.
    public static func value(
        forPosition position: Float,
        in range: ClosedRange<Float>,
        curve: ResponseCurve
    ) -> Float {
        let lo = range.lowerBound
        let hi = range.upperBound
        guard hi > lo else { return lo }
        guard position > 0 else { return lo }
        guard position < 1 else { return hi }
        return lo + shape(position, curve: curve) * (hi - lo)
    }

    /// Parameter value → normalized slider position.
    public static func position(
        forValue value: Float,
        in range: ClosedRange<Float>,
        curve: ResponseCurve
    ) -> Float {
        let lo = range.lowerBound
        let hi = range.upperBound
        guard hi > lo else { return 0 }
        guard value > lo else { return 0 }
        guard value < hi else { return 1 }
        return unshape((value - lo) / (hi - lo), curve: curve)
    }

    /// The normalized curve: 0…1 position → 0…1 fraction of the range.
    /// Strictly increasing with shape(0) == 0, shape(1) == 1 for every case.
    static func shape(_ t: Float, curve: ResponseCurve) -> Float {
        let x = min(max(t, 0), 1)
        switch curve {
        case .linear:
            return x
        case .exp(let k):
            guard k.isFinite, abs(k) > linearKThreshold else { return x }
            return (expf(k * x) - 1) / (expf(k) - 1)
        case .sCurve:
            return x * x * (3 - 2 * x)  // smoothstep
        }
    }

    /// Exact inverse of `shape` on 0…1.
    static func unshape(_ s: Float, curve: ResponseCurve) -> Float {
        let x = min(max(s, 0), 1)
        switch curve {
        case .linear:
            return x
        case .exp(let k):
            guard k.isFinite, abs(k) > linearKThreshold else { return x }
            return logf(1 + x * (expf(k) - 1)) / k
        case .sCurve:
            // Analytic smoothstep inverse: 0.5 − sin(asin(1 − 2s) / 3).
            return 0.5 - sinf(asinf(1 - 2 * x) / 3)
        }
    }
}

// MARK: - Value formatting

/// ParamSpec carries no Unit metadata yet, so labels use adaptive numeric
/// precision. When specs grow a `unit` field, format through it here — this
/// is the single formatting site.
enum ValueFormatting {
    static func format(_ value: Float) -> String {
        let magnitude = abs(value)
        let format: String
        switch magnitude {
        case 1000...: format = "%.0f"
        case 100..<1000: format = "%.1f"
        case 10..<100: format = "%.2f"
        default: format = "%.3f"
        }
        return String(format: format, value)
    }
}

// MARK: - ParameterRow (kind dispatch)

/// One catalog entry → one control row. Dispatch is purely on `ParamKind`;
/// this is the only switch the whole parameter UI has.
public struct ParameterRow: View {
    let entry: CatalogEntry
    let mirror: ParameterMirror

    public init(entry: CatalogEntry, mirror: ParameterMirror) {
        self.entry = entry
        self.mirror = mirror
    }

    public var body: some View {
        switch entry.kind {
        case .float:
            FloatSlotRow(
                label: entry.spec.label, slot: entry.slot,
                range: entry.spec.range, curve: entry.spec.curve, mirror: mirror)
        case .bool:
            BoolRow(label: entry.spec.label, slot: entry.slot, mirror: mirror)
        case .enumeration(let caseCount):
            EnumRow(
                label: entry.spec.label, slot: entry.slot,
                caseCount: caseCount, mirror: mirror)
        case .float3, .float4:
            VectorRow(entry: entry, mirror: mirror)
        }
    }
}

// MARK: - Float

/// Slider for one scalar slot, mapped through the spec's ResponseCurve.
/// Shares `EffectSliderRow`'s geometry (RowMetrics) so catalog rows and
/// ad-hoc rows line up in the same card.
struct FloatSlotRow: View {
    let label: String
    let slot: Int
    let range: ClosedRange<Float>
    let curve: ResponseCurve
    let mirror: ParameterMirror
    var icon: String?
    var labelWidth: CGFloat = RowMetrics.labelWidth

    /// Raw slider position echoed back while dragging, bypassing the
    /// position→value→position round trip through the curve for the
    /// binding's `get`. `ResponseCurveMapping`'s own contract is only
    /// approximate ("≈ t", Float tolerance) — for curved (`.exp`/`.sCurve`)
    /// responses, feeding a `set` position back through `value(forPosition:)`
    /// then `position(forValue:)` can return a slightly different position
    /// than what was just set. SwiftUI's `Slider` sees its bound value
    /// "jump" on its own mid-gesture and can spin trying to reconcile it —
    /// surfaces as the runtime's "onChange action tried to update multiple
    /// times per frame" diagnostic, and in practice as the thumb freezing.
    /// Echoing the exact `set` position here (same trick as
    /// `ParameterMirror.pendingEdits`, one layer up) keeps `get`/`set`
    /// consistent for the duration of the drag.
    @State private var liveDragPosition: Double?

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            RowLabel(icon: icon, label: label, labelWidth: labelWidth)
            Slider(value: positionBinding, in: 0...1) { editing in
                if editing {
                    mirror.beginEdit(slot: slot)
                } else {
                    liveDragPosition = nil
                    mirror.endEdit(slot: slot)
                }
            }
            EditableNumberText(
                display: ValueFormatting.format(mirror.displayValue(slot: slot)),
                value: Double(mirror.displayValue(slot: slot)),
                range: Double(range.lowerBound)...Double(range.upperBound),
                commit: { mirror.updateEdit(slot: slot, target: Float($0)) })
        }
        .frame(minHeight: RowMetrics.height)
    }

    private var positionBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: {
                liveDragPosition ?? Double(ResponseCurveMapping.position(
                    forValue: mirror.displayValue(slot: slot), in: range, curve: curve))
            },
            set: { position in
                liveDragPosition = position
                mirror.updateEdit(
                    slot: slot,
                    target: ResponseCurveMapping.value(
                        forPosition: Float(position), in: range, curve: curve))
            }
        )
    }
}

// MARK: - Bool

/// Toggle over a 0/1 slot: resolved != 0 reads as on; writes are userEdit 1/0.
struct BoolRow: View {
    let label: String
    let slot: Int
    let mirror: ParameterMirror

    var body: some View {
        Toggle(label, isOn: SwiftUI.Binding(
            get: { mirror.displayValue(slot: slot) != 0 },
            set: { mirror.updateEdit(slot: slot, target: $0 ? 1 : 0) }
        ))
    }
}

// MARK: - Enumeration

/// Picker over 0..<caseCount. Case labels are "Mode N" until ParamSpec
/// carries case names (it does not today — noted limitation).
struct EnumRow: View {
    let label: String
    let slot: Int
    let caseCount: Int
    let mirror: ParameterMirror

    var body: some View {
        let picker = Picker(label, selection: selectionBinding) {
            ForEach(0..<max(caseCount, 1), id: \.self) { index in
                Text("Mode \(index)").tag(index)
            }
        }
        if caseCount <= 4 {
            picker.pickerStyle(.segmented)
        } else {
            picker.pickerStyle(.menu)
        }
    }

    private var selectionBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: {
                let raw = Int(mirror.displayValue(slot: slot).rounded())
                return min(max(raw, 0), max(caseCount - 1, 0))
            },
            set: { mirror.updateEdit(slot: slot, target: Float($0)) }
        )
    }
}

// MARK: - Vectors

/// Component sliders for float3/float4 in a labeled group. Each component is
/// its own slot (`entry.slot + i`); range/curve apply per component
/// (ParamSpec.range is per-component by contract).
struct VectorRow: View {
    static let componentLabels = ["X", "Y", "Z", "W"]

    let entry: CatalogEntry
    let mirror: ParameterMirror

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.spec.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(0..<entry.kind.slotWidth, id: \.self) { component in
                FloatSlotRow(
                    label: Self.componentLabels[component],
                    slot: entry.slot + component,
                    range: entry.spec.range,
                    curve: entry.spec.curve,
                    mirror: mirror,
                    labelWidth: 24)
            }
        }
    }
}
