// LegacyBindingMigration.swift — version 0 → 1 for .threshmp: the ORIGINAL
// app's audioReactiveConfig.musicReactiveMappings into rebuild Bindings
// (plan §7.3; corpus in Corpus/legacy/maps/).
//
// Mapped where a rebuild target exists:
//   source  bass/mid/treble → audio.band.*, composite → audio.rms,
//           beat → audio.onset
//   target  saturation → color.saturation, iterations → engine.iterations,
//           fractalScale → de.legacyMandelbox.scale (a mandelbox-only field in
//           the original)
//   amount  → Binding.scale;  disabled mappings are dropped (UI state)
//
// Unmapped targets (colorMix, fog, hueSpeed, glow, bloom — post effects the
// rebuild has not grown yet; formulaParamN — fractal-type-relative with no
// type recorded in the file) ride through in `unknown` with the whole raw
// audioReactiveConfig. Migrations never delete.
//
// The legacy response curves (drift/sinusoidal/pulse/hybrid) were TEMPORAL
// behaviors (LFOs, decays), not static transfer curves — the rebuild's
// music-lane smoothing/decay owns that job now (plan §3.2), so curves map
// to their closest static shape.

import Foundation

public enum LegacyBindingMap {
    /// True when a version-less JSON tree looks like an original-app map.
    static func isLegacyTree(_ tree: [String: JSONValue]) -> Bool {
        tree["version"] == nil && tree["audioReactiveConfig"] != nil
    }

    static let sourceMap: [String: SignalID] = [
        "bass": .audioBandLow,
        "mid": .audioBandMid,
        "treble": .audioBandHigh,
        "composite": .audioRMS,
        "beat": .audioOnset,
    ]

    static let targetMap: [String: ParamKey] = [
        "saturation": .colorSaturation,
        "iterations": .engineIterations,
        "fractalScale": .de("legacyMandelbox", "scale"),
    ]

    static func curve(_ name: String?) -> MappingCurve {
        switch name {
        case "pulse": return .pulse(threshold: 0.5)
        case "hybrid": return .linear
        default: return .smooth  // drift, sinusoidal
        }
    }

    /// The 0 → 1 migration step.
    public static let migration = SceneMigration(fromVersion: 0) { tree in
        guard case .object(let config)? = tree["audioReactiveConfig"],
              case .array(let mappings)? = config["musicReactiveMappings"]
        else { return }

        var bindings: [Binding] = []
        for value in mappings {
            guard case .object(let m) = value else { continue }
            if case .bool(false)? = m["isEnabled"] { continue }
            guard case .string(let source)? = m["source"],
                  case .string(let target)? = m["target"],
                  let signal = sourceMap[source],
                  let param = targetMap[target]
            else { continue }

            var amount: Float = 1
            if case .number(let a)? = m["amount"], a.isFinite { amount = Float(a) }
            var curveName: String?
            if case .string(let c)? = m["responseCurve"] { curveName = c }
            // Legacy ids carry over so re-migration is deterministic and the
            // binding's identity survives a round-trip.
            var id = UUID()
            if case .string(let raw)? = m["id"], let parsed = UUID(uuidString: raw) {
                id = parsed
            }

            bindings.append(Binding(
                id: id,
                signal: signal,
                param: param,
                lane: .music,
                mapping: SignalMapping(
                    inputLo: 0, inputHi: 1, outputLo: 0, outputHi: 1,
                    curve: curve(curveName), deadzone: 0.02),
                policy: .momentary,
                scale: amount))
        }

        // Route through Binding's OWN Codable — hand-building its JSON here
        // would silently drift from the model.
        if let data = try? JSONEncoder().encode(bindings),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            tree["bindings"] = json
        }
    }
}
