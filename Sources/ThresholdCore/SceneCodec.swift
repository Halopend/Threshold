// SceneCodec.swift — catalog-walk serialization, lane-scoped apply, and the
// migration scaffold (plan §7.1/§7.3, ARCHITECTURE.md §7).
//
// Serialization is a CATALOG WALK: there is no hand-written field list, so a
// param cannot be forgotten (Invariant 1). Apply writes ONLY the scene lane
// (Invariant 11): it cannot clobber user offsets or leak transient state.

import Foundation

// MARK: - Errors

public enum SceneCodecError: Error, Equatable, Sendable {
    case malformed(String)
    /// File written by a NEWER format than this build understands.
    case unsupportedVersion(Int)
    /// No migration registered for this older version — the table has a gap.
    case missingMigration(from: Int)
}

// MARK: - Migrations

/// One migration step: rewrites the raw JSON tree of a version-`fromVersion`
/// file into version `fromVersion + 1` shape. Migrations are DATA + pure
/// functions (plan §7.3), run before typed decoding; the codec bumps the
/// version field itself after each step.
public struct SceneMigration: Sendable {
    public let fromVersion: Int
    public let migrate: @Sendable (inout [String: JSONValue]) -> Void

    public init(fromVersion: Int, migrate: @escaping @Sendable (inout [String: JSONValue]) -> Void) {
        self.fromVersion = fromVersion
        self.migrate = migrate
    }
}

public enum SceneMigrations {
    /// The ordered production migration table. Append-only; unit-tested
    /// against the legacy corpus in Corpus/legacy/ (plan §9).
    public static let table: [SceneMigration] = [
        LegacyScene.migration  // 0 → 1: original-app flat format
    ]
}

// MARK: - Apply report

/// What `apply` did — surfaced to the user as warnings, never as data loss
/// (unknown content stays in the envelope and round-trips).
public struct SceneApplyReport: Sendable, Equatable {
    /// Params written to the scene lane.
    public var appliedCount: Int = 0
    /// Param keys not present in the catalog (preserved in the envelope).
    public var unknownParams: [String] = []
    /// Foreign-shaped param entries (preserved verbatim in the envelope).
    public var foreignParams: [String] = []
    /// Catalog params present in the file but not `.scene`-persisted — scene
    /// files do not own device-local or transient state; skipped by policy.
    public var skippedNonScene: [String] = []
    /// Component-count mismatches (file shape vs catalog kind).
    public var componentMismatches: [String] = []
}

// MARK: - SceneCodec

public enum SceneCodec {
    /// Current .threshscene format version.
    public static let currentVersion = 1

    // MARK: Encode / decode

    /// Deterministic bytes: pretty-printed, sorted keys — scenes are
    /// user-shareable documents and should diff cleanly (ARCHITECTURE.md §7).
    public static func encode(_ envelope: SceneEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    /// Decode with migration: parse the raw tree, walk the migration table
    /// from the file's version up to `currentVersion`, then decode typed.
    public static func decode(
        _ data: Data,
        migrations: [SceneMigration] = SceneMigrations.table
    ) throws -> SceneEnvelope {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw SceneCodecError.malformed("not valid JSON: \(error)")
        }
        guard case .object(var tree) = root else {
            throw SceneCodecError.malformed("scene root is not an object")
        }
        // Original-app files (Corpus/legacy/) have no `version` field — they
        // predate the envelope. A version-less tree bearing the legacy
        // signature is version 0; anything else version-less is malformed.
        if tree["version"] == nil, LegacyScene.isLegacyTree(tree) {
            tree["version"] = .number(0)
        }
        guard case .number(let rawVersion)? = tree["version"] else {
            throw SceneCodecError.malformed("scene envelope missing numeric version")
        }
        // Int(Double) TRAPS out of range; a corrupt {"version": 1e300} must
        // throw, not kill the process ("never trust-and-crash", plan §7.2).
        guard rawVersion.isFinite,
              let version0 = Int(exactly: rawVersion.rounded(.towardZero)),
              version0 >= 0
        else {
            throw SceneCodecError.malformed("scene version \(rawVersion) is not a valid version number")
        }
        var version = version0
        guard version <= currentVersion else {
            throw SceneCodecError.unsupportedVersion(version)
        }

        while version < currentVersion {
            guard let step = migrations.first(where: { $0.fromVersion == version }) else {
                throw SceneCodecError.missingMigration(from: version)
            }
            step.migrate(&tree)
            version += 1
            tree["version"] = .number(Double(version))
        }

        // The writer's nesting limit is stricter than the reader's — a
        // maximally-nested parseable file must map to `malformed`, not leak
        // a raw EncodingError.
        guard let migrated = try? JSONEncoder().encode(JSONValue.object(tree)) else {
            throw SceneCodecError.malformed("scene tree not re-encodable after migration")
        }
        do {
            return try JSONDecoder().decode(SceneEnvelope.self, from: migrated)
        } catch let error as DecodingError {
            throw SceneCodecError.malformed(String(describing: error))
        }
    }

    // MARK: Snapshot (catalog walk)

    /// Capture the current scene-lane state as an envelope. Walks the catalog:
    /// every `.scene`-persisted param is serialized (scene-lane value if set,
    /// else the catalog default — explicit, so files are self-contained);
    /// `.deviceLocal` and `.transient` params are structurally excluded.
    public static func snapshot(
        layout: CatalogLayout,
        engine: ModulationEngine,
        fractalTypeKey: String,
        warpStack: [WarpOpDTO] = [],
        camera: CameraDTO = .default,
        name: String? = nil,
        tags: [String] = [],
        embeddedDE: EmbeddedDE? = nil,
        abiVersion: Int = 1
    ) -> SceneEnvelope {
        var params: [String: [Float]] = [:]
        var phases: [String: Float] = [:]

        // Lane storage is deliberately unclamped and JSONEncoder throws on
        // non-finite floats — sanitize at the persistence boundary so one bad
        // value can never make every save fail (non-finite → spec default).
        for entry in layout.entries where entry.spec.persistence == .scene {
            var components = [Float]()
            components.reserveCapacity(entry.kind.slotWidth)
            for (i, slot) in entry.slotRange.enumerated() {
                let raw = engine.currentValue(lane: .scene, slot: slot) ?? entry.spec.defaultValue[i]
                components.append(raw.isFinite ? raw : entry.spec.defaultValue[i])
            }
            params[entry.key.rawValue] = components
        }

        // Integrator phases snapshot regardless of persistence: a phase param
        // is `.transient` in the params walk precisely BECAUSE this is its
        // persistence channel (Invariant 17; ScaleContext header).
        for entry in layout.entries where entry.spec.integratorRateKey != nil {
            if let phase = engine.readIntegratorPhase(slot: entry.slot), phase.isFinite {
                phases[entry.key.rawValue] = phase
            }
        }

        return SceneEnvelope(
            version: currentVersion,
            abiVersion: abiVersion,
            name: name,
            tags: tags,
            fractalTypeKey: fractalTypeKey,
            embeddedDE: embeddedDE,
            params: params,
            integratorPhases: phases,
            warpStack: warpStack,
            camera: camera
        )
    }

    // MARK: Apply (lane-scoped, authoritative)

    /// Apply an envelope to the engine. Writes ONLY the scene lane
    /// (Invariant 11); user/gesture/music offsets survive untouched.
    ///
    /// Authoritative by default: `.scene` catalog params absent from the file
    /// have their scene-lane value cleared (base falls back to the catalog
    /// default), so stale base state cannot leak between scenes. Pass
    /// `authoritative: false` for overlay-style partial presets.
    ///
    /// Render-thread only (the engine is thread-confined); route through the
    /// command mailbox from elsewhere.
    ///
    /// With a `transition` (ADR-005), continuous params EASE from their
    /// current smoothed values toward the new scene over the transition
    /// window (`ModulationEngine.beginSceneTransition`); discrete and
    /// `.snapOnSceneTransition` params snap immediately, and authoritative
    /// clears ramp to the catalog default before releasing. `nil` (the
    /// default) snaps everything — byte-identical to the pre-transition
    /// behavior, which keeps the harness and goldens deterministic.
    @discardableResult
    public static func apply(
        _ envelope: SceneEnvelope,
        layout: CatalogLayout,
        engine: ModulationEngine,
        authoritative: Bool = true,
        transition: SceneTransition? = nil
    ) -> SceneApplyReport {
        var report = SceneApplyReport()
        report.foreignParams = envelope.foreignParams.keys.sorted()

        // Whether THIS apply tweens. A leftover window from a previous apply
        // must not smear a snap apply — snap writes bypass smoothing anyway,
        // and clears go straight to clearLane.
        let transitioning: Bool
        if let transition, transition.duration > 0, transition.duration.isFinite {
            engine.beginSceneTransition(duration: transition.duration)
            transitioning = true
        } else {
            transitioning = false
        }

        var written = Set<ParamKey>()

        for (keyString, components) in envelope.params {
            let key = ParamKey(keyString)
            guard let entry = layout.entry(for: key) else {
                report.unknownParams.append(keyString)
                continue
            }
            guard entry.spec.persistence == .scene else {
                report.skippedNonScene.append(keyString)
                continue
            }
            guard components.count == entry.kind.slotWidth else {
                report.componentMismatches.append(keyString)
                continue
            }
            engine.write(lane: .scene, key: key, values: components, snap: !transitioning)
            written.insert(key)
            report.appliedCount += 1
        }

        if authoritative {
            for entry in layout.entries
            where entry.spec.persistence == .scene && !written.contains(entry.key) {
                for slot in entry.slotRange {
                    if transitioning {
                        engine.scheduleSceneClear(slot: slot)
                    } else {
                        engine.clearLane(.scene, slot: slot)
                    }
                }
            }
        }

        for (keyString, phase) in envelope.integratorPhases {
            guard let entry = layout.entry(for: ParamKey(keyString)) else { continue }
            engine.setIntegratorPhase(slot: entry.slot, value: phase)
        }

        report.unknownParams.sort()
        report.skippedNonScene.sort()
        report.componentMismatches.sort()
        return report
    }
}
