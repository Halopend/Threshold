// WarpOps.swift — Swift-side ergonomics over the C ABI struct `ThreshWarpOp`
// (ADR-002; the layout lives ONLY in ThresholdShaderABI.h).
//
// This file provides:
//   - `WarpKind`: a Swift enum whose raw values EXACTLY match `ThreshWarpKind`
//     (values persist in scene files — never renumber).
//   - Typed constructors: one static factory per constructible kind.
//   - Registration metadata (`isIsometric`, `isDistanceOp`) used by the
//     per-stack Lipschitz/step-scale policy (plan §5.2).
//   - The payload field catalog: for each kind, which `strength`/`flags`/`a`/`b`
//     components it uses, with the field names that later seed dynamic catalog
//     registration under `warp.slot{N}.{field}` (plan §5.3, Invariant 14).
//
// Exact op math is normative in docs/op-semantics.md and implemented by
// `ReferenceOps` (CPU) and the MSL interpreter (GPU) — never here.

import simd
import ThresholdCore
import ThresholdShaderABI

// MARK: - WarpKind

/// Swift mirror of `ThreshWarpKind`. Raw values are the ABI values — they
/// persist in scene files and index the GPU interpreter's switch. NEVER
/// renumber; `Bounding` (66) is reserved (clip/fog, not implemented Phase 2).
public enum WarpKind: UInt32, CaseIterable, Sendable, Codable, Hashable {
    case none = 0
    // Bend & Wave
    case twist = 1
    case bend = 2
    case ripple = 3
    // Mirrors & Folds
    case mirror = 4
    case boxFold = 5
    case planeFold = 6
    case kaleidoscope = 7
    case coxeter = 8
    case mengerFold = 9
    case offsetFold = 10
    // Spherical & Radial
    case sphereFold = 11
    case sphereInvert = 12
    case tubeFold = 13
    case shells = 14
    // Self-Similar Repeats
    case scaleRepeat = 15
    case tiling = 16
    case scale = 17
    // Space projection
    case sphereProject = 18
    // Distance-space ops (>= 64)
    case handAttract = 64
    case forearmCarve = 65
    case bounding = 66

    /// Mirrors `THRESH_WARP_KIND_DISTANCE_OP_BASE` (cross-checked by tests).
    public static let distanceOpBase: UInt32 = 64

    /// Failable bridge from the imported C enum value.
    public init?(abi: ThreshWarpKind) {
        self.init(rawValue: UInt32(abi.rawValue))
    }

    /// The imported C enum value for this kind.
    public var abiValue: ThreshWarpKind {
        ThreshWarpKind(rawValue: ThreshWarpKind.RawValue(rawValue))
    }

    // MARK: Registration metadata

    /// True only for ops docs/op-semantics.md stamps "Isometric at s = 1":
    /// Mirror, BoxFold (incl. Hall of Mirrors), PlaneFold, Kaleidoscope,
    /// Coxeter, MengerFold, OffsetFold, Tiling. (Shells is deliberately
    /// excluded: piecewise-isometric radially but a tangential contraction,
    /// not an isometry.)
    public var isIsometric: Bool {
        switch self {
        case .mirror, .boxFold, .planeFold, .kaleidoscope,
             .coxeter, .mengerFold, .offsetFold, .tiling:
            return true
        default:
            return false
        }
    }

    /// Distance ops (`kind >= 64`) transform the resolved SDF value after the
    /// DE runs and receive the ORIGINAL world-space point.
    public var isDistanceOp: Bool { rawValue >= Self.distanceOpBase }

    /// True when this kind transforms the sample point before the DE runs.
    public var isPointOp: Bool { self != .none && !isDistanceOp }

    /// Free-function-style spellings of the registration metadata.
    public static func isIsometric(_ kind: WarpKind) -> Bool { kind.isIsometric }
    public static func isDistanceOp(_ kind: WarpKind) -> Bool { kind.isDistanceOp }
}

// MARK: - WarpFlags

/// Per-instance flag bits (`ThreshWarpOp.flags`). Kind-specific meaning.
public struct WarpFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// `THRESH_WARP_FLAG_OPTION_A` — BoxFold: Hall of Mirrors;
    /// HandAttract: pocket enabled.
    public static let optionA = WarpFlags(rawValue: 1 << 0)
}

// MARK: - Payload field catalog

/// Where a logical op field lives inside the 48-byte `ThreshWarpOp`.
public enum WarpPayloadPath: Sendable, Hashable {
    /// The universally bindable `strength` field.
    case strength
    /// A single bit of `flags` (exposed to the catalog as a bool param).
    case flagBit(UInt32)
    /// Component(s) of payload `a`.
    case a(WarpPayloadComponent)
    /// Component(s) of payload `b`.
    case b(WarpPayloadComponent)

    /// The `ParamKind` a catalog registration of this field uses.
    public var paramKind: ParamKind {
        switch self {
        case .strength: return .float
        case .flagBit: return .bool
        case .a(let c), .b(let c): return c == .xyz ? .float3 : .float
        }
    }
}

/// Component selector within a payload `float4`.
public enum WarpPayloadComponent: String, Sendable, Hashable, CaseIterable {
    case x, y, z, w
    /// The vector prefix (axis, center, normal, capsule endpoint, …).
    case xyz
}

/// One logical field of an op kind: its catalog field name (the `{field}` in
/// `warp.slot{N}.{field}`) and its physical location in the struct.
public struct WarpPayloadField: Sendable, Hashable {
    public let name: String
    public let path: WarpPayloadPath

    public init(_ name: String, _ path: WarpPayloadPath) {
        self.name = name
        self.path = path
    }

    /// The dynamic catalog key this field registers under for stack slot
    /// `slot` (Invariant 14 — minted only through the factory).
    public func paramKey(slot: Int) -> ParamKey {
        ParamKey.warp(slot: slot, field: name)
    }
}

extension WarpKind {
    /// The fields this kind exposes, in registration order. `strength` is
    /// first for every real kind (it is the universally bindable field —
    /// ADR-002). Data only: dynamic catalog registration in a later phase
    /// walks this to mint `warp.slot{N}.{field}` entries.
    public var payloadFields: [WarpPayloadField] {
        let strength = WarpPayloadField("strength", .strength)
        switch self {
        case .none, .bounding:
            return [] // no-op / reserved — nothing to register
        case .twist:
            return [strength, WarpPayloadField("axis", .a(.xyz))]
        case .bend:
            return [strength, WarpPayloadField("axis", .a(.xyz))]
        case .ripple:
            return [strength,
                    WarpPayloadField("axis", .a(.xyz)),
                    WarpPayloadField("frequency", .a(.w))]
        case .mirror:
            return [strength]
        case .boxFold:
            return [strength,
                    WarpPayloadField("limit", .a(.x)),
                    WarpPayloadField("hallOfMirrors", .flagBit(0))]
        case .planeFold:
            return [strength,
                    WarpPayloadField("normal", .a(.xyz)),
                    WarpPayloadField("distance", .a(.w))]
        case .kaleidoscope:
            return [strength, WarpPayloadField("segments", .a(.x))]
        case .coxeter:
            return [strength,
                    WarpPayloadField("p", .a(.x)),
                    WarpPayloadField("q", .a(.y))]
        case .mengerFold:
            return [strength]
        case .offsetFold:
            return [strength, WarpPayloadField("center", .a(.xyz))]
        case .sphereFold:
            return [strength,
                    WarpPayloadField("minRadius", .a(.x)),
                    WarpPayloadField("fixedRadius", .a(.y))]
        case .sphereInvert:
            return [strength, WarpPayloadField("radius", .a(.x))]
        case .tubeFold:
            return [strength,
                    WarpPayloadField("innerRadius", .a(.x)),
                    WarpPayloadField("outerRadius", .a(.y))]
        case .shells:
            return [strength, WarpPayloadField("spacing", .a(.x))]
        case .scaleRepeat:
            return [strength, WarpPayloadField("factor", .a(.x))]
        case .tiling:
            return [strength,
                    WarpPayloadField("cellSize", .a(.x)),
                    WarpPayloadField("axisMask", .b(.xyz))]
        case .scale:
            return [strength, WarpPayloadField("factor", .a(.x))]
        case .sphereProject:
            return [strength, WarpPayloadField("radius", .a(.x))]
        case .handAttract:
            return [strength,
                    WarpPayloadField("center", .a(.xyz)),
                    WarpPayloadField("radius", .a(.w)),
                    WarpPayloadField("ballScale", .b(.x)),
                    WarpPayloadField("softness", .b(.y)),
                    WarpPayloadField("pocketSize", .b(.z)),
                    WarpPayloadField("pocketSoftness", .b(.w)),
                    WarpPayloadField("pocketEnabled", .flagBit(0))]
        case .forearmCarve:
            return [strength,
                    WarpPayloadField("start", .a(.xyz)),
                    WarpPayloadField("radius", .a(.w)),
                    WarpPayloadField("end", .b(.xyz)),
                    WarpPayloadField("softness", .b(.w))]
        }
    }
}

// MARK: - Typed constructors

extension ThreshWarpOp {
    /// Decoded kind, `nil` for values this build does not know (forward
    /// compatibility: unknown kinds are treated as no-ops everywhere).
    public var warpKind: WarpKind? { WarpKind(rawValue: kind) }

    /// Decoded flags.
    public var warpFlags: WarpFlags { WarpFlags(rawValue: flags) }

    /// Common assembly point for all typed constructors.
    @inlinable
    static func make(
        _ kind: WarpKind,
        flags: WarpFlags = [],
        strength: Float,
        a: SIMD4<Float> = .zero,
        b: SIMD4<Float> = .zero
    ) -> ThreshWarpOp {
        var op = ThreshWarpOp()
        op.kind = kind.rawValue
        op.flags = flags.rawValue
        op.strength = strength
        op.a = a
        op.b = b
        return op
    }

    // MARK: Point ops (kind < 64)

    /// 1 — screw around `axis`, angle proportional to axial coordinate.
    public static func twist(axis: SIMD3<Float>, strength: Float) -> ThreshWarpOp {
        make(.twist, strength: strength, a: SIMD4(axis, 0))
    }

    /// 2 — bow around `axis`; bending coordinate is the deterministic
    /// perpendicular (`perpOf` in docs/op-semantics.md).
    public static func bend(axis: SIMD3<Float>, strength: Float) -> ThreshWarpOp {
        make(.bend, strength: strength, a: SIMD4(axis, 0))
    }

    /// 3 — sinusoidal displacement along `axis` driven by the perpendicular
    /// coordinate.
    public static func ripple(axis: SIMD3<Float>, frequency: Float, strength: Float) -> ThreshWarpOp {
        make(.ripple, strength: strength, a: SIMD4(axis, frequency))
    }

    /// 4 — fold into the positive octant (`abs`). `strength` blends.
    public static func mirror(strength: Float = 1) -> ThreshWarpOp {
        make(.mirror, strength: strength)
    }

    /// 5 — classic Mandelbox box fold at `limit`; `hallOfMirrors` switches to
    /// the mirrored infinite repeat.
    public static func boxFold(limit: Float, hallOfMirrors: Bool = false, strength: Float) -> ThreshWarpOp {
        make(.boxFold,
             flags: hallOfMirrors ? .optionA : [],
             strength: strength,
             a: SIMD4(limit, 0, 0, 0))
    }

    /// 6 — reflect points behind the plane `dot(p, normal) = distance`.
    public static func planeFold(normal: SIMD3<Float>, distance: Float, strength: Float) -> ThreshWarpOp {
        make(.planeFold, strength: strength, a: SIMD4(normal, distance))
    }

    /// 7 — fold the polar angle of p.xz into one wedge of width 2π/segments.
    public static func kaleidoscope(segments: Int, strength: Float) -> ThreshWarpOp {
        make(.kaleidoscope, strength: strength, a: SIMD4(Float(max(1, segments)), 0, 0, 0))
    }

    /// 8 — {p,q} rank-3 reflection-group fold (integers ≥ 2, stored as floats).
    public static func coxeter(p: Int, q: Int, strength: Float) -> ThreshWarpOp {
        make(.coxeter, strength: strength, a: SIMD4(Float(max(2, p)), Float(max(2, q)), 0, 0))
    }

    /// 9 — abs-fold + descending coordinate sort (Menger-sponge prep).
    public static func mengerFold(strength: Float) -> ThreshWarpOp {
        make(.mengerFold, strength: strength)
    }

    /// 10 — mirror fold whose crease is shifted to `center`.
    public static func offsetFold(center: SIMD3<Float>, strength: Float) -> ThreshWarpOp {
        make(.offsetFold, strength: strength, a: SIMD4(center, 0))
    }

    /// 11 — Mandelbox sphere fold (`minRadius`/`fixedRadius`).
    public static func sphereFold(minRadius: Float, fixedRadius: Float, strength: Float) -> ThreshWarpOp {
        make(.sphereFold, strength: strength, a: SIMD4(minRadius, fixedRadius, 0, 0))
    }

    /// 12 — conformal inversion through the sphere of `radius`.
    public static func sphereInvert(radius: Float, strength: Float) -> ThreshWarpOp {
        make(.sphereInvert, strength: strength, a: SIMD4(radius, 0, 0, 0))
    }

    /// 13 — sphere fold restricted to the XZ plane (vertical tube structure).
    public static func tubeFold(innerRadius: Float, outerRadius: Float, strength: Float) -> ThreshWarpOp {
        make(.tubeFold, strength: strength, a: SIMD4(innerRadius, outerRadius, 0, 0))
    }

    /// 14 — fold radius to the nearest concentric shell (`spacing` > 0).
    public static func shells(spacing: Float, strength: Float) -> ThreshWarpOp {
        make(.shells, strength: strength, a: SIMD4(spacing, 0, 0, 0))
    }

    /// 15 — log-radial Droste; maps p into the shell [1, factor) (`factor` > 1).
    public static func scaleRepeat(factor: Float, strength: Float) -> ThreshWarpOp {
        make(.scaleRepeat, strength: strength, a: SIMD4(factor, 0, 0, 0))
    }

    /// 16 — infinite lattice repeat with `cellSize`, per enabled axis.
    public static func tiling(
        cellSize: Float,
        repeatX: Bool = true,
        repeatY: Bool = true,
        repeatZ: Bool = true,
        strength: Float
    ) -> ThreshWarpOp {
        make(.tiling,
             strength: strength,
             a: SIMD4(cellSize, 0, 0, 0),
             b: SIMD4(repeatX ? 1 : 0, repeatY ? 1 : 0, repeatZ ? 1 : 0, 0))
    }

    /// 17 — uniform domain scale by `factor` (> 0; IFS glue step).
    public static func scale(factor: Float, strength: Float) -> ThreshWarpOp {
        make(.scale, strength: strength, a: SIMD4(factor, 0, 0, 0))
    }

    /// 18 — radial compression toward the sphere shell of `radius`.
    public static func sphereProject(radius: Float, strength: Float) -> ThreshWarpOp {
        make(.sphereProject, strength: strength, a: SIMD4(radius, 0, 0, 0))
    }

    // MARK: Distance ops (kind >= 64)

    /// 64 — hand ball attract/repel. Sign of `strength` selects attract (> 0)
    /// vs repel (< 0); `pocketEnabled` carves a pocket when attracting.
    public static func handAttract(
        center: SIMD3<Float>,
        radius: Float,
        ballScale: Float,
        softness: Float,
        pocketSize: Float,
        pocketSoftness: Float,
        pocketEnabled: Bool,
        strength: Float
    ) -> ThreshWarpOp {
        make(.handAttract,
             flags: pocketEnabled ? .optionA : [],
             strength: strength,
             a: SIMD4(center, radius),
             b: SIMD4(ballScale, softness, pocketSize, pocketSoftness))
    }

    /// 65 — forearm capsule carve. ALWAYS subtractive; there is no sign field,
    /// structurally (plan §4.4).
    public static func forearmCarve(
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        radius: Float,
        softness: Float,
        strength: Float
    ) -> ThreshWarpOp {
        make(.forearmCarve,
             strength: strength,
             a: SIMD4(from, radius),
             b: SIMD4(to, softness))
    }

    // NOTE: WarpKind.bounding (66) is reserved (clip/fog op; not implemented
    // in Phase 2) — deliberately no constructor.
}

// MARK: - Internal swizzle helper

extension SIMD4 where Scalar == Float {
    /// The vector prefix of a payload float4.
    @inlinable
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
