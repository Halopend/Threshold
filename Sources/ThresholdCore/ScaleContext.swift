// ScaleContext.swift — the single zoom/scale derivation site (plan §6.3,
// build order phase 10 part 1).
//
// Zoom = model-scale renormalization (the original's choice, kept — it is
// what enables infinite zoom): the kernel multiplies world positions by
// `modelScale` before the warp stack + DE, and divides the resulting
// distance, so the marched field stays a correct WORLD-space bound at any
// zoom. Every scale-derived quantity (epsilon base, the normal-probe floor,
// future LOD/proxy inflation/horizon lift) reads THIS struct — the zoom-out
// bug class of the original ("the fix had to touch three places") cannot
// recur because there is exactly one derivation site.
//
// Octave rebase (infinite-zoom phase 2) will renormalize camera + zoom + DE
// params atomically on a snapshot boundary and bump `octave`; until then
// octave is always 0 and `scale.zoom`'s range is the practical float budget.

import Foundation

// MARK: - Param keys

extension ParamKey {
    /// Zoom position in OCTAVES, positive magnifies (zoom in). Integrator
    /// phase driven by `scaleZoomSpeed`; the engine owns it (Invariant 17).
    public static let scaleZoom = ParamKey("scale.zoom")
    /// Signed zoom rate in octaves/second (the original's "Infinite Zoom"
    /// speed — now a catalog param, so bindable/animatable for free,
    /// plan §12.8). 0 = stationary.
    public static let scaleZoomSpeed = ParamKey("scale.zoomSpeed")
}

// MARK: - ScaleContext

/// Derived per frame from the resolved `scale.zoom` value; consumed by the
/// uniform builder (and later the presentation shells' proxy geometry).
public struct ScaleContext: Sendable, Equatable {
    /// Zoom position in octaves, positive = magnified.
    public let zoomOctaves: Float
    /// Rebase counter — always 0 until infinite-zoom phase 2.
    public let octave: Int32

    public init(zoomOctaves: Float, octave: Int32 = 0) {
        self.zoomOctaves = zoomOctaves
        self.octave = octave
    }

    /// World→model position multiplier: `exp2(-zoom)`. Positive zoom shrinks
    /// model space relative to the world, i.e. the fractal appears LARGER
    /// (world size = model size / modelScale).
    public var modelScale: Float { exp2(-zoomOctaves) }

    /// Cone half-angle base for the distance-proportional hit epsilon
    /// (`hitEps = epsilonBase * t`). Distances are world-space (the kernel
    /// divides by modelScale), so this is scale-INVARIANT by construction —
    /// it derives here anyway so a future screen-space-aware derivation has
    /// its one home.
    public var epsilonBase: Float { 1e-3 }
}

// MARK: - Catalog registration

extension Catalog {
    /// Register the zoom params (rate + integrator phase). Called by
    /// `withEngineDefaults` — separate so tests can build minimal catalogs
    /// without them.
    ///
    /// `scale.zoom` is `.transient` like all integrator phases: the phase
    /// value persists via the envelope's integratorPhases snapshot, not the
    /// params walk. The ±64-octave range is a float-budget guard, not a
    /// design limit — octave rebase (phase 2) lifts it. Wrap-around at the
    /// rim is accepted until then (unreachable in practice: at the maximum
    /// rate it is >30 s of sustained zoom from default).
    public func registerScaleParams() throws {
        try register(ParamSpec(
            key: .scaleZoomSpeed, label: "Zoom Speed",
            range: -2...2, default: 0,
            composition: .additive, smoothing: .instant,
            persistence: .scene,
            capabilities: [.musicBindable, .animatable],
            group: .camera))
        try register(ParamSpec(
            key: .scaleZoom, label: "Zoom",
            range: -64...64, default: 0,
            composition: .additive, smoothing: .instant,
            persistence: .transient,
            capabilities: [.animatable],
            group: .camera,
            integratorRateKey: .scaleZoomSpeed))
    }
}
