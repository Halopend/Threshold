// DERegistry.swift — descriptors for the built-in distance estimators.
//
// Each built-in DE is one registration: a stable table index (the visible
// function table index in FrameUniforms.meta.y), a stable string key (scene
// files, catalog namespace), display metadata, and the declared param layout.
// External DEs use the same registration path (Invariant 5: built-in and
// external DEs are indistinguishable past the function table).
//
// ── Encoder convention (normative for ThresholdRender) ──────────────────────
// The DE param slice uploaded to the GPU (`params + meta.w`, read through
// ThreshDEContext) is:
//
//     [declared params in layout order] + [iterations]      // LAST entry
//
// i.e. `paramLayout.count + 1` floats, with the resolved iteration cap (engine
// slot THRESH_SLOT_ITERATIONS) appended as the final element. The CPU
// reference (`ReferenceDEs`) takes the same declared params plus the same
// iteration count, passed explicitly.

import ThresholdCore

// MARK: - DEDescriptor

/// Registration record for one distance estimator.
public struct DEDescriptor: Sendable, Hashable {
    /// One declared parameter: name (seeds `ParamKey.de(key, name)`), default,
    /// and clamp range. Two optional flags let a DE param behave like the zoom
    /// integrator (ScaleContext): a rate that drives a wrapping phase.
    public struct Param: Sendable, Hashable {
        public let name: String
        public let `default`: Float
        public let range: ClosedRange<Float>
        /// If set, this param is a resolver-owned INTEGRATOR PHASE: transient,
        /// instant, and advanced each frame by the same-DE rate param named
        /// here, then wrapped into `range` — the `scale.zoom ← scale.zoomSpeed`
        /// template applied to a DE param (e.g. `rotationPhase ← rotationSpeed`).
        /// The phase's resolved value still rides the GPU slice at its layout
        /// position, so the shader reads the live phase like any other param.
        public let integratorRate: String?
        /// Register with instant (un-eased) smoothing. Integrator RATES want
        /// this: integrating a stepped rate already yields continuous motion, so
        /// smoothing the rate double-smooths (ScaleContext.registerScaleParams).
        /// Phases are always instant regardless.
        public let instantSmoothing: Bool

        public init(
            name: String, default defaultValue: Float, range: ClosedRange<Float>,
            integratorRate: String? = nil, instantSmoothing: Bool = false
        ) {
            self.name = name
            self.default = defaultValue
            self.range = range
            self.integratorRate = integratorRate
            self.instantSmoothing = instantSmoothing
        }
    }

    /// Visible-function-table index (`FrameUniforms.meta.y`). Stable:
    /// 0 = mandelbox, 1 = mandelbulb. Never renumber.
    public let index: UInt32
    /// Stable string key — scene files and the `de.{key}.{name}` catalog
    /// namespace.
    public let key: String
    public let displayName: String
    /// `[[visible]]` MSL function name in the metallib.
    public let mslFunctionName: String
    /// Human-readable equation string (UI metadata, plan §12.11).
    public let equation: String
    /// Declared params, in GPU slice order (see encoder convention above).
    public let paramLayout: [Param]
    /// Default DE iteration cap (seeds engine slot THRESH_SLOT_ITERATIONS).
    public let defaultIterations: Int
    /// Safe over-relaxation factor ω for enhanced sphere tracing against this
    /// DE (legacy per-formula cap table, docs/perf-notes.md block 6): the
    /// march steps ω·DE and retreats on overshoot. Log-DEs (bulb families)
    /// overestimate near the set and only tolerate ~1.1; box-fold DEs take
    /// 1.6. 1.0 = plain sphere tracing.
    public let stepRelaxation: Float
    /// Cone-prepass DE distrust factor (THRESH_CONE_FUDGE): the coarse tile
    /// prepass multiplies this into every distance estimate before stepping
    /// or stopping — Fulcrum's graduated-fudge idea (distrust an
    /// OVERESTIMATING DE more in wide coarse cones than at per-pixel scale).
    /// REFUTED as a default (perf-notes block 16): on the shimmer/perf axes
    /// it is dominated by the existing Cone Stability margin — bulb-family
    /// 0.75 bought less flicker reduction than margin 12 at higher cost. The
    /// seam stays (baked at specialized-library compile; 1.0 folds away to
    /// zero cost) as a re-test hook for DEs whose prepass demonstrably
    /// tunnels — e.g. the sphere-projection singularity once MSP scenes
    /// render. The fine march's trust knob is `stepRelaxation`.
    public let coneFudge: Float

    public init(
        index: UInt32,
        key: String,
        displayName: String,
        mslFunctionName: String,
        equation: String,
        paramLayout: [Param],
        defaultIterations: Int,
        stepRelaxation: Float = 1.0,
        coneFudge: Float = 1.0
    ) {
        self.index = index
        self.key = key
        self.displayName = displayName
        self.mslFunctionName = mslFunctionName
        self.equation = equation
        self.paramLayout = paramLayout
        self.defaultIterations = defaultIterations
        self.stepRelaxation = stepRelaxation
        self.coneFudge = coneFudge
    }
}

// MARK: - Built-in descriptors

extension DEDescriptor {
    /// Classic Mandelbox. Param layout is THE layout (ReferenceDEs and the
    /// GPU implement the same): [scale, minRadius, fixedRadius, foldLimit].
    public static let mandelbox = DEDescriptor(
        index: 0,
        key: "mandelbox",
        displayName: "Mandelbox",
        mslFunctionName: "de_mandelbox",
        equation: "zₙ₊₁ = scale·sphereFold(boxFold(zₙ)) + p",
        paramLayout: [
            Param(name: "scale", default: 2.0, range: -4.0...4.0),
            Param(name: "minRadius", default: 0.25, range: 0.01...2.0),
            Param(name: "fixedRadius", default: 1.0, range: 0.05...4.0),
            Param(name: "foldLimit", default: 1.0, range: 0.1...4.0),
        ],
        defaultIterations: 12,
        stepRelaxation: 1.6
    )

    /// Classic power-N Mandelbulb with a continuous polar rotation (the
    /// original app's "PolarRotation" knob, now an integrator). Param layout:
    /// [power, rotationSpeed, rotationPhase]. The rotation offsets the spherical
    /// angles (θ, φ) each iteration BEFORE the ×power scaling — an isometry on
    /// the sphere, so the running derivative (and thus the distance bound) is
    /// unchanged; the fractal cycles as the phase sweeps [0, 2π). `rotationPhase`
    /// is a resolver-owned integrator driven by `rotationSpeed` (the zoom
    /// template); at speed 0 the phase stays 0 and the shape is byte-identical
    /// to the un-rotated bulb.
    public static let mandelbulb = DEDescriptor(
        index: 1,
        key: "mandelbulb",
        displayName: "Mandelbulb",
        mslFunctionName: "de_mandelbulb",
        equation: "zₙ₊₁ = zₙ^power + p (polar rotation θ,φ += phase)",
        paramLayout: [
            Param(name: "power", default: 8.0, range: 2.0...16.0),
            Param(name: "rotationSpeed", default: 0.0, range: -2.0...2.0,
                  instantSmoothing: true),
            Param(name: "rotationPhase", default: 0.0, range: 0.0...6.2831855,
                  integratorRate: "rotationSpeed"),
        ],
        defaultIterations: 12,
        stepRelaxation: 1.3
        // coneFudge 0.75 tested + refuted, perf-notes block 16
    )

    /// Knighty's Pseudo Kleinian: box fold + sphere fold with a cylindrical
    /// cross-section DE. Param order matches the ORIGINAL app's
    /// formulaParamValues[0...7] so the legacy migration can map them 1:1.
    /// (The original's ColorOfs/ColorScale tail params were coloring-system
    /// knobs, not DE inputs — deliberately not carried over.)
    public static let kleinian = DEDescriptor(
        index: 2,
        key: "kleinian",
        displayName: "Kleinian",
        mslFunctionName: "de_kleinian",
        equation: "zₙ₊₁ = sphereFold(boxFold(zₙ, mins, maxs))",
        paramLayout: [
            Param(name: "minX", default: -0.3252, range: -2.0...2.0),
            Param(name: "minY", default: -0.7862, range: -2.0...2.0),
            Param(name: "minZ", default: -0.0948, range: -2.0...2.0),
            Param(name: "sphereFold", default: 0.69, range: 0.01...3.0),
            Param(name: "maxX", default: 0.35, range: -2.0...2.0),
            Param(name: "maxY", default: 1.0, range: -2.0...2.0),
            Param(name: "maxZ", default: 1.22, range: -2.0...2.0),
            Param(name: "crossRadius", default: 0.84, range: 0.01...4.0),
        ],
        defaultIterations: 12,
        stepRelaxation: 1.2
    )

    /// Classic Menger sponge (abs + sort fold, scale + offset). The original's
    /// per-iteration rotation matrix is deliberately not a DE input here —
    /// orientation belongs to the warp stack / camera, not the formula.
    public static let mengerSponge = DEDescriptor(
        index: 3,
        key: "mengerSponge",
        displayName: "Menger Sponge",
        mslFunctionName: "de_menger",
        equation: "zₙ₊₁ = scale·sort(|zₙ|) − offset·(scale−1)",
        paramLayout: [
            Param(name: "scale", default: 3.0, range: 1.0...6.0),
            Param(name: "offsetX", default: 1.0, range: 0.0...4.0),
            Param(name: "offsetY", default: 1.0, range: 0.0...4.0),
            Param(name: "offsetZ", default: 1.0, range: 0.0...4.0),
        ],
        defaultIterations: 12,
        stepRelaxation: 1.6
    )

    /// Quaternion Julia set (q ← q² + c with the running Jacobian norm).
    /// `threshold` is the squared escape radius — a genuine shape control in
    /// this family, kept declared.
    public static let quaternionJulia = DEDescriptor(
        index: 4,
        key: "quaternionJulia",
        displayName: "Quaternion Julia",
        mslFunctionName: "de_quaternion_julia",
        equation: "qₙ₊₁ = qₙ² + c",
        paramLayout: [
            Param(name: "cX", default: -0.2, range: -2.0...2.0),
            Param(name: "cY", default: 0.8, range: -2.0...2.0),
            Param(name: "cZ", default: 0.0, range: -2.0...2.0),
            Param(name: "cW", default: 0.0, range: -2.0...2.0),
            Param(name: "threshold", default: 10.0, range: 1.0...100.0),
        ],
        defaultIterations: 12,
        stepRelaxation: 1.3
    )

    /// Mandelbox with a built-in sphere projection (domain warp applied ONCE to
    /// the sample point before the fold loop). Reproduces the original app's
    /// dedicated `mandelboxSphereProjection` type — the look behind scenes like
    /// "good luck" and "mono". Shape params match `mandelbox`; `projBlend` /
    /// `projRadius` are the legacy Space-tab "Sphere Projection" controls, now
    /// self-contained in the DE instead of the warp stack. Identity projection
    /// (blend = 0) degenerates to a plain Mandelbox.
    public static let mandelboxSphereProjection = DEDescriptor(
        index: 6,
        key: "mandelboxSphereProjection",
        displayName: "Mandelbox (Sphere Proj)",
        mslFunctionName: "de_mandelboxSphereProjection",
        equation: "p′ = p·((1−b) + b·R/|p|);  Mandelbox(p′)",
        paramLayout: [
            Param(name: "scale", default: 2.0, range: -4.0...4.0),
            Param(name: "minRadius", default: 0.25, range: 0.01...2.0),
            Param(name: "fixedRadius", default: 1.0, range: 0.05...4.0),
            Param(name: "foldLimit", default: 1.0, range: 0.1...4.0),
            Param(name: "projBlend", default: 0.98, range: 0.0...0.98),
            Param(name: "projRadius", default: 1.0, range: 0.2...12.0),
        ],
        defaultIterations: 12,
        // Step-safety 0.9 (conservative; NOT Mandelbox's over-relaxed 1.6).
        // Used directly as stepSafety (main.swift). The baked projection makes
        // the DE non-conformal, so over-relaxation oversteps → keep the safe
        // default. NOTE: at high blend the projection has a genuine r→0
        // singularity (the origin maps onto the whole shell); if the origin is
        // in empty space in view, no step-safety value removes the caustic —
        // that is inherent to the map, matching the legacy behaviour.
        stepRelaxation: 0.9
    )

    /// Julia-mode Mandelbulb: the mandelbulb iteration with a fixed additive
    /// constant instead of p. The original's Bailout/DerivBias/PolarRotation
    /// knobs were escape-hatch tuning, not shape — dropped; bailout is the
    /// same constant 4 as the mandelbulb.
    public static let mandelbulbJulia = DEDescriptor(
        index: 5,
        key: "mandelbulbJulia",
        displayName: "Mandelbulb Julia",
        mslFunctionName: "de_mandelbulb_julia",
        equation: "zₙ₊₁ = zₙ^power + c",
        paramLayout: [
            Param(name: "power", default: 8.0, range: 2.0...16.0),
            Param(name: "cX", default: 0.2, range: -2.0...2.0),
            Param(name: "cY", default: -0.15, range: -2.0...2.0),
            Param(name: "cZ", default: 0.35, range: -2.0...2.0),
        ],
        defaultIterations: 12,
        stepRelaxation: 1.3
    )
}

// MARK: - DERegistry

public enum DERegistry {
    /// Built-in DEs, ordered by table index.
    public static let builtin: [DEDescriptor] = [
        .mandelbox, .mandelbulb, .kleinian, .mengerSponge,
        .quaternionJulia, .mandelbulbJulia, .mandelboxSphereProjection,
    ]

    public static func descriptor(forKey key: String) -> DEDescriptor? {
        builtin.first { $0.key == key }
    }

    public static func descriptor(forIndex index: UInt32) -> DEDescriptor? {
        builtin.first { $0.index == index }
    }
}

// MARK: - Catalog registration

extension DEDescriptor {
    /// Register this descriptor's declared params into `catalog` under
    /// `ParamKey.de(key, name)` (Invariant 14 — the factory is the only way
    /// DE param keys are minted). One scalar entry per declared param, in
    /// layout order, so the registered slots follow the GPU slice order.
    ///
    /// The iteration cap is NOT registered here — it is the shared engine
    /// param at slot THRESH_SLOT_ITERATIONS, appended to the GPU slice by the
    /// encoder (see the convention at the top of this file).
    ///
    /// - Returns: the assigned catalog slots, in layout order.
    /// - Throws: `CatalogError.duplicateKey` if any param is already
    ///   registered (e.g. registering the same DE twice).
    @discardableResult
    public func registerParams(
        into catalog: Catalog,
        group: GroupID = .shape,
        capabilities: Capabilities = [.musicBindable, .animatable]
    ) throws -> [Int] {
        var slots: [Int] = []
        slots.reserveCapacity(paramLayout.count)
        for param in paramLayout {
            let isPhase = param.integratorRate != nil
            let spec = ParamSpec(
                key: .de(key, param.name),
                label: "\(displayName) \(param.name)",
                range: param.range,
                default: param.default,
                // Phases are resolver-owned + wrap; their value is not eased.
                // Rates flagged instant match the zoom-rate convention. Shape
                // params still ease (ADR-005).
                composition: .additive,
                smoothing: (isPhase || param.instantSmoothing) ? .instant : .continuous,
                // Integrator phases persist via the envelope's integratorPhases
                // snapshot, not the params walk (like scale.zoom).
                persistence: isPhase ? .transient : .scene,
                // A phase is machine-driven, not a slider/music target.
                capabilities: isPhase ? [.animatable] : capabilities,
                group: group,
                integratorRateKey: param.integratorRate.map { .de(key, $0) }
            )
            slots.append(try catalog.register(spec))
        }
        return slots
    }

    /// Build the GPU param slice for the given resolved values: declared
    /// params in layout order + the iteration count as the LAST entry.
    public func makeParamSlice(values: [Float], iterations: Int) -> [Float] {
        precondition(values.count == paramLayout.count,
                     "\(key) expects \(paramLayout.count) declared params, got \(values.count)")
        return values + [Float(iterations)]
    }

    /// The GPU param slice at declared defaults.
    public func defaultParamSlice() -> [Float] {
        paramLayout.map(\.default) + [Float(defaultIterations)]
    }
}
