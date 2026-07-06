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
//   mandelbox       params = [scale, minRadius, fixedRadius, foldLimit]
//   mandelbulb      params = [power]
//   kleinian        params = [minX, minY, minZ, sphereFold, maxX, maxY, maxZ, crossRadius]
//   menger          params = [scale, offsetX, offsetY, offsetZ]
//   quaternionJulia params = [cX, cY, cZ, cW, threshold]
//   mandelbulbJulia params = [power, cX, cY, cZ]
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

    /// Mandelbox with the shipping app's PER-FOLD sphere projection — the CPU
    /// oracle for `de_mandelboxSphereProjection`. Each iteration, after the
    /// sphere fold, the folded point is blended toward a sphere of radius
    /// `projRadius`: `z ← mix(z, projRadius·z/|z|, blend)` before the
    /// scale+offset (Shaders.metal MAP_ITERATION_PROJ). The projection does not
    /// touch the running derivative, matching the app.
    ///
    /// Distance is the FULL Rrmin mandelbox estimate
    /// `(|z| − (|s|−1))/dr − |s|^(1−iterations)` — not the plain `|z|/dr` the
    /// base mandelbox uses — mirroring the tunnelling fix in
    /// `de_mandelboxSphereProjection` (RaymarchCore.metal).
    ///
    /// - Parameter params: `[scale, minRadius, fixedRadius, foldLimit, projBlend, projRadius]`.
    public static func mandelboxSphereProjection(
        _ p: SIMD3<Float>,
        params: [Float],
        iterations: Int
    ) -> SIMD2<Float> {
        precondition(params.count >= 6,
                     "mandelboxSphereProjection params = [scale, minRadius, fixedRadius, foldLimit, projBlend, projRadius]")
        let scale = params[0]
        let minR2 = params[1] * params[1]
        let fixedR2 = params[2] * params[2]
        let limit = SIMD3<Float>(repeating: params[3])
        let blend = min(max(params[4], 0), 0.98)
        let projR = params[5]

        var z = p
        var dr: Float = 1
        var trap = length(p)
        for _ in 0..<max(0, iterations) {
            z = simd_clamp(z, -limit, limit) * 2 - z          // box fold
            let r2 = dot(z, z)                                 // sphere fold
            if r2 < minR2 {
                let f = fixedR2 / minR2; z *= f; dr *= f
            } else if r2 < fixedR2 {
                let f = fixedR2 / r2; z *= f; dr *= f
            }
            if blend > 0 {                                     // per-fold projection
                let len = length(z)
                let proj = len > 1e-6 ? z * (projR / len) : SIMD3<Float>(projR, 0, 0)
                z = simd_mix(z, proj, SIMD3<Float>(repeating: blend))
            }
            z = z * scale + p
            dr = dr * abs(scale) + 1
            trap = min(trap, length(z))
            if dot(z, z) > 1e8 { break }
        }
        // Full Rrmin estimate, mirroring de_mandelboxSphereProjection: the
        // (|s|-1) and |s|^(1-iter) corrections drive the estimate negative
        // inside the surface where the per-fold projection explodes dr — the
        // plain |z|/dr stays tiny-positive there and the march never lands.
        let absScale = abs(scale)
        let dist = (length(z) - (absScale - 1)) / dr
            - powf(absScale, Float(1 - iterations))
        return SIMD2(dist, trap)
    }

    /// Standard power-N Mandelbulb DE (triplex power formula).
    ///
    /// Per iteration: `z ← r^power·(sin θp·cos φp, sin φp·sin θp, cos θp) + p`
    /// with `θ = acos(z.z/r)`, `φ = atan2(z.y, z.x)` scaled by `power`, and the
    /// running derivative `dr = power·r^(power-1)·dr + 1`.
    /// Distance = `0.5·ln(r)·r/dr`, escape radius 4.
    ///
    /// - Parameter params: `[power, rotationSpeed, rotationPhase]`. Only
    ///   `power` (index 0) and `rotationPhase` (index 2) are read; the rate at
    ///   index 1 is CPU-side integrator input, never sampled by the DE. Shorter
    ///   arrays (legacy `[power]`) default the rotation to 0.
    public static func mandelbulb(
        _ p: SIMD3<Float>,
        params: [Float],
        iterations: Int
    ) -> SIMD2<Float> {
        precondition(params.count >= 1, "mandelbulb params = [power, rotationSpeed, rotationPhase]")
        let power = params[0]
        // Polar rotation offset (radians), added to θ and φ before ×power. At 0
        // this is byte-identical to the un-rotated bulb (x + 0 is exact).
        let rotationPhase = params.count > 2 ? params[2] : 0

        var z = p
        var dr: Float = 1
        var r = length(z)
        var trap = r

        for _ in 0..<max(0, iterations) {
            r = length(z)
            if r > 4 { break } // escape radius 4
            let rSafe = max(r, 1e-9)
            let theta = (acosf(simd_clamp(z.z / rSafe, -1, 1)) + rotationPhase) * power
            let phi = (atan2f(z.y, z.x) + rotationPhase) * power
            dr = powf(rSafe, power - 1) * power * dr + 1
            let zr = powf(rSafe, power)
            z = zr * SIMD3(sinf(theta) * cosf(phi),
                           sinf(phi) * sinf(theta),
                           cosf(theta)) + p
            trap = min(trap, length(z))
        }
        return SIMD2(0.5 * logf(max(r, 1e-9)) * r / dr, trap)
    }

    /// Knighty's Pseudo Kleinian: per iteration a two-sided box fold
    /// (`2·clamp(z, mins, maxs) − z`) then a one-sided sphere fold
    /// (`k = max(sphereFold/r², 1)`), with a cylindrical cross-section DE
    /// `0.7·max(r_xy − crossR, r_xy·z/|z|) / scale`.
    ///
    /// - Parameter params: `[minX, minY, minZ, sphereFold, maxX, maxY, maxZ, crossRadius]`
    ///   (the ORIGINAL app's formulaParamValues[0...7] order — normative for
    ///   the legacy migration).
    public static func kleinian(
        _ p: SIMD3<Float>,
        params: [Float],
        iterations: Int
    ) -> SIMD2<Float> {
        precondition(params.count >= 8,
                     "kleinian params = [minX, minY, minZ, sphereFold, maxX, maxY, maxZ, crossRadius]")
        let mins = SIMD3(params[0], params[1], params[2])
        let sphereFold = params[3]
        let maxs = SIMD3(params[4], params[5], params[6])
        let crossR = params[7]

        var z = p
        var scale: Float = 1
        var trap = length(z)

        for _ in 0..<max(0, iterations) {
            z = simd_clamp(z, mins, maxs) * 2 - z
            let r2 = dot(z, z)
            let k = max(sphereFold / max(r2, 1e-6), 1)
            z *= k
            scale *= k
            trap = min(trap, length(z))
        }

        let rxy = length(SIMD2(z.x, z.y))
        let de = 0.7 * max(rxy - crossR, rxy * z.z / max(length(z), 1e-6))
            / max(scale, 1e-6)
        return SIMD2(de, trap)
    }

    /// Classic Menger sponge: abs-fold, descending coordinate sort,
    /// `z ← z·scale − offset·(scale−1)` with the z-axis conditional refold.
    /// Distance = (|z| − 1) / dr.
    ///
    /// - Parameter params: `[scale, offsetX, offsetY, offsetZ]`.
    public static func menger(
        _ p: SIMD3<Float>,
        params: [Float],
        iterations: Int
    ) -> SIMD2<Float> {
        precondition(params.count >= 4, "menger params = [scale, offsetX, offsetY, offsetZ]")
        let scale = params[0]
        let offset = SIMD3(params[1], params[2], params[3])

        var z = p
        var dr: Float = 1
        var trap = length(z)

        for _ in 0..<max(0, iterations) {
            z = abs(z)
            // Sort so z.x ≥ z.y ≥ z.z.
            if z.x < z.y { z = SIMD3(z.y, z.x, z.z) }
            if z.x < z.z { z = SIMD3(z.z, z.y, z.x) }
            if z.y < z.z { z = SIMD3(z.x, z.z, z.y) }

            let offsetScaled = offset * (scale - 1)
            z = z * scale - offsetScaled
            if z.z < -0.5 * offsetScaled.z {
                z.z += offsetScaled.z
            }
            dr = dr * abs(scale) + 1
            trap = min(trap, length(z))
        }
        return SIMD2((length(z) - 1) / dr, trap)
    }

    /// Quaternion Julia set: `q ← q² + c` from `q₀ = (p, 0)` with the running
    /// derivative quaternion `dq ← 2·q·dq`. Distance = `0.5·|q|·ln|q| / |dq|`,
    /// escape when `|q|² > threshold`.
    ///
    /// - Parameter params: `[cX, cY, cZ, cW, threshold]`.
    public static func quaternionJulia(
        _ p: SIMD3<Float>,
        params: [Float],
        iterations: Int
    ) -> SIMD2<Float> {
        precondition(params.count >= 5, "quaternionJulia params = [cX, cY, cZ, cW, threshold]")
        let c = SIMD4(params[0], params[1], params[2], params[3])
        let threshold = params[4]

        var q = SIMD4(p.x, p.y, p.z, 0)
        var dq = SIMD4<Float>(1, 0, 0, 0)
        var trap = length(q)

        for _ in 0..<max(0, iterations) {
            dq = 2 * SIMD4(
                q.x * dq.x - q.y * dq.y - q.z * dq.z - q.w * dq.w,
                q.x * dq.y + q.y * dq.x + q.z * dq.w - q.w * dq.z,
                q.x * dq.z - q.y * dq.w + q.z * dq.x + q.w * dq.y,
                q.x * dq.w + q.y * dq.z - q.z * dq.y + q.w * dq.x)
            q = SIMD4(
                q.x * q.x - q.y * q.y - q.z * q.z - q.w * q.w,
                2 * q.x * q.y,
                2 * q.x * q.z,
                2 * q.x * q.w) + c
            trap = min(trap, length(q))
            if dot(q, q) > threshold { break }
        }

        let r = max(length(q), 1e-6)
        return SIMD2(0.5 * r * logf(r) / max(length(dq), 1e-9), trap)
    }

    /// Julia-mode Mandelbulb: the mandelbulb triplex-power iteration with a
    /// fixed additive constant `c` instead of `p` (and NO `+1` derivative
    /// term — Julia sets iterate a fixed map, `dr = power·r^(power−1)·dr`).
    /// Escape radius 4, distance `0.5·ln(r)·r/dr`.
    ///
    /// - Parameter params: `[power, cX, cY, cZ]`.
    public static func mandelbulbJulia(
        _ p: SIMD3<Float>,
        params: [Float],
        iterations: Int
    ) -> SIMD2<Float> {
        precondition(params.count >= 4, "mandelbulbJulia params = [power, cX, cY, cZ]")
        let power = params[0]
        let c = SIMD3(params[1], params[2], params[3])

        var z = p
        var dr: Float = 1
        var r = length(z)
        var trap = r

        for _ in 0..<max(0, iterations) {
            r = length(z)
            if r > 4 { break }
            let rSafe = max(r, 1e-9)
            let theta = acosf(simd_clamp(z.z / rSafe, -1, 1)) * power
            let phi = atan2f(z.y, z.x) * power
            dr = powf(rSafe, power - 1) * power * dr
            let zr = powf(rSafe, power)
            z = zr * SIMD3(sinf(theta) * cosf(phi),
                           sinf(phi) * sinf(theta),
                           cosf(theta)) + c
            trap = min(trap, length(z))
        }
        return SIMD2(0.5 * logf(max(r, 1e-9)) * r / max(dr, 1e-9), trap)
    }
}
