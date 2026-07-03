// BindingCodec.swift — the .threshmp document model + codec (plan §7.4:
// binding maps are a sub-envelope; loaders share one code path). Same
// contract as SceneCodec/AnimationCodec: versioned, migration-table decode,
// unknown top-level keys preserved verbatim, deterministic encode, shared
// error vocabulary.

import Foundation

// MARK: - BindingMapEnvelope

/// The .threshmp file: a set of signal→param bindings plus format plumbing.
public struct BindingMapEnvelope: Sendable, Equatable {
    public var version: Int
    public var bindings: [Binding]
    /// Foreign top-level keys, preserved verbatim (forward compatibility;
    /// for legacy files this carries the whole audioReactiveConfig).
    public var unknown: [String: JSONValue]

    public init(version: Int = BindingCodec.currentVersion,
                bindings: [Binding],
                unknown: [String: JSONValue] = [:]) {
        self.version = version
        self.bindings = bindings
        self.unknown = unknown
    }
}

extension BindingMapEnvelope: Codable {
    private static let knownKeys: Set<String> = ["version", "bindings"]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ s: String) -> DynamicCodingKey { DynamicCodingKey(s) }

        guard let version = try c.decodeIfPresent(Int.self, forKey: key("version")) else {
            throw DecodingError.keyNotFound(
                key("version"),
                .init(codingPath: c.codingPath,
                      debugDescription: "binding map missing version"))
        }
        self.version = version
        bindings = try c.decodeIfPresent([Binding].self, forKey: key("bindings")) ?? []

        var unknown: [String: JSONValue] = [:]
        for k in c.allKeys where !Self.knownKeys.contains(k.stringValue) {
            unknown[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        self.unknown = unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ s: String) -> DynamicCodingKey { DynamicCodingKey(s) }
        try c.encode(version, forKey: key("version"))
        try c.encode(bindings, forKey: key("bindings"))
        for (k, v) in unknown {
            try c.encode(v, forKey: key(k))
        }
    }
}

// MARK: - BindingCodec

public enum BindingCodec {
    /// Current .threshmp format version.
    public static let currentVersion = 1

    /// Ordered production migration table. Append-only.
    public static let migrations: [SceneMigration] = [LegacyBindingMap.migration]

    /// Deterministic bytes: pretty-printed, sorted keys.
    public static func encode(_ envelope: BindingMapEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    /// Decode with migration — the same walk SceneCodec does.
    public static func decode(
        _ data: Data,
        migrations: [SceneMigration] = BindingCodec.migrations
    ) throws -> BindingMapEnvelope {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw SceneCodecError.malformed("not valid JSON: \(error)")
        }
        guard case .object(var tree) = root else {
            throw SceneCodecError.malformed("binding map root is not an object")
        }
        // Version-less trees with an audioReactiveConfig are original-app
        // files — that signature is version 0 (same convention as scenes).
        if tree["version"] == nil, LegacyBindingMap.isLegacyTree(tree) {
            tree["version"] = .number(0)
        }
        guard case .number(let rawVersion)? = tree["version"] else {
            throw SceneCodecError.malformed("binding map missing numeric version")
        }
        guard rawVersion.isFinite,
              let version0 = Int(exactly: rawVersion.rounded(.towardZero)),
              version0 >= 0
        else {
            throw SceneCodecError.malformed(
                "binding map version \(rawVersion) is not a valid version number")
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

        guard let migrated = try? JSONEncoder().encode(JSONValue.object(tree)) else {
            throw SceneCodecError.malformed("binding map tree not re-encodable after migration")
        }
        do {
            return try JSONDecoder().decode(BindingMapEnvelope.self, from: migrated)
        } catch let error as DecodingError {
            throw SceneCodecError.malformed(String(describing: error))
        }
    }
}
