// BindableParams.swift — derives the gesture editor's menu contents from a
// catalog. Pure value logic (no SwiftUI) so it is unit-tested directly and the
// editor stays a thin view over it.
//
// The three lists mirror the two ways a user assigns axes (the core UX the
// custom editor exists for): `vectors` are native `.float3` params bound whole
// (`.native`); `scalars` are individual params for per-axis assignment; and
// `groups` are x/y/z triples auto-detected among the scalars (external scenes'
// flat `Translate.x/.y/.z`) that seed a `.grouped` target in one pick.

public struct BindableParams: Sendable, Equatable {
    /// One assignable parameter, catalog-order preserved.
    public struct Item: Sendable, Equatable, Identifiable {
        public let key: ParamKey
        public let label: String
        public let group: GroupID
        public let kind: ParamKind
        public let range: ClosedRange<Float>

        public var id: ParamKey { key }

        public init(key: ParamKey, label: String, group: GroupID,
                    kind: ParamKind, range: ClosedRange<Float>) {
            self.key = key
            self.label = label
            self.group = group
            self.kind = kind
            self.range = range
        }
    }

    /// Native `.float3` params — bound whole via `Vec3Target.native`.
    public let vectors: [Item]
    /// Scalar `.float` params — assignable per axis or as ad-hoc groups.
    public let scalars: [Item]
    /// x/y/z triples auto-detected among `scalars` (see `Vec3Group.autoDetect`).
    public let groups: [Vec3Group]

    public init(vectors: [Item], scalars: [Item], groups: [Vec3Group]) {
        self.vectors = vectors
        self.scalars = scalars
        self.groups = groups
    }

    /// Derive from catalog entries (pass `layout.entries + dynamicEntries`).
    /// Bools and enums are excluded (a drag has no meaning for a toggle);
    /// `.float4` is excluded for now (the editor is x/y/z-shaped).
    public static func derive(from entries: [CatalogEntry]) -> BindableParams {
        var vectors: [Item] = []
        var scalars: [Item] = []
        for entry in entries {
            let item = Item(
                key: entry.key, label: entry.spec.label, group: entry.spec.group,
                kind: entry.kind, range: entry.spec.range)
            switch entry.kind {
            case .float: scalars.append(item)
            case .float3: vectors.append(item)
            case .bool, .enumeration, .float4: continue
            }
        }
        return BindableParams(
            vectors: vectors,
            scalars: scalars,
            groups: Vec3Group.autoDetect(from: entries))
    }

    /// The item for a key, if bindable (either list).
    public func item(for key: ParamKey) -> Item? {
        vectors.first { $0.key == key } ?? scalars.first { $0.key == key }
    }

    /// The human label for a key (falls back to the key's raw string).
    public func label(for key: ParamKey) -> String {
        item(for: key)?.label ?? key.rawValue
    }
}
