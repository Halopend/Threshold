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
    /// and clamp range.
    public struct Param: Sendable, Hashable {
        public let name: String
        public let `default`: Float
        public let range: ClosedRange<Float>

        public init(name: String, default defaultValue: Float, range: ClosedRange<Float>) {
            self.name = name
            self.default = defaultValue
            self.range = range
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

    public init(
        index: UInt32,
        key: String,
        displayName: String,
        mslFunctionName: String,
        equation: String,
        paramLayout: [Param],
        defaultIterations: Int
    ) {
        self.index = index
        self.key = key
        self.displayName = displayName
        self.mslFunctionName = mslFunctionName
        self.equation = equation
        self.paramLayout = paramLayout
        self.defaultIterations = defaultIterations
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
        defaultIterations: 12
    )

    /// Classic power-N Mandelbulb. Param layout: [power].
    public static let mandelbulb = DEDescriptor(
        index: 1,
        key: "mandelbulb",
        displayName: "Mandelbulb",
        mslFunctionName: "de_mandelbulb",
        equation: "zₙ₊₁ = zₙ^power + p",
        paramLayout: [
            Param(name: "power", default: 8.0, range: 2.0...16.0),
        ],
        defaultIterations: 12
    )
}

// MARK: - DERegistry

public enum DERegistry {
    /// Built-in DEs, ordered by table index.
    public static let builtin: [DEDescriptor] = [.mandelbox, .mandelbulb]

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
            let spec = ParamSpec(
                key: .de(key, param.name),
                label: "\(displayName) \(param.name)",
                range: param.range,
                default: param.default,
                composition: .additive,
                persistence: .scene,
                capabilities: capabilities,
                group: group
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
