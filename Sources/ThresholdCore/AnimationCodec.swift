// AnimationCodec.swift — the .threshanim document model + codec (plan §7.4:
// "each is a sub-envelope of the scene format, so loaders share one code
// path"). Same contract as SceneCodec: versioned, migration-table decode,
// unknown top-level keys preserved verbatim, deterministic pretty/sorted
// encode, and shared error vocabulary (SceneCodecError).

import Foundation

// MARK: - AnimationEnvelope

/// The .threshanim file: an AnimationClip plus format plumbing.
public struct AnimationEnvelope: Sendable, Equatable {
    public var version: Int
    public var clip: AnimationClip
    /// Foreign top-level keys, preserved verbatim (forward compatibility).
    public var unknown: [String: JSONValue]

    public init(version: Int = AnimationCodec.currentVersion,
                clip: AnimationClip,
                unknown: [String: JSONValue] = [:]) {
        self.version = version
        self.clip = clip
        self.unknown = unknown
    }
}

extension AnimationEnvelope: Codable {
    /// Known top-level keys. Anything else is preserved in `unknown`.
    private static let knownKeys: Set<String> = [
        "version", "name", "loop", "duration", "tracks",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ s: String) -> DynamicCodingKey { DynamicCodingKey(s) }

        guard let version = try c.decodeIfPresent(Int.self, forKey: key("version")) else {
            throw DecodingError.keyNotFound(
                key("version"),
                .init(codingPath: c.codingPath,
                      debugDescription: "animation envelope missing version"))
        }
        self.version = version
        // The clip's fields live flat at the top level — a .threshanim IS a
        // clip document, not a wrapper around one.
        let name = try c.decodeIfPresent(String.self, forKey: key("name"))
        let loop = (try? c.decodeIfPresent(LoopMode.self, forKey: key("loop"))) ?? .once
        let duration = try c.decodeIfPresent(Double.self, forKey: key("duration"))
        let tracks = try c.decodeIfPresent([AnimationTrack].self, forKey: key("tracks")) ?? []
        clip = AnimationClip(name: name, loop: loop, duration: duration, tracks: tracks)

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
        try c.encodeIfPresent(clip.name, forKey: key("name"))
        try c.encode(clip.loop, forKey: key("loop"))
        try c.encodeIfPresent(clip.duration, forKey: key("duration"))
        try c.encode(clip.tracks, forKey: key("tracks"))

        for (k, v) in unknown where !Self.knownKeys.contains(k) {
            try c.encode(v, forKey: key(k))
        }
    }
}

// MARK: - AnimationCodec

public enum AnimationCodec {
    /// Current .threshanim format version.
    public static let currentVersion = 1

    /// Ordered production migration table (same machinery as scenes,
    /// plan §7.3). Append-only.
    public static let migrations: [SceneMigration] = []

    /// Deterministic bytes: pretty-printed, sorted keys — animations are
    /// user-shareable documents and should diff cleanly.
    public static func encode(_ envelope: AnimationEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    /// Decode with migration — the same walk SceneCodec does, including the
    /// corrupt-version and re-encode guards ("never trust-and-crash").
    public static func decode(
        _ data: Data,
        migrations: [SceneMigration] = AnimationCodec.migrations
    ) throws -> AnimationEnvelope {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw SceneCodecError.malformed("not valid JSON: \(error)")
        }
        guard case .object(var tree) = root else {
            throw SceneCodecError.malformed("animation root is not an object")
        }
        guard case .number(let rawVersion)? = tree["version"] else {
            throw SceneCodecError.malformed("animation envelope missing numeric version")
        }
        guard rawVersion.isFinite,
              let version0 = Int(exactly: rawVersion.rounded(.towardZero)),
              version0 >= 0
        else {
            throw SceneCodecError.malformed(
                "animation version \(rawVersion) is not a valid version number")
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
            throw SceneCodecError.malformed("animation tree not re-encodable after migration")
        }
        do {
            return try JSONDecoder().decode(AnimationEnvelope.self, from: migrated)
        } catch let error as DecodingError {
            throw SceneCodecError.malformed(String(describing: error))
        }
    }
}
