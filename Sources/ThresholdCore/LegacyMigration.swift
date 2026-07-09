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
//   fractalScale / foldingLimit / sphereRadius / minDistance → de.mandelbox.*
//   scale × detailScale → scale.zoom integrator phase (octaves)
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

import Foundation
import simd

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
        func formulaNumber(_ values: [JSONValue], _ index: Int) -> Double? {
            guard values.count > index, case .number(let n) = values[index] else { return nil }
            return n
        }
        func legacyMandelboxScale(fractalScale: Double?, minDistance: Double?) -> Double? {
            guard let fractalScale, fractalScale.isFinite else { return nil }
            guard let minDistance, minDistance.isFinite, abs(minDistance) > 1e-9 else {
                return fractalScale
            }
            return fractalScale / minDistance
        }
        func writeLegacyMandelboxShape(
            key: String,
            minDistance: Double?,
            foldingLimit: Double?,
            sphereRadius: Double?,
            fractalScale: Double?
        ) {
            if let scale = legacyMandelboxScale(
                fractalScale: fractalScale, minDistance: minDistance) {
                params["de.\(key).scale"] = .array([.number(scale)])
            }
            if let foldingLimit {
                params["de.\(key).foldLimit"] = .array([.number(foldingLimit)])
            }
            if let sphereRadius {
                params["de.\(key).minRadius"] = .array([.number(sphereRadius)])
            }
            // The original Mandelbox fold used a one-radius outer fold:
            // t = clamp(1 / max(r2, sphereRadius^2), 1, 1 / sphereRadius^2).
            params["de.\(key).fixedRadius"] = .array([.number(1.0)])
        }

        // --- identity ----------------------------------------------------
        // The rebuild now has a dedicated `mandelboxSphereProjection` DE (the
        // projection baked into the formula), so the legacy type name maps
        // straight through instead of folding into base mandelbox + warp op.
        if case .string(let type)? = tree["fractalType"] {
            tree["fractalTypeKey"] = .string(type)
        }
        // `name` carries over verbatim (same key both formats).

        // --- camera ------------------------------------------------------
        // The original moved the MODEL, not the camera: world transform
        // T(position)·R(worldRotation)·S(scale·detailScale) on the fractal,
        // with the view camera at (0,0,3) looking −Z. The rebuild keeps the
        // fractal at the origin, so the equivalent camera pose is the INVERSE:
        // position′ = R⁻¹·(camera−position), orientation′ = R⁻¹. The scale part
        // cancels out of the camera because zoom rescales MODEL space
        // (mapScene), leaving world distances — and the camera — untouched.
        var legacyPosition = SIMD3<Double>(0, 0, -3)
        if case .array(let p)? = tree["position"], p.count == 3,
           case .number(let px) = p[0], case .number(let py) = p[1],
           case .number(let pz) = p[2] {
            legacyPosition = SIMD3(px, py, pz)
        }
        // R⁻¹ = conjugate of the (normalized) legacy world rotation.
        var q = SIMD4<Double>(
            number("worldRotationX") ?? 0, number("worldRotationY") ?? 0,
            number("worldRotationZ") ?? 0, number("worldRotationW") ?? 1)
        let qLen = (q * q).sum().squareRoot()
        q = qLen > 1e-9 ? q / qLen : SIMD4(0, 0, 0, 1)
        let inv = SIMD4(-q.x, -q.y, -q.z, q.w)
        // v′ = v + 2·(inv.xyz × (inv.xyz × v + inv.w·v))
        let legacyCamera = SIMD3<Double>(0, 0, 3)
        let v = legacyCamera - legacyPosition
        let im = SIMD3(inv.x, inv.y, inv.z)
        let cameraPosition = v + 2 * simd_cross(im, simd_cross(im, v) + inv.w * v)
        tree["camera"] = .object([
            "position": .array(cameraPosition.indices.map { .number(cameraPosition[$0]) }),
            "orientation": .array([
                .number(inv.x), .number(inv.y), .number(inv.z), .number(inv.w),
            ]),
            "fovYRadians": .number(Double.pi / 3),
        ])

        // --- formula params (per-type, only where the rebuild DE exists) --
        // kleinian's declared layout deliberately matches the original's
        // formulaParamValues[0...7] (DERegistry.kleinian) so this is a
        // positional copy. Other types map as their DEs land; unmapped
        // formulaParamValues stay preserved in `unknown`.
        if case .string("kleinian")? = tree["fractalType"],
           case .array(let formula)? = tree["formulaParamValues"], formula.count >= 8 {
            let names = ["minX", "minY", "minZ", "sphereFold",
                         "maxX", "maxY", "maxZ", "crossRadius"]
            for (i, name) in names.enumerated() {
                if case .number(let n) = formula[i] {
                    params["de.kleinian.\(name)"] = .array([.number(n)])
                }
            }
        }

        // --- embedded formulas (fractalType "custom") -----------------------
        // The original's user-authored DEs, adapted verbatim onto the
        // rebuild's external-DE pipeline: shim prelude + untouched
        // metalSource + generated de_main (LegacyFormulaShim). No declared
        // hash — the loader computes one for cache identity. The raw
        // embeddedFormula stays in the tree (never delete).
        if case .string("custom")? = tree["fractalType"],
           case .object(let formula)? = tree["embeddedFormula"],
           case .string(let metalSource)? = formula["metalSource"],
           case .string(let stem)? = formula["functionStem"] {
            var declared: [(index: Int, param: JSONValue)] = []
            if case .array(let rawParams)? = formula["params"] {
                for value in rawParams {
                    guard case .object(let p) = value,
                          case .string(let name)? = p["name"],
                          case .number(let def)? = p["default"],
                          case .number(let lo)? = p["min"],
                          case .number(let hi)? = p["max"]
                    else { continue }
                    var index = declared.count
                    if case .number(let i)? = p["index"], let exact = Int(exactly: i.rounded()) {
                        index = exact
                    }
                    declared.append((index, .object([
                        "name": .string(name),
                        "defaultValue": .number(def),
                        "min": .number(lo),
                        "max": .number(hi),
                    ])))
                }
            }
            declared.sort { $0.index < $1.index }  // GPU slice order
            let source = LegacyFormulaShim.adapt(
                metalSource: metalSource, stem: stem, declaredParams: declared.count)
            tree["embeddedDE"] = .object([
                "source": .string(source),
                "abiVersion": .number(Double(EmbeddedDE.currentABIVersion)),
                "hash": .string(""),
                "params": .array(declared.map(\.param)),
            ])
            if case .number(let iters)? = formula["defaultIterations"],
               params[ParamKey.engineIterations.rawValue] == nil {
                params[ParamKey.engineIterations.rawValue] = .array([.number(iters)])
            }
        }

        // --- mandelbox DE params -------------------------------------------
        // The original optimized Mandelbox path precomputed scale as
        // `fractalScale / minDistance`, while the sphere fold used
        // `sphereRadius` as the inner radius and hardcoded the outer radius to
        // 1. Preserve that shape rather than treating `minDistance` as the
        // sphere-fold radius; scenes like Spiky and Paul are very sensitive to
        // this distinction.
        //
        // Some saved "mandelbox" scenes also have the legacy sphere-projection
        // toggle enabled (Paul/Pulsing is the canonical example). The rebuild
        // has a dedicated projected Mandelbox DE for that look, so promote
        // those files and store the projection controls on the DE itself.
        if case .string("mandelbox")? = tree["fractalType"] {
            let key = (tree["sphereProjectionEnabled"] == .bool(true))
                ? "mandelboxSphereProjection" : "mandelbox"
            if key == "mandelboxSphereProjection" {
                tree["fractalTypeKey"] = .string(key)
            }
            writeLegacyMandelboxShape(
                key: key,
                minDistance: number("minDistance"),
                foldingLimit: number("foldingLimit"),
                sphereRadius: number("sphereRadius"),
                fractalScale: number("fractalScale"))
            if key == "mandelboxSphereProjection" {
                if let blend = number("sphereProjectionBlend") {
                    params["de.\(key).projBlend"] = .array([.number(blend)])
                }
                if let radius = number("sphereProjectionRadius") {
                    params["de.\(key).projRadius"] = .array([.number(radius)])
                }
            }
        }

        // --- mandelboxSphereProjection DE params ---------------------------
        // Legacy dedicated MSP scenes stored their authored Mandelbox shape in
        // formulaParamValues[0...3]:
        // [minDistance, foldingLimit, sphereRadius, fractalScale]. The
        // top-level geometry fields remained at defaults in many saved files.
        // Projection blend/radius are formulaParamValues[4]/[5].
        if case .string("mandelboxSphereProjection")? = tree["fractalType"] {
            let key = "mandelboxSphereProjection"
            if case .array(let formula)? = tree["formulaParamValues"], formula.count >= 6 {
                writeLegacyMandelboxShape(
                    key: key,
                    minDistance: formulaNumber(formula, 0),
                    foldingLimit: formulaNumber(formula, 1),
                    sphereRadius: formulaNumber(formula, 2),
                    fractalScale: formulaNumber(formula, 3))
                if let blend = formulaNumber(formula, 4) {
                    params["de.\(key).projBlend"] = .array([.number(blend)])
                }
                if let radius = formulaNumber(formula, 5) {
                    params["de.\(key).projRadius"] = .array([.number(radius)])
                }
            } else {
                writeLegacyMandelboxShape(
                    key: key,
                    minDistance: number("minDistance"),
                    foldingLimit: number("foldingLimit"),
                    sphereRadius: number("sphereRadius"),
                    fractalScale: number("fractalScale"))
            }
        }

        // --- safety bubble (legacy "safe space") ---------------------------
        // The shipping app carved a shape out of the fractal around the camera
        // so scenes could never bury the viewer — and, crucially, the escape
        // hatch for the mandelboxSphereProjection family whose r→0 singularity
        // otherwise fills the frame. The scene persisted enabled/radius/shape
        // and `safetyBubbleBlend` (the strength slider); fade width/enabled were
        // device-local app defaults and are baked into the shader. Only migrate
        // when the scene actually turned it on, so nothing else is disturbed.
        if case .bool(true)? = tree["safetyBubbleEnabled"] {
            params[ParamKey.engineBubbleEnabled.rawValue] = .array([.number(1)])
            if let r = number("safetyBubbleRadius") {
                params[ParamKey.engineBubbleRadius.rawValue] = .array([.number(r)])
            }
            if let s = number("safetyBubbleShape") {
                params[ParamKey.engineBubbleShape.rawValue] = .array([.number(s)])
            }
            // `safetyBubbleBlend` → strength; default matches SafetyBubbleConfig.
            params[ParamKey.engineBubbleBlend.rawValue] =
                .array([.number(number("safetyBubbleBlend") ?? 0.25)])
        }

        // --- zoom (plan §6.3) ----------------------------------------------
        // The original scaled the model matrix by `scale × detailScale`
        // (RaymarchRenderView's effectiveScale); the rebuild's zoom is the
        // scale.zoom integrator phase in octaves. Written into
        // integratorPhases — a params write would be overridden by the
        // engine's integrator post-pass (Invariant 17).
        let magnification = (number("scale") ?? 1) * (number("detailScale") ?? 1)
        if magnification > 0, magnification.isFinite, magnification != 1 {
            tree["integratorPhases"] = .object([
                ParamKey.scaleZoom.rawValue: .number(log2(magnification)),
            ])
        }

        // --- engine + grading scalars -------------------------------------
        copyParam("fractalIterations", to: .engineIterations)
        copyParam("maxRaySteps", to: .engineMaxSteps)
        copyParam("aoStrength", to: .engineAOStrength)
        copyParam("colorSchemeSaturation", to: .colorSaturation)
        copyParam("colorSchemeContrast", to: .colorContrast)
        copyParam("colorSchemeVibrance", to: .colorVibrance)
        copyParam("colorSchemeGamma", to: .colorGamma)
        copyParam("tonemapStrength", to: .colorTonemap)

        // --- atmosphere effects (legacy Effects ▸ Static) -----------------
        if case .object(let glow)? = tree["glowEffect"],
           case .bool(true)? = glow["enabled"] {
            params[ParamKey.atmosphereGlowEnabled.rawValue] = .array([.number(1)])
            if case .number(let n)? = glow["intensity"] {
                params[ParamKey.atmosphereGlowIntensity.rawValue] = .array([.number(n)])
            }
        }
        if case .object(let bloom)? = tree["bloomEffect"],
           case .bool(true)? = bloom["enabled"] {
            params[ParamKey.atmosphereBloomEnabled.rawValue] = .array([.number(1)])
            if case .number(let n)? = bloom["strength"] {
                params[ParamKey.atmosphereBloomStrength.rawValue] = .array([.number(n)])
            }
        }
        if case .object(let fog)? = tree["fogEffect"],
           case .bool(true)? = fog["enabled"] {
            params[ParamKey.atmosphereFogEnabled.rawValue] = .array([.number(1)])
            if case .number(let n)? = fog["intensity"] {
                params[ParamKey.atmosphereFogIntensity.rawValue] = .array([.number(n)])
            }
            if case .number(let r)? = fog["colorRed"],
               case .number(let g)? = fog["colorGreen"],
               case .number(let b)? = fog["colorBlue"] {
                params[ParamKey.atmosphereFogColor.rawValue] =
                    .array([.number(r), .number(g), .number(b)])
            }
        }

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
                // Legacy raw values were orbit=0, iterations=1, depth=2,
                // angle=3, normal=4, blended=5. Threshold already persisted
                // depth/normal/blend as 1/2/3, so translate rather than copy.
                let mapped: Double
                switch Int(n.rounded()) {
                case 2: mapped = Double(ColorMapMode.depth.rawValue)
                case 3: mapped = Double(ColorMapMode.angle.rawValue)
                case 4: mapped = Double(ColorMapMode.normal.rawValue)
                case 5: mapped = Double(ColorMapMode.blend.rawValue)
                default: mapped = Double(ColorMapMode.orbitTrap.rawValue)
                }
                params[ParamKey.colorMapMode.rawValue] = .array([.number(mapped)])
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
        // Sphere projection was a separate legacy system. Plain Mandelbox
        // projection is promoted above to the dedicated DE; other fractal
        // families still preserve the authored projection as a warp op.
        if case .bool(true)? = tree["sphereProjectionEnabled"],
           tree["fractalTypeKey"] != .string("mandelboxSphereProjection") {
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
