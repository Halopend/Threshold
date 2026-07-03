// PalettePresets.swift — the built-in named gradients (plan §5.5: the 14
// presets the shipping app ships). Colors are LINEAR rgb. These are content:
// selecting one copies its stops into the scene palette, after which the user
// can edit freely — the preset identity is not retained.

import Foundation

// MARK: - PalettePreset

public struct PalettePreset: Sendable, Identifiable, Hashable {
    /// Stable identifier (persists nowhere — the STOPS persist; this is a UI
    /// handle). Kebab-case, matching the shipping app's names.
    public let id: String
    public let name: String
    public let palette: Palette

    public init(id: String, name: String, stops: [GradientStop]) {
        self.id = id
        self.name = name
        self.palette = Palette(stops: stops)
    }
}

// MARK: - Built-ins

extension PalettePreset {
    private static func stop(_ p: Float, _ r: Float, _ g: Float, _ b: Float) -> GradientStop {
        GradientStop(position: p, red: r, green: g, blue: b)
    }

    /// All built-in presets, in menu order. The first (`classic`) is the
    /// renderer's default look.
    public static let builtIn: [PalettePreset] = [
        PalettePreset(id: "classic", name: "Classic", stops: [
            stop(0.00, 0.02, 0.02, 0.06), stop(0.30, 0.55, 0.12, 0.30),
            stop(0.60, 0.95, 0.55, 0.18), stop(0.85, 0.98, 0.90, 0.55),
            stop(1.00, 0.90, 0.98, 0.95),
        ]),
        PalettePreset(id: "ocean", name: "Ocean", stops: [
            stop(0.00, 0.01, 0.03, 0.10), stop(0.35, 0.02, 0.20, 0.45),
            stop(0.70, 0.10, 0.55, 0.70), stop(1.00, 0.80, 0.95, 0.98),
        ]),
        PalettePreset(id: "fire", name: "Fire", stops: [
            stop(0.00, 0.02, 0.00, 0.00), stop(0.30, 0.45, 0.03, 0.01),
            stop(0.60, 0.95, 0.35, 0.02), stop(0.85, 1.00, 0.80, 0.15),
            stop(1.00, 1.00, 0.98, 0.85),
        ]),
        PalettePreset(id: "forest", name: "Forest", stops: [
            stop(0.00, 0.02, 0.05, 0.02), stop(0.35, 0.08, 0.25, 0.08),
            stop(0.70, 0.35, 0.55, 0.15), stop(1.00, 0.85, 0.92, 0.55),
        ]),
        PalettePreset(id: "nebula", name: "Nebula", stops: [
            stop(0.00, 0.03, 0.01, 0.08), stop(0.30, 0.25, 0.05, 0.35),
            stop(0.60, 0.65, 0.15, 0.55), stop(0.82, 0.90, 0.45, 0.65),
            stop(1.00, 0.98, 0.85, 0.90),
        ]),
        PalettePreset(id: "mono", name: "Mono", stops: [
            stop(0.00, 0.02, 0.02, 0.02), stop(1.00, 0.98, 0.98, 0.98),
        ]),
        PalettePreset(id: "aurora", name: "Aurora", stops: [
            stop(0.00, 0.01, 0.05, 0.08), stop(0.35, 0.05, 0.45, 0.40),
            stop(0.65, 0.20, 0.80, 0.55), stop(0.85, 0.55, 0.75, 0.85),
            stop(1.00, 0.90, 0.70, 0.95),
        ]),
        PalettePreset(id: "volcanic", name: "Volcanic", stops: [
            stop(0.00, 0.03, 0.02, 0.03), stop(0.40, 0.30, 0.05, 0.08),
            stop(0.70, 0.75, 0.15, 0.05), stop(0.90, 0.98, 0.55, 0.10),
            stop(1.00, 1.00, 0.92, 0.60),
        ]),
        PalettePreset(id: "neon-cyber", name: "Neon Cyber", stops: [
            stop(0.00, 0.02, 0.01, 0.08), stop(0.35, 0.05, 0.85, 0.90),
            stop(0.70, 0.85, 0.10, 0.75), stop(1.00, 0.98, 0.95, 0.30),
        ]),
        PalettePreset(id: "neon-sunset", name: "Neon Sunset", stops: [
            stop(0.00, 0.10, 0.02, 0.20), stop(0.35, 0.80, 0.10, 0.45),
            stop(0.70, 1.00, 0.45, 0.20), stop(1.00, 1.00, 0.90, 0.40),
        ]),
        PalettePreset(id: "neon-matrix", name: "Neon Matrix", stops: [
            stop(0.00, 0.00, 0.03, 0.01), stop(0.45, 0.02, 0.45, 0.10),
            stop(0.80, 0.20, 0.95, 0.30), stop(1.00, 0.80, 1.00, 0.70),
        ]),
        PalettePreset(id: "rainbow", name: "Rainbow", stops: [
            stop(0.00, 0.90, 0.05, 0.05), stop(0.20, 0.95, 0.55, 0.05),
            stop(0.40, 0.90, 0.90, 0.05), stop(0.55, 0.05, 0.80, 0.15),
            stop(0.70, 0.05, 0.45, 0.90), stop(0.85, 0.35, 0.10, 0.75),
            stop(1.00, 0.75, 0.10, 0.55),
        ]),
        PalettePreset(id: "infrared", name: "Infrared", stops: [
            stop(0.00, 0.02, 0.00, 0.05), stop(0.30, 0.30, 0.00, 0.35),
            stop(0.55, 0.85, 0.10, 0.20), stop(0.78, 0.98, 0.60, 0.05),
            stop(1.00, 1.00, 0.98, 0.75),
        ]),
        PalettePreset(id: "twilight", name: "Twilight", stops: [
            stop(0.00, 0.04, 0.03, 0.12), stop(0.35, 0.25, 0.15, 0.40),
            stop(0.65, 0.60, 0.35, 0.50), stop(0.85, 0.90, 0.60, 0.45),
            stop(1.00, 0.98, 0.88, 0.70),
        ]),
    ]

    /// The default preset (`classic`) — the renderer's out-of-the-box look.
    public static let `default` = builtIn[0]

    /// Look up a preset by id.
    public static func preset(id: String) -> PalettePreset? {
        builtIn.first { $0.id == id }
    }
}
