// GestureDefaults.swift — the out-of-the-box gesture bindings (the rebuild's
// port of the old app's per-fractal `FractalTypeDescriptor` default bindings).
//
// Why seed defaults at all: without them the whole assignable gesture layer is
// inert on a fresh install — every finger has to be hand-bound in the editor
// before it does anything (the "gestures don't work out of the box" problem).
// The old app shipped a full per-fractal table; this is its single-hand subset.
//
// Scope: single-hand only for now. The old app's SIGNATURE controls (two-hand
// grab-zoom, two-hand scalar pull-apart) live on `both`-hand slots that the
// rebuild's `GestureSource` vocabulary cannot yet express — those defaults land
// with the two-hand detector. Here the MIDDLE/RING fingers drive each fractal's
// shape params (signed vertical-axis drag), and the INDEX finger is left free so
// the hardwired index-pinch camera control (orbit/dolly) keeps working.

// MARK: - Starter bindings

extension GestureBindingSet {
    /// The default binding set for a fresh install: per-fractal single-hand
    /// bindings that make gestures do something immediately. Global scope is
    /// left empty (two-hand grab defaults come with the two-hand detector).
    public static func starter() -> GestureBindingSet {
        var set = GestureBindingSet()

        func bind(_ deKey: String, _ pairs: [(GestureSource, GestureBinding)]) {
            for (source, binding) in pairs {
                set.setBinding(binding, for: source, scope: .fractal(deKey))
            }
        }
        // A single scalar param driven by the SIGNED vertical (y) axis of a
        // finger-drag — the rebuild's analog of the old app's "vertical" slot
        // direction (magnitude would be one-directional; a grouped y is signed).
        func scalarY(_ deKey: String, _ name: String) -> GestureBinding {
            .vector(.grouped(x: nil, y: .de(deKey, name), z: nil))
        }
        // An x/y/z triple (Julia C, Kleinian Mins/Maxs) driven by a finger-drag.
        func triplet(_ deKey: String, _ x: String, _ y: String, _ z: String) -> GestureBinding {
            .vector(.grouped(x: .de(deKey, x), y: .de(deKey, y), z: .de(deKey, z)))
        }
        func L(_ f: GestureFinger) -> GestureSource { .tapThumb(hand: .left, finger: f) }
        func R(_ f: GestureFinger) -> GestureSource { .tapThumb(hand: .right, finger: f) }

        // Mandelbox — the shape trio (old app: both middle=minDistance,
        // both ring=fractalScale, and foldingLimit exposed).
        bind("mandelbox", [
            (R(.middle), scalarY("mandelbox", "scale")),
            (L(.middle), scalarY("mandelbox", "minRadius")),
            (L(.ring), scalarY("mandelbox", "foldLimit")),
        ])

        // Mandelbulb — Power + the polar rotation rate (old: left index=Power,
        // left middle=PolarRotation; moved off the index to keep camera).
        bind("mandelbulb", [
            (L(.middle), scalarY("mandelbulb", "power")),
            (L(.ring), scalarY("mandelbulb", "rotationSpeed")),
        ])

        // Mandelbulb Julia — Power + the Julia C triplet (old: right middle=JuliaC).
        bind("mandelbulbJulia", [
            (L(.middle), scalarY("mandelbulbJulia", "power")),
            (R(.middle), triplet("mandelbulbJulia", "cX", "cY", "cZ")),
        ])

        // Quaternion Julia — the C triplet (old: right middle=C).
        bind("quaternionJulia", [
            (R(.middle), triplet("quaternionJulia", "cX", "cY", "cZ")),
        ])

        // Kleinian — Mins + Maxs triplets (old: left middle=Mins, right middle=Maxs).
        bind("kleinian", [
            (L(.middle), triplet("kleinian", "minX", "minY", "minZ")),
            (R(.middle), triplet("kleinian", "maxX", "maxY", "maxZ")),
        ])

        // Menger Sponge — the fold scale.
        bind("mengerSponge", [
            (L(.middle), scalarY("mengerSponge", "scale")),
        ])

        // Mandelbox (sphere projection) — scale + the projection knobs.
        bind("mandelboxSphereProjection", [
            (L(.middle), scalarY("mandelboxSphereProjection", "scale")),
            (L(.ring), scalarY("mandelboxSphereProjection", "projBlend")),
            (R(.middle), scalarY("mandelboxSphereProjection", "projRadius")),
        ])

        return set
    }
}
