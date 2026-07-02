// ReferenceDEs.swift — CPU reference distance estimators for the built-in
// fractals. These are the numeric oracles the GPU DEs (`de_mandelbox`,
// `de_mandelbulb` in the metallib) are cross-checked against, and the layout
// documented here is THE param layout: the GPU implements the same.
//
// Return convention (matches the DE ABI, ThresholdShaderABI.h):
//   .x = distance estimate
//   .y = orbit trap (minimum |z| over the iteration)
//
// Param layouts (normative):
//   mandelbox  params = [scale, minRadius, fixedRadius, foldLimit]
//   mandelbulb params = [power]
//
// Encoder convention (see DERegistry): the DE param slice uploaded to the GPU
// is the declared params in layout order with the iteration count appended as
// the LAST entry; `iterations` here is that same count, passed explicitly.
//
// Both are the numerically standard formulations — these must look like the
// classic fractals.

import simd

public enum ReferenceDEs {
    /// Standard Mandelbox DE.
    ///
    /// Per iteration: box fold at `foldLimit` (clamp+reflect), sphere fold
    /// (`minRadius`/`fixedRadius`), multiply by `scale`, add p; the running
    /// derivative accumulates `dr = dr·f` through folds and `dr = dr·|scale| + 1`
    /// through the affine step. Distance = |z| / |dr|.
    ///
    /// - Parameter params: `[scale, minRadius, fixedRadius, foldLimit]`.
    public static func mandelbox(
        _ p: SIMD3<Float>,
        params: [Float],
        iterations: Int
    ) -> SIMD2<Float> {
        precondition(params.count >= 4,
                     "mandelbox params = [scale, minRadius, fixedRadius, foldLimit]")
        let scale = params[0]
        let minR2 = params[1] * params[1]
        let fixedR2 = params[2] * params[2]
        let limit = SIMD3<Float>(repeating: params[3])

        var z = p
        var dr: Float = 1
        var trap = length(p)

        for _ in 0..<max(0, iterations) {
            // Box fold: clamp+reflect per axis.
            z = simd_clamp(z, -limit, limit) * 2 - z
            // Sphere fold: inflate inside minRadius, rescale the shell.
            let r2 = dot(z, z)
            if r2 < minR2 {
                let f = fixedR2 / minR2
                z *= f
                dr *= f
            } else if r2 < fixedR2 {
                let f = fixedR2 / r2
                z *= f
                dr *= f
            }
            // Scale + translate, derivative accumulation.
            z = z * scale + p
            dr = dr * abs(scale) + 1
            trap = min(trap, length(z))
            if dot(z, z) > 1e8 { break } // diverged — further folds are inert
        }
        return SIMD2(length(z) / abs(dr), trap)
    }

    /// Standard power-N Mandelbulb DE (triplex power formula).
    ///
    /// Per iteration: `z ← r^power·(sin θp·cos φp, sin φp·sin θp, cos θp) + p`
    /// with `θ = acos(z.z/r)`, `φ = atan2(z.y, z.x)` scaled by `power`, and the
    /// running derivative `dr = power·r^(power-1)·dr + 1`.
    /// Distance = `0.5·ln(r)·r/dr`, escape radius 4.
    ///
    /// - Parameter params: `[power]`.
    public static func mandelbulb(
        _ p: SIMD3<Float>,
        params: [Float],
        iterations: Int
    ) -> SIMD2<Float> {
        precondition(params.count >= 1, "mandelbulb params = [power]")
        let power = params[0]

        var z = p
        var dr: Float = 1
        var r = length(z)
        var trap = r

        for _ in 0..<max(0, iterations) {
            r = length(z)
            if r > 4 { break } // escape radius 4
            let rSafe = max(r, 1e-9)
            let theta = acosf(simd_clamp(z.z / rSafe, -1, 1)) * power
            let phi = atan2f(z.y, z.x) * power
            dr = powf(rSafe, power - 1) * power * dr + 1
            let zr = powf(rSafe, power)
            z = zr * SIMD3(sinf(theta) * cosf(phi),
                           sinf(phi) * sinf(theta),
                           cosf(theta)) + p
            trap = min(trap, length(z))
        }
        return SIMD2(0.5 * logf(max(r, 1e-9)) * r / dr, trap)
    }
}
