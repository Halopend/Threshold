// LegacyMigration.swift — version 0 → 1: the ORIGINAL app's flat
// FractalPreset-era .threshscene format into the rebuild envelope
// (plan §7.3; corpus in Corpus/legacy/, captured 2026-07-02 from
// TEMP/MetalRaymarch-main).
//
// Philosophy: migrations NEVER delete. Every legacy key stays in the tree —
// consumed or not — and rides through decode into `unknown`/`foreignParams`,
// so a future, higher-fidelity migration (e.g. formulaParamValues → de.*
// params once the kleinian DE lands) still has the raw material. What this
// pass maps is the tractable structural core:
//
//   fractalType            → fractalTypeKey (name-level)
//   position + worldRotationXYZW → camera
//   fractalIterations / maxRaySteps / aoStrength → engine.* params
//   colorScheme* / tonemapStrength → color.* grading params
//   gradientState.gradient → palette + color.gradient.* params
//   spaceWarpOps           → warpStack (kind + payload remap, disabled ops
//                            dropped — they were UI state, not content)
//   sphereProjection*      → one .sphereProject warp op (Invariant 6:
//                            ONE sphere system)
//
// Legacy files carry `schemaVersion` (or nothing) instead of `version`;
// SceneCodec.decode treats a version-less tree with a `fractalType` as
// version 0 and routes it here.

public enum LegacyScene {
    /// True when a version-less JSON tree looks like an original-app scene.
    static func isLegacyTree(_ tree: [String: JSONValue]) -> Bool {
        tree["version"] == nil && tree["fractalType"] != nil
    }

    /// Legacy `SpaceWarpType` raw value → rebuild `WarpKind` raw value
    /// (both stable on-disk vocabularies; mapped by NAME, the numbering
    /// diverged). Index = legacy raw value.
    static let kindMap: [UInt32] = [
        1,   // 0 twist        → twist
        2,   // 1 bend         → bend
        4,   // 2 mirror       → mirror
        5,   // 3 boxFold      → boxFold
        11,  // 4 sphereFold   → sphereFold
        12,  // 5 inversion    → sphereInvert
        7,   // 6 kaleidoscope → kaleidoscope
        3,   // 7 ripple       → ripple
        13,  // 8 circle       → tubeFold
        14,  // 9 shells       → shells
        15,  // 10 scaleRepeat → scaleRepeat
        8,   // 11 coxeter     → coxeter
        6,   // 12 planeFold   → planeFold
        9,   // 13 mengerFold  → mengerFold
        16,  // 14 tiling      → tiling
        17,  // 15 scale       → scale
        10,  // 16 offsetFold  → offsetFold
    ]

    /// Rebuild WarpKind raw values whose payload uses `a.xyz` as a vector
    /// (axis/normal/center) — legacy `axis` maps there; legacy `p1` then
    /// lands in `a.w` where the kind has a scalar (ripple frequency,
    /// planeFold distance).
    private static let vectorKinds: Set<UInt32> = [1, 2, 3, 6, 10]  // twist, bend, ripple, planeFold, offsetFold

    /// The rebuild's sphereProject WarpKind raw value.
    private static let sphereProjectKind: UInt32 = 18
    /// BoxFold "Hall of Mirrors" option bit (WarpFlags.optionA).
    private static let optionAFlag: UInt32 = 1

    /// The 0 → 1 migration step.
    public static let migration = SceneMigration(fromVersion: 0) { tree in
        var params: [String: JSONValue] = [:]

        func number(_ key: String) -> Double? {
            if case .number(let n)? = tree[key] { return n }
            return nil
        }
        func copyParam(_ legacyKey: String, to paramKey: ParamKey) {
            if let n = number(legacyKey) {
                params[paramKey.rawValue] = .array([.number(n)])
            }
        }

        // --- identity ----------------------------------------------------
        if case .string(let type)? = tree["fractalType"] {
            tree["fractalTypeKey"] = .string(
                type == "mandelboxSphereProjection" ? "mandelbox" : type)
        }
        // `name` carries over verbatim (same key both formats).

        // --- camera ------------------------------------------------------
        var position: [JSONValue] = [.number(0), .number(0), .number(3)]
        if case .array(let p)? = tree["position"], p.count == 3 {
            position = p
        }
        let orientation: [JSONValue] = [
            .number(number("worldRotationX") ?? 0),
            .number(number("worldRotationY") ?? 0),
            .number(number("worldRotationZ") ?? 0),
            .number(number("worldRotationW") ?? 1),
        ]
        tree["camera"] = .object([
            "position": .array(position),
            "orientation": .array(orientation),
            "fovYRadians": .number(Double.pi / 3),
        ])

        // --- engine + grading scalars -------------------------------------
        copyParam("fractalIterations", to: .engineIterations)
        copyParam("maxRaySteps", to: .engineMaxSteps)
        copyParam("aoStrength", to: .engineAOStrength)
        copyParam("colorSchemeSaturation", to: .colorSaturation)
        copyParam("colorSchemeContrast", to: .colorContrast)
        copyParam("colorSchemeVibrance", to: .colorVibrance)
        copyParam("colorSchemeGamma", to: .colorGamma)
        copyParam("tonemapStrength", to: .colorTonemap)

        // --- palette (gradientState.gradient) -----------------------------
        if case .object(let state)? = tree["gradientState"],
           case .object(let gradient)? = state["gradient"] {
            func gnumber(_ key: String) -> Double? {
                if case .number(let n)? = gradient[key] { return n }
                return nil
            }
            if case .array(let stops)? = gradient["stops"] {
                var mapped: [JSONValue] = []
                for stop in stops {
                    guard case .object(let s) = stop,
                          case .number(let pos)? = s["position"],
                          case .array(let rgb)? = s["color"], rgb.count >= 3,
                          case .number(let r) = rgb[0],
                          case .number(let g) = rgb[1],
                          case .number(let b) = rgb[2]
                    else { continue }
                    mapped.append(.object([
                        "position": .number(pos),
                        "red": .number(r), "green": .number(g), "blue": .number(b),
                    ]))
                }
                if !mapped.isEmpty {
                    tree["palette"] = .object(["stops": .array(mapped)])
                }
            }
            if let n = gnumber("repeatCount") {
                params[ParamKey.colorGradientRepeat.rawValue] = .array([.number(n)])
            }
            if let n = gnumber("offset") {
                params[ParamKey.colorGradientOffset.rawValue] = .array([.number(n)])
            }
            if let n = gnumber("smoothing") {
                params[ParamKey.colorGradientSmoothing.rawValue] = .array([.number(n)])
            }
            if let n = gnumber("mappingMode") {
                params[ParamKey.colorMapMode.rawValue] = .array([.number(n)])
            }
        }

        // --- warp stack ----------------------------------------------------
        var stack: [JSONValue] = []
        if case .array(let ops)? = tree["spaceWarpOps"] {
            for opValue in ops {
                guard case .object(let op) = opValue else { continue }
                func onumber(_ key: String) -> Double {
                    if case .number(let n)? = op[key] { return n }
                    return 0
                }
                // Disabled ops were UI state; content is the enabled stack.
                if case .bool(false)? = op["isEnabled"] { continue }
                guard case .number(let rawType)? = op["type"],
                      let legacyType = Int(exactly: rawType.rounded()),
                      legacyType >= 0, legacyType < kindMap.count
                else { continue }
                let kind = kindMap[legacyType]

                var a: [Double] = [0, 0, 0, 0]
                var flags: UInt32 = 0
                let p1 = onumber("p1")
                let p2 = onumber("p2")
                if vectorKinds.contains(kind) {
                    if case .array(let axis)? = op["axis"], axis.count == 3 {
                        for (i, c) in axis.enumerated() {
                            if case .number(let n) = c { a[i] = n }
                        }
                    }
                    a[3] = p1  // ripple frequency / planeFold distance; 0 elsewhere
                } else {
                    a[0] = p1
                    a[1] = p2
                }
                // Legacy BoxFold: p1 = fold limit (a.x, set above); the
                // "Hall of Mirrors" toggle lived in p2 as 0/1 → flag bit.
                if kind == 5 {
                    a[1] = 0
                    if p2 != 0 { flags |= optionAFlag }
                }

                stack.append(.object([
                    "kind": .number(Double(kind)),
                    "flags": .number(Double(flags)),
                    "strength": .number(onumber("strength")),
                    "a": .array(a.map { .number($0) }),
                    "b": .array([.number(0), .number(0), .number(0), .number(0)]),
                ]))
            }
        }
        // Sphere projection was a separate legacy system; it is a warp op
        // now (Invariant 6 — one sphere system).
        if case .bool(true)? = tree["sphereProjectionEnabled"] {
            stack.append(.object([
                "kind": .number(Double(sphereProjectKind)),
                "flags": .number(0),
                "strength": .number(number("sphereProjectionBlend") ?? 1),
                "a": .array([
                    .number(number("sphereProjectionRadius") ?? 1),
                    .number(0), .number(0), .number(0),
                ]),
                "b": .array([.number(0), .number(0), .number(0), .number(0)]),
            ]))
        }
        if !stack.isEmpty {
            tree["warpStack"] = .array(stack)
        }

        if !params.isEmpty {
            tree["params"] = .object(params)
        }
        // Codec bumps `version` to 1 after this step.
    }
}
