// PostProcessing.swift — scene-owned, ordered post-processing filter data.
//
// This is deliberately a DTO rather than a renderer ABI type. ThresholdCore
// owns persistence and editing semantics; ThresholdRender decides how many GPU
// passes a filter expands into. The raw kind keeps unknown future filters
// round-trippable instead of making one new enum case invalidate a whole scene.

import Foundation

/// Stable on-disk vocabulary for the built-in post-processing filters.
///
/// Raw values are scene-file data: append new cases, never renumber existing
/// ones. `PostProcessFilterDTO.kind` remains a raw `UInt32` so a newer kind can
/// be decoded, reordered, and re-encoded by an older build without data loss.
public enum PostProcessKind: UInt32, CaseIterable, Codable, Sendable {
    case bloom = 1
    case gaussianBlur = 2
    case sharpen = 3
    case vignette = 4
    case chromaticAberration = 5
    case filmGrain = 6
    case colorGrade = 7
    case posterize = 8
    case invert = 9
}

/// One slot in a scene's ordered post-processing stack.
///
/// `id` is stable across edits and reordering, allowing UI identity to follow
/// the filter rather than its current array index. `a` and `b` are fixed-width
/// generic payloads whose meanings are declared by the known kind. Unknown
/// kinds and their payloads survive round trips unchanged.
public struct PostProcessFilterDTO: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// Raw `PostProcessKind` value. Kept raw for unknown-kind preservation.
    public var kind: UInt32
    public var enabled: Bool
    /// Primary wet/intensity control shared by every filter.
    public var strength: Float
    public var a: [Float]
    public var b: [Float]

    public init(
        id: UUID = UUID(),
        kind: UInt32,
        enabled: Bool = true,
        strength: Float,
        a: [Float],
        b: [Float]
    ) {
        precondition(
            a.count == 4 && b.count == 4,
            "PostProcessFilterDTO payloads are exactly 4 components")
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.strength = strength
        self.a = a
        self.b = b
    }

    public init(
        id: UUID = UUID(),
        kind: PostProcessKind,
        enabled: Bool = true,
        strength: Float,
        a: [Float],
        b: [Float]
    ) {
        self.init(
            id: id, kind: kind.rawValue, enabled: enabled,
            strength: strength, a: a, b: b)
    }

    /// The built-in kind, or nil when this DTO came from a newer producer.
    public var knownKind: PostProcessKind? { PostProcessKind(rawValue: kind) }

    /// Construct a useful, visible starting point for a built-in filter.
    ///
    /// Payload conventions:
    /// - bloom:              a = threshold, knee, radius(px), scatter
    /// - gaussianBlur:       a = radius(px), sigma, 0, 0
    /// - sharpen:            a = radius(px), 0, 0, 0
    /// - vignette:           a = inner radius, outer radius, roundness, 0
    /// - chromaticAberration:a = offset(px), angle(rad), 0, 0
    /// - filmGrain:          a = grain size(px), colored(0/1), 0, 0
    /// - colorGrade:         a = saturation, contrast, brightness, gamma
    /// - posterize:          a = levels, 0, 0, 0
    /// - invert:             payload unused
    public static func makeDefault(
        _ kind: PostProcessKind,
        id: UUID = UUID()
    ) -> PostProcessFilterDTO {
        switch kind {
        case .bloom:
            return PostProcessFilterDTO(
                id: id, kind: kind, strength: 0.5,
                a: [1.0, 0.5, 8.0, 0.7], b: [0, 0, 0, 0])
        case .gaussianBlur:
            return PostProcessFilterDTO(
                id: id, kind: kind, strength: 1.0,
                a: [4.0, 2.0, 0, 0], b: [0, 0, 0, 0])
        case .sharpen:
            return PostProcessFilterDTO(
                id: id, kind: kind, strength: 0.5,
                a: [1.0, 0, 0, 0], b: [0, 0, 0, 0])
        case .vignette:
            return PostProcessFilterDTO(
                id: id, kind: kind, strength: 0.5,
                a: [0.35, 0.85, 1.0, 0], b: [0, 0, 0, 0])
        case .chromaticAberration:
            return PostProcessFilterDTO(
                id: id, kind: kind, strength: 0.5,
                a: [2.0, 0, 0, 0], b: [0, 0, 0, 0])
        case .filmGrain:
            return PostProcessFilterDTO(
                id: id, kind: kind, strength: 0.15,
                a: [1.0, 0, 0, 0], b: [0, 0, 0, 0])
        case .colorGrade:
            return PostProcessFilterDTO(
                id: id, kind: kind, strength: 1.0,
                a: [1.0, 1.0, 1.0, 1.0], b: [0, 0, 0, 0])
        case .posterize:
            return PostProcessFilterDTO(
                id: id, kind: kind, strength: 1.0,
                a: [8.0, 0, 0, 0], b: [0, 0, 0, 0])
        case .invert:
            return PostProcessFilterDTO(
                id: id, kind: kind, strength: 1.0,
                a: [0, 0, 0, 0], b: [0, 0, 0, 0])
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(UInt32.self, forKey: .kind)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        strength = try c.decode(Float.self, forKey: .strength)
        a = try c.decode([Float].self, forKey: .a)
        b = try c.decode([Float].self, forKey: .b)
        guard a.count == 4, b.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .a, in: c,
                debugDescription:
                    "post-process filter payloads must have exactly 4 components")
        }
    }
}
