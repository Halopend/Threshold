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
    /// visionOS Compositor Services frame loop (CompositorSession): the
    /// stereo RASTER path — same march body (marchShade) through
    /// thresh_march_fragment, so kernel-level features cannot diverge.
    case compositor

    /// The paths that SHIP in the current codebase.
    public static let shipping: Set<RenderPath> = [.offscreen, .interactive, .compositor]
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
        RenderFeature(id: "march.core", paths: [.offscreen, .interactive, .compositor]),
        // In-kernel step counter (device atomic; plan §9 "measured steps
        // always compiled in"). The raster path adds from the fragment.
        RenderFeature(id: "march.stepStats", paths: [.offscreen, .interactive, .compositor]),
        // Color pipeline: palette buffer + mapping/grading param slots
        // (plan §5.5).
        RenderFeature(id: "color.palette", paths: [.offscreen, .interactive, .compositor]),
        // Warp-op stack applied before de_main (plan §5.2).
        RenderFeature(id: "warp.stack", paths: [.offscreen, .interactive, .compositor]),
        // External (runtime-compiled) DE programs. NOT on the compositor yet:
        // the raster pipeline links built-ins only (spike scope) — embedded-DE
        // scenes apply their params/palette but render on compute shells.
        RenderFeature(
            id: "de.external", paths: [.offscreen, .interactive], requiredOnAll: false),
        // Hierarchical cone-march prepass (perf block 9, raster port block 11):
        // coarse tile dispatch + THRESH_CONE-gated march start. Now on all
        // three shells — the compositor uses a per-view prepass (rays through
        // ThreshViewUniforms.invProj) writing a depth array the fragment reads.
        // Still requiredOnAll:false: it is a perf overlay, correct to omit.
        RenderFeature(
            id: "march.conePrepass",
            paths: [.offscreen, .interactive, .compositor],
            requiredOnAll: false),
    ]
}
