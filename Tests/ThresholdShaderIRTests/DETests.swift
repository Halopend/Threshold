// DETests.swift — sanity for the CPU reference distance estimators and the
// DE registry / catalog registration path.

import simd
import Testing
import ThresholdCore
import ThresholdShaderABI
@testable import ThresholdShaderIR

private let boxParams: [Float] = [2.0, 0.25, 1.0, 1.0] // scale, minR, fixedR, foldLimit
private let bulbParams: [Float] = [8.0] // power

@Suite("Reference DEs")
struct ReferenceDETests {
    @Test("mandelbulb: positive distance far away, shrinking along a ray toward the set")
    func bulbRayMonotone() {
        let radii: [Float] = [3.0, 2.5, 2.0, 1.7, 1.5]
        var previous = Float.greatestFiniteMagnitude
        for r in radii {
            let d = ReferenceDEs.mandelbulb(SIMD3(0, 0, r), params: bulbParams, iterations: 12).x
            #expect(d > 0, "exterior distance at r=\(r) must be positive, got \(d)")
            #expect(d < previous + 1e-4, "distance must shrink approaching the set (r=\(r))")
            previous = d
        }
        // Far away the estimate is comfortably large…
        #expect(ReferenceDEs.mandelbulb(SIMD3(0, 0, 3), params: bulbParams, iterations: 12).x > 0.5)
        // …and near the surface it is small.
        #expect(ReferenceDEs.mandelbulb(SIMD3(0, 0, 1.3), params: bulbParams, iterations: 12).x < 0.5)
    }

    @Test("mandelbulb: distance underestimates the true surface gap along the ray")
    func bulbLowerBound() {
        // Walk the ray using the DE (sphere tracing); it must never step past
        // the point where the DE goes non-positive (the set boundary band).
        var t: Float = 0
        let origin = SIMD3<Float>(0, 0, 3)
        let dir = SIMD3<Float>(0, 0, -1)
        var steps = 0
        while steps < 200 {
            let d = ReferenceDEs.mandelbulb(origin + dir * t, params: bulbParams, iterations: 12).x
            if d < 1e-3 { break }
            t += d
            steps += 1
        }
        // On the +z axis the orbit is the scalar dynamics z → z⁸ + c, bounded
        // for c ≤ c* = max(x − x⁸) ≈ 0.650 — the bulb's polar pinch. The
        // march must converge to that boundary band without overshooting
        // into the interior (a lower-bound DE never steps past the surface).
        let hit = origin + dir * t
        #expect(steps < 200, "sphere trace failed to converge")
        #expect(simd_length(hit) > 0.62, "marched into the interior: |p|=\(simd_length(hit))")
        #expect(simd_length(hit) < 1.6, "stopped implausibly far out: |p|=\(simd_length(hit))")
    }

    @Test("mandelbox: finite sane values and non-negative traps on a sample grid")
    func boxGridSane() {
        var count = 0
        let coords: [Float] = [-6, -3.6, -1.2, 0, 1.2, 3.6, 6]
        for x in coords {
            for y in coords {
                for z in coords {
                    let out = ReferenceDEs.mandelbox(SIMD3(x, y, z), params: boxParams, iterations: 12)
                    #expect(out.x.isFinite, "non-finite distance at (\(x),\(y),\(z))")
                    #expect(abs(out.x) < 1000, "implausible distance \(out.x) at (\(x),\(y),\(z))")
                    #expect(out.y.isFinite && out.y >= 0, "bad trap \(out.y) at (\(x),\(y),\(z))")
                    count += 1
                }
            }
        }
        #expect(count == coords.count * coords.count * coords.count)
        // Far outside the structure the distance is strictly positive.
        #expect(ReferenceDEs.mandelbox(SIMD3(8, 8, 8), params: boxParams, iterations: 12).x > 0)
    }

    @Test("finite-difference gradient magnitude <= ~1.05 at exterior points")
    func gradientBounded() {
        var rng = SplitMix64(seed: 51)
        let h: Float = 1e-3

        func gradientNorm(_ f: (SIMD3<Float>) -> Float, _ p: SIMD3<Float>) -> Float {
            var g = SIMD3<Float>.zero
            for i in 0..<3 {
                var hi = p, lo = p
                hi[i] += h
                lo[i] -= h
                g[i] = (f(hi) - f(lo)) / (2 * h)
            }
            return simd_length(g)
        }

        var checkedBox = 0
        var checkedBulb = 0
        for _ in 0..<2000 where checkedBox < 60 || checkedBulb < 60 {
            // Mandelbox exterior sample (the scale-2 box's structure reaches
            // out to |p| ≈ 6, so sample beyond it for solidly exterior points).
            if checkedBox < 60 {
                let p = rng.unitVector() * rng.float(in: 6.5...10)
                let d = ReferenceDEs.mandelbox(p, params: boxParams, iterations: 12).x
                if d > 0.05 {
                    checkedBox += 1
                    let g = gradientNorm({ ReferenceDEs.mandelbox($0, params: boxParams, iterations: 12).x }, p)
                    #expect(g <= 1.05, "mandelbox |∇d| = \(g) at \(p)")
                }
            }
            // Mandelbulb exterior sample.
            if checkedBulb < 60 {
                let p = rng.unitVector() * rng.float(in: 1.6...3)
                let d = ReferenceDEs.mandelbulb(p, params: bulbParams, iterations: 12).x
                if d > 0.05 {
                    checkedBulb += 1
                    let g = gradientNorm({ ReferenceDEs.mandelbulb($0, params: bulbParams, iterations: 12).x }, p)
                    #expect(g <= 1.05, "mandelbulb |∇d| = \(g) at \(p)")
                }
            }
        }
        #expect(checkedBox >= 60 && checkedBulb >= 60,
                "sampled: box=\(checkedBox) bulb=\(checkedBulb)")
    }

    @Test("orbit trap channel: finite, >= 0, and <= |p| initially")
    func trapChannel() {
        var rng = SplitMix64(seed: 52)
        for _ in 0..<100 {
            let p = rng.point(in: -3...3)
            let box = ReferenceDEs.mandelbox(p, params: boxParams, iterations: 12)
            let bulb = ReferenceDEs.mandelbulb(p, params: bulbParams, iterations: 12)
            for trap in [box.y, bulb.y] {
                #expect(trap.isFinite && trap >= 0)
                // Trap is the min |z| over the orbit, seeded with |p|.
                #expect(trap <= simd_length(p) + 1e-5)
            }
        }
    }

    @Test("iteration count refines the estimate near the set, and 0 iterations is benign")
    func iterationBehavior() {
        let p = SIMD3<Float>(0, 0, 1.4)
        let coarse = ReferenceDEs.mandelbulb(p, params: bulbParams, iterations: 2).x
        let fine = ReferenceDEs.mandelbulb(p, params: bulbParams, iterations: 16).x
        #expect(coarse.isFinite && fine.isFinite)
        #expect(fine <= coarse + 1e-4, "more iterations must not loosen the bound")
        // Zero iterations: no orbit — still finite, no crash.
        #expect(ReferenceDEs.mandelbox(p, params: boxParams, iterations: 0).x.isFinite)
        #expect(ReferenceDEs.mandelbulb(p, params: bulbParams, iterations: 0).x.isFinite)
    }
}

@Suite("DE registry")
struct DERegistryTests {
    @Test("builtin table: indices, keys, MSL names, layouts")
    func builtinTable() {
        #expect(DERegistry.builtin.count == 6)

        let box = DERegistry.builtin[0]
        #expect(box.index == 0)
        #expect(box.key == "mandelbox")
        #expect(box.mslFunctionName == "de_mandelbox")
        #expect(box.displayName == "Mandelbox")
        #expect(!box.equation.isEmpty)
        #expect(box.paramLayout.map(\.name) == ["scale", "minRadius", "fixedRadius", "foldLimit"])
        #expect(box.paramLayout.map(\.default) == [2.0, 0.25, 1.0, 1.0])
        #expect(box.defaultIterations == 12)

        let bulb = DERegistry.builtin[1]
        #expect(bulb.index == 1)
        #expect(bulb.key == "mandelbulb")
        #expect(bulb.mslFunctionName == "de_mandelbulb")
        #expect(bulb.paramLayout.map(\.name) == ["power"])
        #expect(bulb.paramLayout.first?.default == 8.0)

        // Structural invariants for the whole table: index == position
        // (the visible-function-table contract), keys and MSL names unique.
        for (position, descriptor) in DERegistry.builtin.enumerated() {
            #expect(descriptor.index == UInt32(position),
                    "\(descriptor.key) index \(descriptor.index) != table position \(position)")
        }
        #expect(Set(DERegistry.builtin.map(\.key)).count == DERegistry.builtin.count)
        #expect(Set(DERegistry.builtin.map(\.mslFunctionName)).count == DERegistry.builtin.count)

        // Defaults sit inside their declared ranges.
        for descriptor in DERegistry.builtin {
            for param in descriptor.paramLayout {
                #expect(param.range.contains(param.default),
                        "\(descriptor.key).\(param.name) default outside range")
            }
        }

        // The 2026-07 additions: param layouts are load-bearing (scene files
        // + the legacy migration's formulaParamValues order).
        #expect(DERegistry.descriptor(forKey: "kleinian")?.paramLayout.map(\.name)
            == ["minX", "minY", "minZ", "sphereFold", "maxX", "maxY", "maxZ", "crossRadius"])
        #expect(DERegistry.descriptor(forKey: "mengerSponge")?.paramLayout.map(\.name)
            == ["scale", "offsetX", "offsetY", "offsetZ"])
        #expect(DERegistry.descriptor(forKey: "quaternionJulia")?.paramLayout.map(\.name)
            == ["cX", "cY", "cZ", "cW", "threshold"])
        #expect(DERegistry.descriptor(forKey: "mandelbulbJulia")?.paramLayout.map(\.name)
            == ["power", "cX", "cY", "cZ"])

        // Lookups.
        #expect(DERegistry.descriptor(forKey: "mandelbox")?.index == 0)
        #expect(DERegistry.descriptor(forIndex: 1)?.key == "mandelbulb")
        #expect(DERegistry.descriptor(forKey: "nope") == nil)
        #expect(DERegistry.descriptor(forIndex: 99) == nil)
    }

    @Test("declared defaults drive the reference DEs to sane values")
    func defaultsMatchReference() {
        let box = DERegistry.descriptor(forKey: "mandelbox")!
        let boxOut = ReferenceDEs.mandelbox(
            SIMD3(0, 0, 5),
            params: box.paramLayout.map(\.default),
            iterations: box.defaultIterations)
        #expect(boxOut.x > 0 && boxOut.x.isFinite)

        let bulb = DERegistry.descriptor(forKey: "mandelbulb")!
        let bulbOut = ReferenceDEs.mandelbulb(
            SIMD3(0, 0, 2),
            params: bulb.paramLayout.map(\.default),
            iterations: bulb.defaultIterations)
        #expect(bulbOut.x > 0 && bulbOut.x.isFinite)
    }

    @Test("catalog registration mints de.{key}.{name} entries in layout order")
    func catalogRegistration() throws {
        let catalog = Catalog()
        let box = DERegistry.descriptor(forKey: "mandelbox")!
        let slots = try box.registerParams(into: catalog)
        #expect(slots.count == box.paramLayout.count)

        let layout = catalog.freeze(dynamicArenaSlots: 0)
        for (offset, param) in box.paramLayout.enumerated() {
            let key = ParamKey.de(box.key, param.name)
            let entry = layout.entry(for: key)
            #expect(entry != nil, "missing catalog entry \(key)")
            #expect(entry?.slot == slots[offset])
            #expect(entry?.spec.range == param.range)
            #expect(entry?.spec.defaultValue == [param.default])
            #expect(entry?.spec.kind == .float)
        }
        // Slots are consecutive in layout order (scalar params).
        #expect(slots == Array(slots[0]..<(slots[0] + slots.count)))
        // Key spelling goes through the sanctioned factory.
        #expect(ParamKey.de("mandelbox", "scale").rawValue == "de.mandelbox.scale")

        // Duplicate registration throws (recoverable, per Catalog contract).
        #expect(throws: CatalogError.duplicateKey(ParamKey.de("mandelbox", "scale"))) {
            try box.registerParams(into: catalog)
        }
    }

    @Test("encoder convention: GPU slice = declared params + [iterations] LAST")
    func paramSliceConvention() {
        let box = DERegistry.descriptor(forKey: "mandelbox")!
        let slice = box.makeParamSlice(values: [2.5, 0.3, 1.1, 0.9], iterations: 20)
        #expect(slice == [2.5, 0.3, 1.1, 0.9, 20.0])
        #expect(slice.count == box.paramLayout.count + 1)

        let defaults = box.defaultParamSlice()
        #expect(defaults == [2.0, 0.25, 1.0, 1.0, 12.0])
        #expect(defaults.last == Float(box.defaultIterations))

        let bulb = DERegistry.descriptor(forKey: "mandelbulb")!
        #expect(bulb.defaultParamSlice() == [8.0, 12.0])
    }
}
