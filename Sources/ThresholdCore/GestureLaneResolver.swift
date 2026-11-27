// GestureLaneResolver.swift — the pure bridge from "a gesture was detected" to
// "these gesture-lane slots move". It is the connective tissue between the
// binding model and the renderer: detection (ARKit, visionOS-only) produces a
// `GestureDrive` per active source, and this maps each through its binding into
// `LaneWrite`s on the `.gesture` lane. Kept platform-free so it is unit-tested
// on any host — the visionOS tracker is then a thin joints→drives shim.
//
// Semantics: each target parameter's COMPOSITION decides what a drive means.
//
//   • additive   — the gesture contributes an OFFSET on top of the accumulated
//     value (`offset = drive · gain · span`): two simultaneous sources both
//     push the parameter (their offsets sum).
//   • multiplicative — the gesture contributes a FACTOR around the neutral 1,
//     in log space (`factor = exp(drive · gain · logReach)`), so a full drive
//     at full gain reaches the range edge and two simultaneous sources scale
//     together (factors multiply). This matches how multiplicative lane values
//     are consumed (ModulationEngine: `acc *= laneValue`) and the camera
//     dolly's hand-write path (`exp(accumulated log-dolly)`).
//   • replace — the gesture OWNS the slot while live: it writes the absolute
//     value `default + drive · gain · span`, overwriting scene/base state for
//     the gesture's duration (that is what replace means; resolution clamps).
//
// Two replace-only wrinkles follow from that lane write being absolute —
// both inherent to replace semantics, both accepted for now:
//   1. A live gesture anchored at rest holds the param at its DEFAULT, not
//      its authored value. (Anchoring at the live composed value would need
//      engine state, and this resolver is deliberately pure: `(drives,
//      table, layout) → writes` is a pure function, unit-tested without a
//      ModulationEngine. Refined anchoring belongs to gesture-vocabulary
//      expansion, tracker-side accumulators.)
//   2. Lane order still applies (Invariant 16): on a replace target a live
//      MUSIC write (later lane) overrides the gesture, while the gesture
//      overrides scene/animation/system/user. On multiplicative targets a
//      music factor multiplies the gesture's factor.
//
// `gain` is the single tuning knob (finger travel → parameter travel); real
// feel is dialed in on-device. Resolution clamps into range, so this file
// doesn't need to — with one exception documented below (multiplicative
// degenerate ranges).

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
    /// (behavioral — the tracker handles those), keys absent from `layout`,
    /// and discrete-kind targets (`.bool`/`.enumeration` — a drag has no
    /// meaning for a toggle; the editor never offers them) all yield no write.
    ///
    /// ## Deterministic arbitration
    ///
    /// Sources are iterated in `GestureSource.arbitrationRank` order — never
    /// dictionary order — so this frame's output is a pure function of the
    /// drive set. Each touched (lane, slot) then emits EXACTLY ONE write,
    /// composed from every qualifying source by the slot's composition:
    ///
    ///   - additive: the sources' offsets sum (both sources push).
    ///   - multiplicative: the sources' factors multiply (both scale).
    ///   - replace: the LOWEST-RANK (most precise) armed source owns the slot
    ///     for the frame; its value alone is written and later, blunter
    ///     sources cannot ratchet it aside mid-drag.
    public static func resolve(
        drives: [GestureSource: GestureDrive],
        table: GestureBindingTable,
        layout: CatalogLayout,
        gain: Float = defaultGain
    ) -> [LaneWrite] {
        var slots: [Int: SlotValue] = [:]
        // Canonical order (see arbitrationRank): precision-first, left first,
        // index first — replace ownership and any future order-sensitive
        // policy resolve identically regardless of dictionary iteration.
        for (source, drive) in drives
        .sorted(by: { $0.key.arbitrationRank < $1.key.arbitrationRank }) {
            guard let binding = table.binding(for: source) else { continue }
            switch binding {
            case let .vector(target):
                guard case let .vector(v) = drive else { continue }  // arity guard
                appendVector(v, to: target, layout: layout, gain: gain, into: &slots)
            case let .scalar(key):
                appendScalar(drive.scalarValue, to: key, layout: layout, gain: gain, into: &slots)
            case let .scalarAxis(key, axis):
                guard case let .vector(v) = drive else { continue }
                appendScalar(v[axis.component], to: key, layout: layout, gain: gain, into: &slots)
            case .core:
                continue
            }
        }
        // Exactly one write per touched slot, in ascending slot order: the
        // mailbox is latest-value-wins per (lane, slot), so a resolver that
        // ever emitted more than one per slot would be silently depending on
        // publication order.
        return slots
            .sorted { $0.key < $1.key }
            .map { slot, acc in LaneWrite(lane: .gesture, slot: slot, value: acc.value) }
    }

    // MARK: Mapping

    /// One touched slot's composed write value, plus the composition that
    /// decides how later sources must compose into it.
    private struct SlotValue {
        let composition: Composition
        var value: Float
    }

    /// The `drive · gain · span` piece, in composition-relative units.
    private static func offset(_ drive: Float, span: Float, gain: Float) -> Float {
        drive * gain * span
    }

    /// The multiplicative write for one drive, or nil when the range cannot
    /// express multiplicative excursions at all (non-finite or non-positive
    /// upper bound — factors are relative to the neutral 1).
    ///
    /// The gesture lane's multiplicative neutral is 1: at rest (and whenever a
    /// side has no excursion room) the write is the inert factor 1. A FULL
    /// drive at `gain == 1` reaches exactly the range edge, in log space:
    ///   - `drive >= 0` factors toward the upper edge: `exp(drive·gain·ln(hi))
    ///     (the formula also handles a range lying entirely below 1, where
    ///     `ln(hi) < 0` pulls the factor downward to its edge).
    ///   - `drive < 0` factors toward the lower edge via `ln(1 / lo)`, possible
    ///     only while `lo > 0` and `lo < 1`; otherwise the factor stays 1 (the
    ///     range has nothing below the neutral).
    private static func multiplicativeFactor(
        _ drive: Float, range: ClosedRange<Float>, gain: Float
    ) -> Float? {
        let hi = range.upperBound
        let lo = range.lowerBound
        guard drive.isFinite, hi.isFinite, hi > 0 else { return nil }
        if drive >= 0 {
            return exp(drive * gain * log(hi))
        }
        guard lo.isFinite, lo > 0, lo < 1 else { return 1 }
        return exp(drive * gain * log(1 / lo))
    }

    /// Compose one more source's contribution into a touched slot. The first
    /// (lowest-rank) writer fixes the slot's write composition; later
    /// contributions merge additively, multiplicatively, or not at all
    /// (replace keeps its owner).
    private static func compose(
        slot: Int, composition: Composition, value: Float, into slots: inout [Int: SlotValue]
    ) {
        guard slots[slot] != nil else {
            slots[slot] = SlotValue(composition: composition, value: value)
            return
        }
        switch composition {
        case .additive:
            if slots[slot]!.composition == .additive { slots[slot]!.value += value }
        case .multiplicative:
            if slots[slot]!.composition == .multiplicative { slots[slot]!.value *= value }
        case .replace:
            break  // first (lowest-rank) source keeps ownership
        }
    }

    /// One source's scalar drive lands on one slot of `entry`.
    private static func contribute(
        _ drive: Float, to entry: CatalogEntry, slot: Int,
        gain: Float, into slots: inout [Int: SlotValue]
    ) {
        let spec = entry.spec
        let component = slot - entry.slot
        guard component >= 0, component < spec.defaultValue.count else { return }
        // Discrete kinds are never gesture targets (the editor excludes them;
        // a foreign hand-authored binding must not produce a mid-table
        // nonsensical value).
        switch spec.kind {
        case .bool, .enumeration: return
        case .float, .float3, .float4: break
        }
        let span = spec.range.upperBound - spec.range.lowerBound
        switch spec.composition {
        case .additive:
            compose(slot: slot, composition: .additive,
                    value: offset(drive, span: span, gain: gain), into: &slots)
        case .multiplicative:
            guard let factor = multiplicativeFactor(drive, range: spec.range, gain: gain) else { return }
            compose(slot: slot, composition: .multiplicative, value: factor, into: &slots)
        case .replace:
            // Absolute write, anchored at the parameter's default so the
            // neutral-est gesture drive reproduces the authored value.
            compose(slot: slot, composition: .replace,
                    value: spec.defaultValue[component] + offset(drive, span: span, gain: gain),
                    into: &slots)
        }
    }

    private static func appendVector(
        _ v: SIMD3<Float>, to target: Vec3Target,
        layout: CatalogLayout, gain: Float, into slots: inout [Int: SlotValue]
    ) {
        switch target {
        case let .native(key):
            guard let entry = layout.entry(for: key) else { return }
            for axis in GestureAxis.allCases {
                contribute(v[axis.component], to: entry, slot: entry.slot + axis.component,
                           gain: gain, into: &slots)
            }
        case let .grouped(x, y, z):
            let axes: [(GestureAxis, ParamKey?)] = [(.x, x), (.y, y), (.z, z)]
            for (axis, key) in axes {
                guard let key, let entry = layout.entry(for: key) else { continue }
                contribute(v[axis.component], to: entry, slot: entry.slot,
                           gain: gain, into: &slots)
            }
        }
    }

    private static func appendScalar(
        _ s: Float, to key: ParamKey,
        layout: CatalogLayout, gain: Float, into slots: inout [Int: SlotValue]
    ) {
        guard let entry = layout.entry(for: key) else { return }
        contribute(s, to: entry, slot: entry.slot, gain: gain, into: &slots)
    }
}