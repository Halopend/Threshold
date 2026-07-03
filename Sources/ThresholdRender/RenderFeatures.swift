// RenderFeatures.swift — the render feature table (plan §6.2, Invariant 8:
// a feature must never silently exist on only one path).
//
// ADR-001 makes this nearly free: every path dispatches the SAME compute
// kernel family (GPUContext.marchPipeline, "march_offscreen"), so visual
// features cannot diverge per shell at the kernel level. What CAN diverge is
// the ENCODE CONTRACT — which buffers/textures a shell binds (the palette
// buffer, the stats buffer, the DE function table). This table declares that
// contract per path, and the CI test (RenderFeatureTableTests) fails when a
// shipping path is missing a feature marked requiredOnAll — turning "zoom fog
// exists on fragment but not compute" (the original codebase's failure mode)
// into a build failure instead of a device discovery.
//
// Rules for editing:
// - Adding a shell (the visionOS Compositor path) = add the RenderPath case,
//   add it to `shipping` for the platforms it ships on, and extend each
//   feature's `paths` as the shell wires it. The test then enumerates exactly
//   what the new shell still lacks.
// - Adding a feature = one entry here, `requiredOnAll: true` unless it is
//   genuinely shell-specific (e.g. present-time foveation decode).

public enum RenderPath: String, CaseIterable, Sendable, Hashable {
    /// Headless offscreen texture render (harness, tests, Quick Look later).
    case offscreen
    /// Live CAMetalDisplayLink → drawable path (macOS + iPadOS).
    case interactive
    /// visionOS Compositor Services frame loop. Declared ahead of its shell
    /// so the table already tracks what it must cover (ADR-001 action items
    /// gate the implementation on a device spike).
    case compositor

    /// The paths that SHIP in the current codebase. The compositor shell is
    /// not yet implemented, so it is deliberately absent — a feature listing
    /// it early is fine; a shipping path missing a required feature is not.
    public static let shipping: Set<RenderPath> = [.offscreen, .interactive]
}

public struct RenderFeature: Sendable, Hashable {
    public let id: String
    /// Paths that implement this feature TODAY.
    public let paths: Set<RenderPath>
    /// When true, the CI test fails if any `RenderPath.shipping` member is
    /// missing from `paths`.
    public let requiredOnAll: Bool

    public init(id: String, paths: Set<RenderPath>, requiredOnAll: Bool = true) {
        self.id = id
        self.paths = paths
        self.requiredOnAll = requiredOnAll
    }
}

public enum RenderFeatureTable {
    /// The single registry (plan §6.2). Every render feature registers here.
    public static let features: [RenderFeature] = [
        // The march core itself: uniforms + param table + warp ops + DE
        // visible function table — the kernel's mandatory bindings.
        RenderFeature(id: "march.core", paths: [.offscreen, .interactive]),
        // In-kernel step counter (device atomic; plan §9 "measured steps
        // always compiled in").
        RenderFeature(id: "march.stepStats", paths: [.offscreen, .interactive]),
        // Color pipeline: palette buffer + mapping/grading param slots
        // (plan §5.5).
        RenderFeature(id: "color.palette", paths: [.offscreen, .interactive]),
        // Warp-op stack applied before de_main (plan §5.2).
        RenderFeature(id: "warp.stack", paths: [.offscreen, .interactive]),
    ]
}
