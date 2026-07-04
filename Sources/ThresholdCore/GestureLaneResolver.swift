// GestureLaneResolver.swift — the pure bridge from "a gesture was detected" to
// "these gesture-lane slots move". It is the connective tissue between the
// binding model and the renderer: detection (ARKit, visionOS-only) produces a
// `GestureDrive` per active source, and this maps each through its binding into
// `LaneWrite`s on the `.gesture` lane. Kept platform-free so it is unit-tested
// on any host — the visionOS tracker is then a thin joints→drives shim.
//
// Semantic: the gesture lane composes ADDITIVELY over base (Invariant 3 — it is
// transient, never folded in), so a drive maps to an OFFSET, not an absolute.
// `offset = drive · gain · span`, where span is the param's range width. `gain`
// is the single tuning knob (finger travel → parameter travel); real feel is
// dialed in on-device. Resolution clamps into range, so this never needs to.

import simd

// MARK: - GestureDrive

/// One source's detected output for a frame. Vector sources (pinch-drag, swipe)
/// yield a signed per-axis drive; scalar sources (palm tap, fist) yield one
/// value. Components are expected pre-normalized to roughly ±1 (vector) or 0…1
/// (scalar) by the detector, so `gain` means the same thing across sources.
public enum GestureDrive: Sendable, Hashable {
    case vector(SIMD3<Float>)
    case scalar(Float)

    /// Collapse to a scalar (a vector source bound to a scalar param uses its
    /// magnitude). Scalar drives pass through.
    public var scalarValue: Float {
        switch self {
        case let .vector(v): return simd_length(v)
        case let .scalar(s): return s
        }
    }

    /// The arity this drive can satisfy.
    public var arity: GestureArity {
        switch self {
        case .vector: return .vector
        case .scalar: return .scalar
        }
    }
}

// MARK: - Resolver

public enum GestureLaneResolver {
    /// Default finger-travel → parameter-travel gain. Deliberately gentle;
    /// tuned per feel on-device.
    public static let defaultGain: Float = 0.5

    /// Map every active source's drive through its binding into gesture-lane
    /// writes. Sources without a binding, arity mismatches, `.core` bindings
    /// (behavioral — the tracker handles those), and keys absent from `layout`
    /// all yield no write.
    public static func resolve(
        drives: [GestureSource: GestureDrive],
        table: GestureBindingTable,
        layout: CatalogLayout,
        gain: Float = defaultGain
    ) -> [LaneWrite] {
        var writes: [LaneWrite] = []
        for (source, drive) in drives {
            guard let binding = table.binding(for: source) else { continue }
            switch binding {
            case let .vector(target):
                guard case let .vector(v) = drive else { continue }  // arity guard
                appendVector(v, to: target, layout: layout, gain: gain, into: &writes)
            case let .scalar(key):
                appendScalar(drive.scalarValue, to: key, layout: layout, gain: gain, into: &writes)
            case .core:
                continue
            }
        }
        return writes
    }

    // MARK: Mapping

    private static func offset(_ drive: Float, range: ClosedRange<Float>, gain: Float) -> Float {
        drive * gain * (range.upperBound - range.lowerBound)
    }

    private static func appendVector(
        _ v: SIMD3<Float>, to target: Vec3Target,
        layout: CatalogLayout, gain: Float, into writes: inout [LaneWrite]
    ) {
        switch target {
        case let .native(key):
            guard let entry = layout.entry(for: key) else { return }
            for axis in GestureAxis.allCases {
                writes.append(LaneWrite(
                    lane: .gesture,
                    slot: entry.slot + axis.component,
                    value: offset(v[axis.component], range: entry.spec.range, gain: gain)))
            }
        case let .grouped(x, y, z):
            let axes: [(GestureAxis, ParamKey?)] = [(.x, x), (.y, y), (.z, z)]
            for (axis, key) in axes {
                guard let key, let entry = layout.entry(for: key) else { continue }
                writes.append(LaneWrite(
                    lane: .gesture,
                    slot: entry.slot,
                    value: offset(v[axis.component], range: entry.spec.range, gain: gain)))
            }
        }
    }

    private static func appendScalar(
        _ s: Float, to key: ParamKey,
        layout: CatalogLayout, gain: Float, into writes: inout [LaneWrite]
    ) {
        guard let entry = layout.entry(for: key) else { return }
        writes.append(LaneWrite(
            lane: .gesture,
            slot: entry.slot,
            value: offset(s, range: entry.spec.range, gain: gain)))
    }
}
