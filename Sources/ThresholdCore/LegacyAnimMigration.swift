// LegacyAnimMigration.swift — version 0 → 1 for .threshanim: the ORIGINAL
// app's scene-keyframe sequences into the rebuild's per-param tracks
// (plan §7.3; corpus in Corpus/legacy/anims/).
//
// The legacy format animates whole scene states: each keyframe is a flat
// legacy-scene snapshot plus `duration` (seconds of transition INTO that
// keyframe) and an easing. The rebuild animates PARAMS: one AnimationTrack
// per catalog key, absolute mode. This pass extracts the scalars whose
// catalog params exist (same field mappings as LegacyMigration for scenes)
// at cumulative keyframe times; everything else — camera paths, effect
// blocks, detailScale zoom (an integrator phase the animation lane cannot
// address yet) — rides through in `unknown` for a later, higher-fidelity
// pass. Migrations never delete.

import Foundation

public enum LegacyAnimation {
    /// True when a version-less JSON tree looks like an original-app anim.
    static func isLegacyTree(_ tree: [String: JSONValue]) -> Bool {
        tree["version"] == nil && tree["keyframes"] != nil
    }

    /// Legacy easing → rebuild segment interpolation. The legacy easing
    /// describes the transition INTO its keyframe; the rebuild's lives on
    /// the segment's STARTING keyframe — the caller shifts accordingly.
    static func interpolation(_ easing: String?) -> String {
        switch easing {
        case "linear": return "linear"
        case "step", "hold": return "step"
        default: return "smooth"  // bezier and friends
        }
    }

    /// The 0 → 1 migration step.
    public static let migration = SceneMigration(fromVersion: 0) { tree in
        guard case .array(let rawKeyframes)? = tree["keyframes"] else { return }

        // --- decode the keyframe sequence: cumulative times + easings -----
        struct LegacyKey {
            let time: Double
            let easing: String?
            let fields: [String: JSONValue]
        }
        var keys: [LegacyKey] = []
        var cursor = 0.0
        for value in rawKeyframes {
            guard case .object(let kf) = value else { continue }
            if case .number(let d)? = kf["duration"], d.isFinite, d >= 0 {
                cursor += d
            }
            var easing: String?
            if case .string(let e)? = kf["easingType"] { easing = e }
            keys.append(LegacyKey(time: cursor, easing: easing, fields: kf))
        }
        guard !keys.isEmpty else { return }

        // --- per-keyframe scalar extraction (shared with LegacyMigration) --
        var fractalType = ""
        if case .string(let t)? = tree["fractalType"] { fractalType = t }
        let isMandelbox = fractalType == "mandelbox"
            || fractalType == "mandelboxSphereProjection"

        func scalar(_ kf: [String: JSONValue], _ key: String) -> Double? {
            if case .number(let n)? = kf[key] { return n }
            return nil
        }
        // ParamKey → per-keyframe value extractor. nil = key absent in that
        // keyframe (the whole track is dropped unless EVERY keyframe has it —
        // a torn track would interpolate against garbage).
        var extractors: [(ParamKey, ([String: JSONValue]) -> Double?)] = [
            (.engineIterations, { scalar($0, "baseFractalIterations") }),
            (.engineMaxSteps, { scalar($0, "baseMaxRaySteps") }),
        ]
        if isMandelbox {
            let key = fractalType == "mandelbox" ? "legacyMandelbox" : "mandelbox"
            if fractalType == "mandelbox" {
                extractors += [
                    (.de(key, "scale"), { scalar($0, "fractalScale") }),
                    (.de(key, "minDistance"), { scalar($0, "minDistance") }),
                    (.de(key, "sphereRadius"), { scalar($0, "sphereRadius") }),
                    (.de(key, "foldLimit"), { scalar($0, "foldingLimit") }),
                ]
            } else {
                extractors += [
                    (.de(key, "scale"), { scalar($0, "fractalScale") }),
                    (.de(key, "foldLimit"), { scalar($0, "foldingLimit") }),
                    (.de(key, "minRadius"), { scalar($0, "sphereRadius") }),
                    (.de(key, "fixedRadius"), { _ in 1.0 }),
                ]
            }
        }
        if fractalType == "kleinian" {
            let names = ["minX", "minY", "minZ", "sphereFold",
                         "maxX", "maxY", "maxZ", "crossRadius"]
            for (i, name) in names.enumerated() {
                extractors.append((.de("kleinian", name), { kf in
                    guard case .array(let formula)? = kf["formulaParamValues"],
                          formula.count > i, case .number(let n) = formula[i]
                    else { return nil }
                    return n
                }))
            }
        }

        // --- build tracks ---------------------------------------------------
        var tracks: [JSONValue] = []
        for (param, extract) in extractors {
            let values = keys.map { extract($0.fields) }
            guard values.allSatisfy({ $0 != nil }) else { continue }
            let keyframes: [JSONValue] = keys.indices.map { i in
                // Segment interpolation comes from the NEXT legacy keyframe's
                // easing (it described the transition into that keyframe).
                let easing = i + 1 < keys.count ? keys[i + 1].easing : nil
                return .object([
                    "time": .number(keys[i].time),
                    "values": .array([.number(values[i]!)]),
                    "interpolation": .string(interpolation(easing)),
                ])
            }
            tracks.append(.object([
                "param": .string(param.rawValue),
                "mode": .string("absolute"),
                "keyframes": .array(keyframes),
            ]))
        }

        tree["tracks"] = .array(tracks)
        tree["duration"] = .number(keys.last!.time)
        if case .bool(let looping)? = tree["isLooping"] {
            tree["loop"] = .string(looping ? "loop" : "once")
        }
        // No display name in the legacy format; the filename is the name at
        // the open site. `keyframes` and every other legacy key stay in the
        // tree → preserved in AnimationEnvelope.unknown.
    }
}
