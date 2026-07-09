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
    case angle = 4

    public var label: String {
        switch self {
        case .orbitTrap: return "Orbit Trap"
        case .depth: return "Depth"
        case .normal: return "Normal"
        case .blend: return "Blend"
        case .angle: return "Angle"
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

    /// CPU reference sampler — the byte-for-byte mirror of `samplePalette` in
    /// RaymarchCore.metal (the same wrap, bracket search, and linear↔smoothstep
    /// segment blend). Kept in lockstep so tests can pin the GPU look on the
    /// CPU. Returns linear rgb.
    ///
    /// - Parameters:
    ///   - t: raw mapping coordinate (wrapped internally).
    ///   - repeatCount: gradient tiling (clamped to >= 1).
    ///   - offset: phase shift, wrapped with the coordinate.
    ///   - smoothing: 0 = linear segments, 1 = smoothstep segments.
    public func sample(
        t: Float, repeatCount: Float = 1, offset: Float = 0, smoothing: Float = 0
    ) -> (red: Float, green: Float, blue: Float) {
        let n = stops.count
        if n == 0 { return (0.5, 0.5, 0.5) }
        var u = t * max(repeatCount, 1) + offset
        u -= u.rounded(.down)  // wrap into [0,1)
        if n == 1 || u <= stops[0].position {
            return (stops[0].red, stops[0].green, stops[0].blue)
        }
        if u >= stops[n - 1].position {
            return (stops[n - 1].red, stops[n - 1].green, stops[n - 1].blue)
        }
        let s = min(max(smoothing, 0), 1)
        for i in 0..<(n - 1) where u >= stops[i].position && u <= stops[i + 1].position {
            let p0 = stops[i].position
            let p1 = stops[i + 1].position
            var f = (u - p0) / max(p1 - p0, 1e-6)
            let fs = f * f * (3 - 2 * f)
            f = f + (fs - f) * s
            let a = stops[i], b = stops[i + 1]
            return (a.red + (b.red - a.red) * f,
                    a.green + (b.green - a.green) * f,
                    a.blue + (b.blue - a.blue) * f)
        }
        return (stops[n - 1].red, stops[n - 1].green, stops[n - 1].blue)
    }

    /// Blend two palettes for a scene-transition crossfade (ADR-005).
    ///
    /// Stops are rebuilt at the UNION of both palettes' stop positions and
    /// each sampled color mixed by `weight` (0 = `from`, 1 = `to`). With
    /// linear segments (smoothing 0) a palette resampled at a superset of its
    /// own knots reproduces it exactly, so the crossfade endpoints match the
    /// originals; when the union exceeds the ABI stop cap, stops fall back to
    /// `maxStops` uniform positions (a mid-flight approximation only — the
    /// transition owner returns the exact target palette once it lands).
    public static func crossfade(from: Palette, to: Palette, weight: Float) -> Palette {
        let w = weight.isFinite ? min(max(weight, 0), 1) : 1
        if w <= 0 { return from }
        if w >= 1 { return to }

        var positions = (from.stops.map(\.position) + to.stops.map(\.position))
            .sorted()
        // Dedup within a hair — coincident stops would waste cap slots.
        var merged: [Float] = []
        for p in positions where merged.last.map({ p - $0 > 1e-4 }) ?? true {
            merged.append(p)
        }
        if merged.count > maxStops {
            merged = (0..<maxStops).map { Float($0) / Float(maxStops - 1) }
        }
        positions = merged

        let stops = positions.map { p -> GradientStop in
            // sample() wraps t into [0,1), sending an exact 1.0 to the FIRST
            // stop — back off a hair so a position-1.0 stop reads its own end.
            let t = min(p, 1 - Float.ulpOfOne * 4)
            let a = from.sample(t: t)
            let b = to.sample(t: t)
            return GradientStop(
                position: p,
                red: a.red + (b.red - a.red) * w,
                green: a.green + (b.green - a.green) * w,
                blue: a.blue + (b.blue - a.blue) * w)
        }
        return Palette(stops: stops)
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
