// Palette.swift — the gradient palette data model (plan §5.5 stage 2).
//
// A palette is SCENE CONTENT, the same tier as the warp stack: authored in the
// gradient editor, persisted in the scene envelope, and pushed to the GPU as
// its own buffer (ThreshPalette in the ABI). It is NOT a set of loose catalog
// scalars — the repeat / offset / smoothing / mapping knobs around it ARE
// catalog scalars (see the `color.*` engine slots), but the STOPS are content.
//
// Colors are LINEAR rgb (the kernel outputs linear; sRGB encode is the
// harness's job). Stops are kept sorted by position; up to 8 (ABI cap).

import Foundation

// MARK: - ColorMapMode

/// How the palette coordinate `t ∈ [0,1]` is derived per pixel. Raw values
/// MUST match `ThreshColorMapMode` in the ABI header — they persist in scenes.
public enum ColorMapMode: Int, Sendable, Codable, Hashable, CaseIterable {
    case orbitTrap = 0
    case depth = 1
    case normal = 2
    case blend = 3

    public var label: String {
        switch self {
        case .orbitTrap: return "Orbit Trap"
        case .depth: return "Depth"
        case .normal: return "Normal"
        case .blend: return "Blend"
        }
    }
}

// MARK: - GradientStop

/// One gradient stop: a linear-rgb color at a normalized position.
public struct GradientStop: Sendable, Equatable, Codable, Hashable {
    /// Position along the gradient, 0…1.
    public var position: Float
    /// Linear rgb, each 0…1.
    public var red: Float
    public var green: Float
    public var blue: Float

    public init(position: Float, red: Float, green: Float, blue: Float) {
        self.position = position
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(position: Float, rgb: (Float, Float, Float)) {
        self.init(position: position, red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

// MARK: - Palette

/// An ordered set of 1…8 gradient stops. Construction sanitizes: non-finite
/// components are dropped/clamped, positions clamped to 0…1, stops sorted by
/// position, and the list truncated to the ABI stop cap. An empty input yields
/// the single-stop mid-gray identity so the GPU always has ≥ 1 stop.
public struct Palette: Sendable, Equatable, Codable, Hashable {
    /// Maximum stops the GPU buffer holds (mirrors THRESH_MAX_GRADIENT_STOPS).
    public static let maxStops = 8

    public private(set) var stops: [GradientStop]

    public init(stops: [GradientStop]) {
        self.stops = Palette.sanitized(stops)
    }

    /// Replace the stops, re-sanitizing (sort/clamp/cap).
    public mutating func setStops(_ newStops: [GradientStop]) {
        stops = Palette.sanitized(newStops)
    }

    private static func sanitized(_ input: [GradientStop]) -> [GradientStop] {
        func clamp01(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }
        let cleaned = input.map {
            GradientStop(
                position: clamp01($0.position),
                red: clamp01($0.red), green: clamp01($0.green), blue: clamp01($0.blue))
        }
        // Stable sort by position; keep insertion order among equal positions.
        let sorted = cleaned.enumerated()
            .sorted { $0.element.position != $1.element.position
                ? $0.element.position < $1.element.position
                : $0.offset < $1.offset }
            .map(\.element)
        let capped = Array(sorted.prefix(maxStops))
        return capped.isEmpty
            ? [GradientStop(position: 0.5, red: 0.5, green: 0.5, blue: 0.5)]
            : capped
    }
}
