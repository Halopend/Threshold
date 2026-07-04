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
// Octave rebase (infinite-zoom phase 2, plan §6.3): when the zoom phase
// reaches `rebaseThreshold` octaves, the render thread folds the INTEGER part
// into `octave` and renormalizes the world atomically between frames —
// phase -= k, camera.position ×= 2^-k. Both rewrites are exact in binary
// floats (power-of-two scale, exact float−int subtraction at this magnitude),
// so the rendered image is unchanged while the phase and the camera's world
// coordinates stay in a healthy float range at ANY zoom depth. Rebase fires
// zoom-IN only: magnification pushes off-origin features (and the camera
// chasing them) outward at 2^zoom, which is the coordinate growth that eats
// mantissa bits; zoom-out collapses features toward the origin with the
// camera holding still, so no drift accumulates and the −64 range floor
// remains the honest budget.

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
    /// Zoom phase in octaves, positive = magnified. After a rebase this is
    /// the FRACTIONAL remainder — kept within `±rebaseThreshold`.
    public let zoomOctaves: Float
    /// Rebase counter: how many integer octaves have been folded out of the
    /// phase (and out of the world's coordinates). Bookkeeping only — the
    /// kernel never sees it; `zoomOctaves` + the rebased camera fully
    /// determine the image.
    public let octave: Int32

    /// Zoom phase magnitude at which the render thread rebases. 8 keeps
    /// `modelScale` within 2⁻⁸…2⁸ and camera coordinates small enough that
    /// float absolute precision (~2⁻¹⁵ at magnitude 2⁸·|p₀|) stays well under
    /// the hit epsilon; legacy scenes migrate with zoom < 8, so their goldens
    /// never see a rebase.
    public static let rebaseThreshold: Float = 8

    /// The integer octave step to fold out of `zoomOctaves` at a rebase
    /// boundary; 0 when the phase is within budget (or zooming OUT — see the
    /// header: negative zoom accumulates no coordinate drift).
    public static func rebaseStep(zoomOctaves: Float) -> Int32 {
        guard zoomOctaves.isFinite, zoomOctaves >= rebaseThreshold else { return 0 }
        return Int32(zoomOctaves.rounded(.towardZero))
    }

    public init(zoomOctaves: Float, octave: Int32 = 0) {
        self.zoomOctaves = zoomOctaves
        self.octave = octave
    }

    /// Total zoom depth in octaves — what the user has actually zoomed,
    /// across every rebase. Display/telemetry only.
    public var totalZoomOctaves: Float { Float(octave) + zoomOctaves }

    /// World→model position multiplier: `exp2(-zoom)`. Positive zoom shrinks
    /// model space relative to the world, i.e. the fractal appears LARGER
    /// (world size = model size / modelScale).
    public var modelScale: Float { exp2(-zoomOctaves) }

    /// Cone half-angle base for the distance-proportional hit epsilon
    /// (`hitEps = epsilonBase * t`). Distances are world-space (the kernel
    /// divides by modelScale), so this is scale-INVARIANT by construction —
    /// it derives here anyway so a future screen-space-aware derivation has
    /// its one home.
    /// 1.5e-3 (was 1e-3): perf round 10 — the near-surface step crawl scales
    /// with 1/epsilon, and the 1.5× base cut the 2048² mandelbox frame ~18%
    /// for a slight softening of finest detail (bench-results/history.jsonl).
    public var epsilonBase: Float { 1.5e-3 }
}

// MARK: - Catalog registration

extension Catalog {
    /// Register the zoom params (rate + integrator phase). Called by
    /// `withEngineDefaults` — separate so tests can build minimal catalogs
    /// without them.
    ///
    /// `scale.zoom` is `.transient` like all integrator phases: the phase
    /// value persists via the envelope's integratorPhases snapshot, not the
    /// params walk. Zoom-IN never approaches the +64 rim — octave rebase
    /// folds the phase back at +8 — so the range effectively bounds zoom-OUT
    /// only, where −64 is the honest float budget (no rebase; see the
    /// header).
    public func registerScaleParams() throws {
        // Zoom SPEED stays instant (ADR-005): it is an integrator rate, and
        // the phase integrator already turns a stepped rate into continuous
        // motion (∫ of a step is a ramp — position never jumps). Smoothing the
        // rate on top would double-smooth and desync the deterministic
        // integration the harness/golden tests rely on.
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
