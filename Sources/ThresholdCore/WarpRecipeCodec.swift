// WarpRecipeCodec.swift — the .threshfx document model + codec (plan §7.4:
// warp-stack recipes are a sub-envelope of the scene format). The contract
// matches the other document codecs: versioned decode, unknown top-level key
// preservation, deterministic encoding, and the shared SceneCodecError
// vocabulary.

import Foundation

// MARK: - WarpRecipeEnvelope

/// A shareable `.threshfx` warp-stack recipe.
public struct WarpRecipeEnvelope: Sendable, Equatable {
    public var version: Int
    public var name: String?
    public var warpStack: [WarpOpDTO]
    /// Foreign top-level keys, preserved verbatim for forward compatibility.
    public var unknown: [String: JSONValue]

    public init(
        version: Int = WarpRecipeCodec.currentVersion,
        name: String? = nil,
        warpStack: [WarpOpDTO],
        unknown: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.name = name
        self.warpStack = warpStack
        self.unknown = unknown
    }
}

extension WarpRecipeEnvelope: Codable {
    private static let knownKeys: Set<String> = ["version", "name", "warpStack"]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(value) }

        guard let version = try c.decodeIfPresent(Int.self, forKey: key("version")) else {
            throw DecodingError.keyNotFound(
                key("version"),
                .init(
                    codingPath: c.codingPath,
                    debugDescription: "warp recipe missing version"))
        }
        self.version = version
        name = try c.decodeIfPresent(String.self, forKey: key("name"))
        // Required even when intentionally empty. Treating a misspelled or
        // omitted key as [] would turn a malformed import into a destructive
        // "clear the current stack" recipe.
        warpStack = try c.decode([WarpOpDTO].self, forKey: key("warpStack"))

        var unknown: [String: JSONValue] = [:]
        for k in c.allKeys where !Self.knownKeys.contains(k.stringValue) {
            unknown[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        self.unknown = unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(value) }

        try c.encode(version, forKey: key("version"))
        try c.encodeIfPresent(name, forKey: key("name"))
        try c.encode(warpStack, forKey: key("warpStack"))
        for (k, v) in unknown where !Self.knownKeys.contains(k) {
            try c.encode(v, forKey: key(k))
        }
    }
}

// MARK: - WarpRecipeCodec

public enum WarpRecipeCodec {
    /// Current `.threshfx` format version.
    public static let currentVersion = 1

    /// Ordered production migration table. Append-only as the format evolves.
    public static let migrations: [SceneMigration] = []

    /// Deterministic, human-readable bytes for shareable recipe documents.
    public static func encode(_ envelope: WarpRecipeEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    /// Decode after walking any registered format migrations.
    public static func decode(
        _ data: Data,
        migrations: [SceneMigration] = WarpRecipeCodec.migrations
    ) throws -> WarpRecipeEnvelope {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw SceneCodecError.malformed("not valid JSON: \(error)")
        }
        guard case .object(var tree) = root else {
            throw SceneCodecError.malformed("warp recipe root is not an object")
        }
        guard case .number(let rawVersion)? = tree["version"] else {
            throw SceneCodecError.malformed("warp recipe missing numeric version")
        }

        let integralVersion = rawVersion.rounded(.towardZero)
        guard rawVersion.isFinite,
              rawVersion == integralVersion,
              let version0 = Int(exactly: integralVersion),
              version0 >= 0
        else {
            throw SceneCodecError.malformed(
                "warp recipe version \(rawVersion) is not a valid version number")
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
            throw SceneCodecError.malformed("warp recipe tree not re-encodable after migration")
        }
        do {
            return try JSONDecoder().decode(WarpRecipeEnvelope.self, from: migrated)
        } catch {
            throw SceneCodecError.malformed(String(describing: error))
        }
    }
}
