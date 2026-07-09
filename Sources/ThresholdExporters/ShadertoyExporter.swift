// ShadertoyExporter.swift — export a SceneEnvelope as a self-contained
// Shadertoy fragment shader (GLSL ES 3.0, `mainImage` entry point).
//
// This is a TRANSLATION of RaymarchCore.metal, not a transpilation: each
// built-in DE and every point-space warp op has a hand-ported GLSL body here,
// with the scene's resolved parameter values baked in as constants. If the
// MSL and this file disagree, the MSL is right (op math is normative in
// docs/op-semantics.md).
//
// Deliberate deltas from the live renderer, documented in the emitted header:
//  * Distance ops (HandAttract / ForearmCarve) and Bounding ops are skipped —
//    they exist for live hand input / room bounding, which Shadertoy has no
//    analog for.
//  * Integrator phases are baked at their snapshot value, EXCEPT phases with
//    a nonzero rate param (e.g. mandelbulb rotationPhase ← rotationSpeed),
//    which are re-animated from iTime so the export keeps moving.
//  * Output is sRGB-encoded (pow 1/2.2) — the Metal kernel writes linear and
//    lets the swapchain encode; Shadertoy expects encoded output.
//  * The hierarchical cone prepass, MetalFX aux path, and stats are omitted:
//    they are performance/telemetry machinery, not image content.

import Foundation
import ThresholdCore
import ThresholdShaderIR

public enum ShadertoyExportError: Error, CustomStringConvertible, Equatable {
    /// The envelope names a fractal key the registry doesn't know.
    case unknownFractal(String)
    /// The scene carries an embedded (externally-authored) MSL DE. MSL cannot
    /// be mechanically translated to GLSL here; port the formula by hand.
    case embeddedDEUnsupported

    public var description: String {
        switch self {
        case .unknownFractal(let key):
            return "unknown fractal type key \"\(key)\" — no built-in DE to export"
        case .embeddedDEUnsupported:
            return "scene embeds a custom MSL distance estimator; "
                + "Shadertoy export supports built-in DEs only"
        }
    }
}

public enum ShadertoyExporter {

    /// Render the scene as a complete Shadertoy "Image" tab shader.
    public static func export(_ scene: SceneEnvelope) throws -> String {
        guard scene.embeddedDE == nil else {
            throw ShadertoyExportError.embeddedDEUnsupported
        }
        guard let de = DERegistry.descriptor(forKey: scene.fractalTypeKey) else {
            throw ShadertoyExportError.unknownFractal(scene.fractalTypeKey)
        }

        // -- parameter resolution -------------------------------------------
        // Scene-lane value if persisted, else integrator snapshot, else the
        // catalog/registry default — the same precedence a fresh load applies.
        func value(_ key: String, _ fallback: Float) -> Float {
            scene.params[key]?.first ?? scene.integratorPhases[key] ?? fallback
        }
        func deValue(_ name: String, _ fallback: Float) -> Float {
            value("de.\(scene.fractalTypeKey).\(name)", fallback)
        }

        let iterations = Int(value("engine.iterations", Float(de.defaultIterations)))
        let maxSteps = Int(value("engine.maxSteps", 256))
        let maxDist = value("engine.maxDist", 64)
        let stepSafety = value("engine.stepSafety", de.stepRelaxation)
        let aoStrength = value("engine.aoStrength", 0.5)
        // modelScale = exp2(-zoom phase); camera is saved in the rebased
        // world, so scaleOctave stays bookkeeping (ScaleContext.swift).
        let modelScale = exp2(-(scene.integratorPhases["scale.zoom"] ?? 0))

        // DE params, layout order, with integrator phases re-animated from
        // iTime when their rate is nonzero (rotationPhase ← rotationSpeed).
        var deParamExprs: [String] = []
        var animated = false
        for param in de.paramLayout {
            let v = deValue(param.name, param.default)
            if let rateName = param.integratorRate {
                let rate = deValue(rateName,
                                   de.paramLayout.first { $0.name == rateName }?.default ?? 0)
                if rate != 0 {
                    let span = param.range.upperBound - param.range.lowerBound
                    deParamExprs.append(
                        "mod(\(f(v)) + \(f(rate)) * iTime, \(f(span)))")
                    animated = true
                    continue
                }
            }
            deParamExprs.append(f(v))
        }

        // -- warp stack ------------------------------------------------------
        var skipped: [String] = []
        let pointOps = scene.warpStack.filter { op in
            if WarpKind(rawValue: op.kind) != nil { return true }
            if op.kind != 0 {                     // None slots drop silently
                let names: [UInt32: String] = [
                    64: "HandAttract", 65: "ForearmCarve", 66: "Bounding",
                ]
                skipped.append(names[op.kind] ?? "kind \(op.kind)")
            }
            return false
        }

        // -- assemble ---------------------------------------------------------
        var out = header(scene: scene, de: de, skipped: skipped, animated: animated)
        out += constants(
            scene: scene, modelScale: modelScale, iterations: iterations,
            maxSteps: maxSteps, maxDist: maxDist, stepSafety: stepSafety,
            aoStrength: aoStrength, value: value)
        out += paletteBlock(scene.palette)
        out += helpers
        out += try deFunction(de, paramExprs: deParamExprs)
        out += pointOpsFunction(pointOps)
        out += mapAndShade(bubbleEnabled: value("engine.bubble.enabled", 0) >= 0.5)
        return out
    }

    // MARK: - GLSL sections

    private static func header(scene: SceneEnvelope, de: DEDescriptor,
                               skipped: [String], animated: Bool) -> String {
        var lines = [
            "// \(scene.name ?? "Untitled") — exported from Threshold",
            "// Fractal: \(de.displayName)  (\(de.equation))",
        ]
        if !skipped.isEmpty {
            lines.append("// NOTE: skipped live-input/bounding warp ops: "
                + skipped.joined(separator: ", "))
        }
        if animated {
            lines.append("// Integrator phase(s) re-animated from iTime.")
        }
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func constants(
        scene: SceneEnvelope, modelScale: Float, iterations: Int,
        maxSteps: Int, maxDist: Float, stepSafety: Float, aoStrength: Float,
        value: (String, Float) -> Float
    ) -> String {
        let cam = scene.camera
        let fovTan = tan(cam.fovYRadians * 0.5)
        return """
        const float MODEL_SCALE = \(f(modelScale));
        const float EPS_BASE    = 1.5e-3;          // ScaleContext.epsilonBase
        const int   MAX_STEPS   = \(maxSteps);
        const float MAX_DIST    = \(f(maxDist));
        const float STEP_SAFETY = \(f(stepSafety)); // over-relaxation omega
        const int   ITERATIONS  = \(iterations);
        const float AO_STRENGTH = \(f(aoStrength));

        const float GRAD_REPEAT = \(f(value("color.gradient.repeat", 1)));
        const float GRAD_OFFSET = \(f(value("color.gradient.offset", 0)));
        const float GRAD_SMOOTH = \(f(value("color.gradient.smoothing", 0)));
        const int   MAP_MODE    = \(Int(value("color.mapMode", 0)));
        const float SATURATION  = \(f(value("color.saturation", 1)));
        const float CONTRAST    = \(f(value("color.contrast", 1)));
        const float VIBRANCE    = \(f(value("color.vibrance", 0)));
        const float BRIGHTNESS  = \(f(value("color.brightness", 1)));
        const float GAMMA       = \(f(value("color.gamma", 1)));
        const float TONEMAP     = \(f(value("color.tonemap", 0)));

        const float BUBBLE_RADIUS = \(f(value("engine.bubble.radius", 1.8)));
        const float BUBBLE_SHAPE  = \(f(value("engine.bubble.shape", 0)));
        const float BUBBLE_BLEND  = \(f(value("engine.bubble.blend", 0.25)));

        const vec3  CAM_POS  = vec3(\(f(cam.position[0])), \(f(cam.position[1])), \(f(cam.position[2])));
        const vec4  CAM_QUAT = vec4(\(f(cam.orientation[0])), \(f(cam.orientation[1])), \(f(cam.orientation[2])), \(f(cam.orientation[3])));
        const float FOV_TAN  = \(f(fovTan));

        """
    }

    private static func paletteBlock(_ palette: Palette?) -> String {
        // Renderer default when the scene ships none (RenderRequest.swift
        // defaultStops — keep in sync).
        let stops: [(Float, Float, Float, Float)] = palette.map {
            $0.stops.map { ($0.red, $0.green, $0.blue, $0.position) }
        } ?? [
            (0.02, 0.02, 0.06, 0.00),
            (0.55, 0.12, 0.30, 0.30),
            (0.95, 0.55, 0.18, 0.60),
            (0.98, 0.90, 0.55, 0.85),
            (0.90, 0.98, 0.95, 1.00),
        ]
        let entries = stops
            .map { "vec4(\(f($0.0)), \(f($0.1)), \(f($0.2)), \(f($0.3)))" }
            .joined(separator: ",\n    ")
        return """
        // Gradient palette: .rgb = LINEAR color, .w = position (sorted).
        const int PAL_COUNT = \(stops.count);
        const vec4 PAL[\(stops.count)] = vec4[\(stops.count)](
            \(entries));

        """
    }

    /// Shared math helpers — line-for-line ports of RaymarchCore.metal.
    private static let helpers = """
    float threshMod(float x, float y) { return x - y * floor(x / y); }
    vec3 threshMod3(vec3 x, float y) {
        return vec3(threshMod(x.x, y), threshMod(x.y, y), threshMod(x.z, y));
    }
    vec3 perpOf(vec3 n) {
        return normalize(cross(n, (abs(n.y) < 0.9) ? vec3(0.0, 1.0, 0.0)
                                                   : vec3(1.0, 0.0, 0.0)));
    }
    vec3 rotAxis(vec3 v, vec3 n, float t) {
        float c = cos(t), s = sin(t);
        return v * c + cross(n, v) * s + n * (dot(n, v) * (1.0 - c));
    }
    float sminIQ(float x, float y, float k) {
        float h = max(k - abs(x - y), 0.0) / k;
        return min(x, y) - h * h * k * 0.25;
    }
    float smaxIQ(float x, float y, float k) { return -sminIQ(-x, -y, k); }
    vec3 readAxis(vec3 raw) {
        return (dot(raw, raw) < 1e-12) ? vec3(0.0, 1.0, 0.0) : normalize(raw);
    }
    vec3 quatRotate(vec4 q, vec3 v) {
        return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
    }

    """

    // MARK: - DE bodies (GLSL ports, params baked via P0…Pn expressions)

    private static func deFunction(_ de: DEDescriptor, paramExprs: [String]) throws -> String {
        // Bind each declared param to a named local so the DE bodies below
        // read like their MSL originals.
        let binds = zip(de.paramLayout, paramExprs)
            .map { "    float \(paramName($0.0.name)) = \($0.1);" }
            .joined(separator: "\n")
        let body: String
        switch de.key {
        case "mandelbox": body = deMandelbox(projected: false)
        case "mandelboxSphereProjection": body = deMandelbox(projected: true)
        case "mandelbulb": body = deMandelbulb(julia: false)
        case "mandelbulbJulia": body = deMandelbulb(julia: true)
        case "kleinian": body = deKleinian
        case "mengerSponge": body = deMenger
        case "quaternionJulia": body = deQuaternionJulia
        // A registered DE with no GLSL body must fail loudly, not silently
        // export a unit sphere. Guards against adding a DERegistry.builtin
        // entry and forgetting the exporter case (caught by the coverage test).
        default: throw ShadertoyExportError.unknownFractal(de.key)
        }
        return """
        // \(de.displayName): \(de.equation)
        // returns .x = distance estimate, .y = orbit trap
        vec2 deFractal(vec3 p, int iterations) {
        \(binds)
        \(body)
        }

        """
    }

    /// GLSL-identifier-safe local name for a declared DE param.
    private static func paramName(_ name: String) -> String { "P_" + name }

    private static func deMandelbox(projected: Bool) -> String {
        let proj = projected ? """

            if (P_projBlend > 0.0) {                        // per-fold projection
                    float len = length(z);
                    vec3 proj = (len > 1e-6) ? z * (P_projRadius / len)
                                             : vec3(P_projRadius, 0.0, 0.0);
                    z = mix(z, proj, clamp(P_projBlend, 0.0, 0.98));
                }
        """ : ""
        let ret = projected ? """
            float absScale = abs(P_scale);
            float dist = (length(z) - (absScale - 1.0)) / dr
                       - pow(absScale, float(1 - iterations));
            return vec2(dist, sqrt(trap2));
        """ : """
            return vec2(length(z) / abs(dr), sqrt(trap2));
        """
        return """
            float mR2 = P_minRadius * P_minRadius;
            float fR2 = P_fixedRadius * P_fixedRadius;
            vec3 z = p;
            float dr = 1.0;
            float trap2 = dot(z, z);
            for (int i = 0; i < iterations; ++i) {
                z = clamp(z, -P_foldLimit, P_foldLimit) * 2.0 - z;   // box fold
                float r2 = dot(z, z);                                // sphere fold
                if (r2 < mR2)      { float fac = fR2 / mR2; z *= fac; dr *= fac; }
                else if (r2 < fR2) { float fac = fR2 / r2;  z *= fac; dr *= fac; }\(proj)
                z = z * P_scale + p;
                dr = dr * abs(P_scale) + 1.0;
                float zz = dot(z, z);
                trap2 = min(trap2, zz);
                if (zz > 1e8) { break; }
            }
        \(ret)
        """
    }

    private static func deMandelbulb(julia: Bool) -> String {
        let phase = julia ? "0.0" : "P_rotationPhase"
        let add = julia ? "vec3(P_cX, P_cY, P_cZ)" : "p"
        let drUpdate = julia ? "dr = rp * P_power * dr;"
                             : "dr = rp * P_power * dr + 1.0;"
        let ret = julia
            ? "return vec2(0.5 * log(max(r, 1e-9)) * r / max(dr, 1e-9), trap);"
            : "return vec2(0.5 * log(max(r, 1e-9)) * r / dr, trap);"
        return """
            vec3 z = p;
            float dr = 1.0;
            float r = length(z);
            float trap = r;
            for (int i = 0; i < iterations; ++i) {
                r = length(z);
                trap = min(trap, r);
                if (r > 4.0) { break; }                              // escape radius
                float rSafe = max(r, 1e-9);
                float theta = (acos(clamp(z.z / rSafe, -1.0, 1.0)) + \(phase)) * P_power;
                float phiBase = (z.y == 0.0 && z.x == 0.0) ? 0.0 : atan(z.y, z.x);
                float phi = (phiBase + \(phase)) * P_power;
                float rp = pow(rSafe, P_power - 1.0);
                \(drUpdate)
                float zr = rp * rSafe;
                z = zr * vec3(sin(theta) * cos(phi), sin(phi) * sin(theta), cos(theta)) + \(add);
            }
            trap = min(trap, length(z));
            \(ret)
        """
    }

    private static let deKleinian = """
            vec3 mins = vec3(P_minX, P_minY, P_minZ);
            vec3 maxs = vec3(P_maxX, P_maxY, P_maxZ);
            vec3 z = p;
            float scale = 1.0;
            float trap2 = dot(z, z);
            for (int i = 0; i < iterations; ++i) {
                z = clamp(z, mins, maxs) * 2.0 - z;
                float r2 = dot(z, z);
                float k = max(P_sphereFold / max(r2, 1e-6), 1.0);
                z *= k;
                scale *= k;
                trap2 = min(trap2, dot(z, z));
            }
            float rxy = length(z.xy);
            float de = 0.7 * max(rxy - P_crossRadius,
                                 rxy * z.z / max(length(z), 1e-6)) / max(scale, 1e-6);
            return vec2(de, sqrt(trap2));
        """

    private static let deMenger = """
            vec3 offsetV = vec3(P_offsetX, P_offsetY, P_offsetZ);
            vec3 z = p;
            float dr = 1.0;
            float trap2 = dot(z, z);
            for (int i = 0; i < iterations; ++i) {
                z = abs(z);
                if (z.x < z.y) { float t = z.x; z.x = z.y; z.y = t; }
                if (z.x < z.z) { float t = z.x; z.x = z.z; z.z = t; }
                if (z.y < z.z) { float t = z.y; z.y = z.z; z.z = t; }
                vec3 offsetScaled = offsetV * (P_scale - 1.0);
                z = z * P_scale - offsetScaled;
                if (z.z < -0.5 * offsetScaled.z) { z.z += offsetScaled.z; }
                dr = dr * abs(P_scale) + 1.0;
                trap2 = min(trap2, dot(z, z));
            }
            return vec2((length(z) - 1.0) / dr, sqrt(trap2));
        """

    private static let deQuaternionJulia = """
            vec4 c = vec4(P_cX, P_cY, P_cZ, P_cW);
            vec4 q = vec4(p, 0.0);
            vec4 dq = vec4(1.0, 0.0, 0.0, 0.0);
            float trap2 = dot(q, q);
            for (int i = 0; i < iterations; ++i) {
                dq = 2.0 * vec4(
                    q.x * dq.x - q.y * dq.y - q.z * dq.z - q.w * dq.w,
                    q.x * dq.y + q.y * dq.x + q.z * dq.w - q.w * dq.z,
                    q.x * dq.z - q.y * dq.w + q.z * dq.x + q.w * dq.y,
                    q.x * dq.w + q.y * dq.z - q.z * dq.y + q.w * dq.x);
                q = vec4(
                    q.x * q.x - q.y * q.y - q.z * q.z - q.w * q.w,
                    2.0 * q.x * q.y,
                    2.0 * q.x * q.z,
                    2.0 * q.x * q.w) + c;
                float qq = dot(q, q);
                trap2 = min(trap2, qq);
                if (qq > P_threshold) { break; }
            }
            float r = max(length(q), 1e-6);
            return vec2(0.5 * r * log(r) / max(length(dq), 1e-9), sqrt(trap2));
        """

    // MARK: - Warp stack (unrolled, payloads baked)

    private static func pointOpsFunction(_ ops: [WarpOpDTO]) -> String {
        var body = ""
        for (i, op) in ops.enumerated() {
            guard let kind = WarpKind(rawValue: op.kind) else { continue }
            body += "    { // op \(i): \(kind.name)\n"
            body += pointOpBody(kind, op)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "        \($0)\n" }.joined()
            body += "    }\n"
        }
        return """
        // Warp stack (point ops), unrolled with scene payloads baked in.
        vec3 applyPointOps(vec3 p, inout float dScale) {
        \(body)    return p;
        }

        """
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func pointOpBody(_ kind: WarpKind, _ op: WarpOpDTO) -> String {
        let s = f(op.strength)
        let a = op.a, b = op.b
        let axis = "readAxis(vec3(\(f(a[0])), \(f(a[1])), \(f(a[2]))))"
        switch kind {
        case .twist: return """
            vec3 n = \(axis);
            float t = dot(p, n);
            float rp = length(p - n * t);
            p = rotAxis(p, n, \(s) * t);
            dScale *= max(1.0, sqrt(1.0 + (\(s) * rp) * (\(s) * rp)));
            """
        case .bend: return """
            vec3 n = \(axis);
            vec3 c = perpOf(n);
            float theta = \(s) * dot(p, c);
            float rp = length(p - n * dot(p, n));
            p = rotAxis(p, n, theta);
            dScale *= max(1.0, sqrt(1.0 + (\(s) * rp) * (\(s) * rp)));
            """
        case .ripple: return """
            vec3 n = \(axis);
            vec3 c = perpOf(n);
            p = p + n * (\(s) * sin(\(f(a[3])) * dot(p, c)));
            dScale *= 1.0 + abs(\(s) * \(f(a[3])));
            """
        case .mirror: return "p = mix(p, abs(p), \(s));"
        case .boxFold:
            let hom = (op.flags & 1) != 0   // OPTION_A = Hall of Mirrors
            let folded = hom
                ? "abs(threshMod3(p + \(f(a[0])), 4.0 * \(f(a[0]))) - 2.0 * \(f(a[0]))) - \(f(a[0]))"
                : "clamp(p, -\(f(a[0])), \(f(a[0]))) * 2.0 - p"
            return "vec3 folded = \(folded);\np = mix(p, folded, \(s));"
        case .planeFold: return """
            vec3 n = \(axis);
            float h = dot(p, n) - \(f(a[3]));
            if (h < 0.0) { p = mix(p, p - 2.0 * h * n, \(s)); }
            """
        case .kaleidoscope: return """
            float theta = (p.z == 0.0 && p.x == 0.0) ? 0.0 : atan(p.z, p.x);
            float r = length(p.xz);
            float w = 3.14159265358979 / \(f(a[0]));
            float tf = abs(threshMod(theta + w, 2.0 * w) - w);
            float tp = mix(theta, tf, \(s));
            p = vec3(r * cos(tp), p.y, r * sin(tp));
            """
        case .coxeter: return """
            float sp = sin(3.14159265358979 / \(f(a[0])));
            float c = cos(3.14159265358979 / \(f(a[1]))) / sp;
            vec3 n1 = vec3(1.0, 0.0, 0.0);
            vec3 n2 = vec3(-cos(3.14159265358979 / \(f(a[0]))), sp, 0.0);
            vec3 n3 = normalize(vec3(0.0, -c, sqrt(max(1e-6, 1.0 - c * c))));
            vec3 q = p;
            for (int it = 0; it < 24; ++it) {
                bool reflected = false;
                float d1 = dot(q, n1); if (d1 < 0.0) { q -= 2.0 * d1 * n1; reflected = true; }
                float d2 = dot(q, n2); if (d2 < 0.0) { q -= 2.0 * d2 * n2; reflected = true; }
                float d3 = dot(q, n3); if (d3 < 0.0) { q -= 2.0 * d3 * n3; reflected = true; }
                if (!reflected) { break; }
            }
            p = mix(p, q, \(s));
            """
        case .mengerFold: return """
            vec3 q = abs(p);
            if (q.x < q.y) { float t = q.x; q.x = q.y; q.y = t; }
            if (q.x < q.z) { float t = q.x; q.x = q.z; q.z = t; }
            if (q.y < q.z) { float t = q.y; q.y = q.z; q.z = t; }
            p = mix(p, q, \(s));
            """
        case .offsetFold: return """
            vec3 c = vec3(\(f(a[0])), \(f(a[1])), \(f(a[2])));
            p = mix(p, abs(p - c) + c, \(s));
            """
        case .sphereFold: return """
            float mR2 = \(f(a[0])) * \(f(a[0]));
            float fR2 = \(f(a[1])) * \(f(a[1]));
            float r2 = dot(p, p);
            float factor = 1.0;
            if (r2 < mR2)      { factor = fR2 / mR2; }
            else if (r2 < fR2) { factor = fR2 / r2; }
            float k = mix(1.0, factor, \(s));
            p *= k;
            dScale *= k;
            """
        case .sphereInvert: return """
            float r2 = max(dot(p, p), 1e-12);
            float k = mix(1.0, (\(f(a[0])) * \(f(a[0]))) / r2, \(s));
            p *= k;
            dScale *= k;
            """
        case .tubeFold: return """
            float mR2 = \(f(a[0])) * \(f(a[0]));
            float fR2 = \(f(a[1])) * \(f(a[1]));
            float r2 = dot(p.xz, p.xz);
            float factor = 1.0;
            if (r2 < mR2)      { factor = fR2 / mR2; }
            else if (r2 < fR2) { factor = fR2 / r2; }
            float k = mix(1.0, factor, \(s));
            p.x *= k;
            p.z *= k;
            dScale *= max(1.0, k);
            """
        case .shells: return """
            float t = \(f(a[0]));
            float r = length(p);
            float rp = abs(threshMod(r, 2.0 * t) - t);
            float k = mix(1.0, rp / max(r, 1e-9), \(s));
            p *= k;
            """
        case .scaleRepeat: return """
            float kf = \(f(a[0]));
            float r = length(p);
            float n = floor(log(max(r, 1e-9)) / log(kf));
            float m = pow(kf, n * \(s));
            p /= m;
            dScale *= 1.0 / m;
            """
        case .tiling: return """
            float c = \(f(a[0]));
            vec3 q = p;
            \(b[0] >= 0.5 ? "q.x = threshMod(p.x + 0.5 * c, c) - 0.5 * c;" : "")
            \(b[1] >= 0.5 ? "q.y = threshMod(p.y + 0.5 * c, c) - 0.5 * c;" : "")
            \(b[2] >= 0.5 ? "q.z = threshMod(p.z + 0.5 * c, c) - 0.5 * c;" : "")
            p = mix(p, q, \(s));
            """
        case .scale: return """
            float m = mix(1.0, \(f(a[0])), \(s));
            p /= m;
            dScale *= 1.0 / m;
            """
        case .sphereProject: return """
            float r = length(p);
            float rp = mix(r, \(f(a[0])), \(s));
            float k = rp / max(r, 1e-9);
            p *= k;
            dScale *= max(1.0, k);
            """
        }
    }

    // MARK: - Map + march + shade (static tail, reads the baked constants)

    private static func mapAndShade(bubbleEnabled: Bool) -> String {
        let bubble = bubbleEnabled ? """

        // Safety bubble: shape carved around the camera (legacy "safe space").
        float bubbleCube(vec3 p, float r) {
            vec3 d = abs(p) - vec3(r);
            return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
        }
        float sdSolid(vec3 p, float r, float shape) {
            float sphereDist = length(p) - r;
            float cubeDist = bubbleCube(p, r);
            return mix(sphereDist, cubeDist, clamp(shape, 0.0, 1.0));
        }
        float applySafetyBubble(float d, vec3 pos, vec3 center) {
            if (BUBBLE_BLEND < 0.001) { return d; }
            float bd = sdSolid(pos - center, BUBBLE_RADIUS, BUBBLE_SHAPE);
            float a = d, b = -bd, k = 0.1;
            float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
            float dBubbled = mix(a, b, h) + k * h * (1.0 - h);
            return BUBBLE_BLEND >= 1.0 ? dBubbled : mix(d, dBubbled, BUBBLE_BLEND);
        }
        """ : """

        float applySafetyBubble(float d, vec3 pos, vec3 center) { return d; }
        """
        return """
        // The single scene distance function: point ops -> DE -> world units.
        vec2 mapScene(vec3 worldP, float iterScale) {
            float dScale = MODEL_SCALE;
            vec3 q = applyPointOps(worldP * MODEL_SCALE, dScale);
            int iters = (iterScale >= 1.0)
                ? ITERATIONS
                : max(1, int(float(ITERATIONS) * iterScale));
            vec2 de = deFractal(q, iters);
            return vec2(de.x / dScale, de.y);
        }
        \(bubble)
        vec3 calcNormal(vec3 pos, float h, float d0) {
            vec3 g = vec3(
                mapScene(pos + vec3(h, 0.0, 0.0), 0.6).x,
                mapScene(pos + vec3(0.0, h, 0.0), 0.6).x,
                mapScene(pos + vec3(0.0, 0.0, h), 0.6).x) - d0;
            float len = length(g);
            return (len > 1e-12) ? g / len : vec3(0.0, 1.0, 0.0);
        }

        float cheapAO(vec3 pos, vec3 n, float featureScale) {
            float h1 = 0.16 * featureScale;
            float h2 = 0.55 * featureScale;
            float d1 = mapScene(pos + n * h1, 0.5).x;
            float d2 = mapScene(pos + n * h2, 0.5).x;
            float occ = (h1 - d1) * 1.45 + (h2 - d2) * 0.65;
            return clamp(1.0 - 1.5 * AO_STRENGTH * occ, 0.0, 1.0);
        }

        vec3 samplePalette(float t) {
            float u = t * max(GRAD_REPEAT, 1.0) + GRAD_OFFSET;
            u = u - floor(u);
            if (PAL_COUNT == 1 || u <= PAL[0].w) { return PAL[0].xyz; }
            if (u >= PAL[PAL_COUNT - 1].w) { return PAL[PAL_COUNT - 1].xyz; }
            for (int i = 0; i + 1 < PAL_COUNT; ++i) {
                float p0 = PAL[i].w;
                float p1 = PAL[i + 1].w;
                if (u >= p0 && u <= p1) {
                    float fr = (u - p0) / max(p1 - p0, 1e-6);
                    float fs = fr * fr * (3.0 - 2.0 * fr);
                    fr = mix(fr, fs, clamp(GRAD_SMOOTH, 0.0, 1.0));
                    return mix(PAL[i].xyz, PAL[i + 1].xyz, fr);
                }
            }
            return PAL[PAL_COUNT - 1].xyz;
        }

        vec3 acesFilmic(vec3 x) {
            return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14),
                         0.0, 1.0);
        }

        vec3 applyGrading(vec3 c) {
            c = max(c, 0.0) * BRIGHTNESS;
            float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
            c = mix(vec3(luma), c, SATURATION);
            float mx = max(c.r, max(c.g, c.b));
            float mn = min(c.r, min(c.g, c.b));
            float vib = VIBRANCE * (1.0 - (mx - mn));
            c = mix(vec3(luma), c, 1.0 + vib);
            c = (c - 0.5) * CONTRAST + 0.5;
            c = max(c, 0.0);
            if (TONEMAP > 0.0) { c = mix(c, acesFilmic(c), clamp(TONEMAP, 0.0, 1.0)); }
            if (GAMMA != 1.0) { c = pow(max(c, vec3(0.0)), vec3(1.0 / max(GAMMA, 1e-3))); }
            return clamp(c, 0.0, 1.0);
        }

        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 ndc = fragCoord / iResolution.xy * 2.0 - 1.0;   // y up
            float aspect = iResolution.x / iResolution.y;
            vec3 ro = CAM_POS;
            vec3 rd = quatRotate(CAM_QUAT, normalize(
                vec3(ndc.x * aspect * FOV_TAN, ndc.y * FOV_TAN, -1.0)));
            float featureScale = 1.0 / max(MODEL_SCALE, 1e-6);

            // Enhanced sphere tracing (Keinert et al.): STEP_SAFETY doubles as
            // the over-relaxation omega with an overshoot-retreat guard.
            float t = 0.0;
            float hitEps = 0.0;
            float trap = 0.0;
            float hitRadius = 0.0;
            bool hit = false;
            float omega = STEP_SAFETY;
            float prevRadius = 0.0;
            float stepLength = 0.0;

            for (int i = 0; i < MAX_STEPS; ++i) {
                if (t > MAX_DIST) { break; }
                vec3 pos = ro + rd * t;
                vec2 dm = mapScene(pos, 1.0);
                dm.x = applySafetyBubble(dm.x, pos, ro);
                float radius = dm.x;
                bool sorFail = (omega > 1.0) && (radius + prevRadius) < stepLength;
                if (sorFail) {
                    stepLength -= omega * stepLength;
                    omega = 1.0;
                } else {
                    stepLength = radius * omega;
                }
                prevRadius = radius;
                hitEps = EPS_BASE * t;
                if (!sorFail && radius < hitEps) {
                    hit = true; trap = dm.y; hitRadius = radius; break;
                }
                t += stepLength;
                if (t > MAX_DIST) { break; }
            }

            vec3 c = vec3(0.0);                                  // miss: black
            if (hit) {
                vec3 pos = ro + rd * t;
                float nEps = max(hitEps, 1e-4 * featureScale);
                vec3 n = calcNormal(pos, nEps, hitRadius);
                vec3 lightDir = normalize(vec3(1.0, 0.8, 0.6));
                float lambert = max(dot(n, lightDir), 0.0);
                float depth = clamp(t / max(MAX_DIST, 1e-3), 0.0, 1.0);
                float facing = clamp(0.5 + 0.5 * dot(n, -rd), 0.0, 1.0);
                float angle = atan(pos.y, pos.x) * 0.15915494 + 0.5;
                float tMap = (MAP_MODE == 1) ? depth
                           : (MAP_MODE == 2) ? facing
                           : (MAP_MODE == 3) ? 0.5 * fract(trap) + 0.5 * depth
                           : (MAP_MODE == 4) ? angle
                           : trap;
                vec3 albedo = samplePalette(tMap);
                float occ = (AO_STRENGTH > 0.0) ? cheapAO(pos, n, featureScale) : 1.0;
                c = applyGrading(albedo * (lambert + 0.2) * occ);
            }
            // The Metal kernel writes LINEAR and the display encodes; here we
            // encode to sRGB-ish ourselves for Shadertoy's canvas.
            fragColor = vec4(pow(c, vec3(1.0 / 2.2)), 1.0);
        }
        """
    }

    // MARK: - misc

    /// Point-space warp kinds (ABI ThreshWarpKind, kind < 64) the exporter
    /// can translate. Distance ops (>= 64) and Bounding are skipped.
    private enum WarpKind: UInt32 {
        case twist = 1, bend = 2, ripple = 3, mirror = 4, boxFold = 5
        case planeFold = 6, kaleidoscope = 7, coxeter = 8, mengerFold = 9
        case offsetFold = 10, sphereFold = 11, sphereInvert = 12, tubeFold = 13
        case shells = 14, scaleRepeat = 15, tiling = 16, scale = 17
        case sphereProject = 18

        var isPointOp: Bool { true }
        var name: String { String(describing: self) }
    }

    /// GLSL float literal: finite, always with a decimal point or exponent.
    private static func f(_ v: Float) -> String {
        guard v.isFinite else { return "0.0" }
        var s = String(format: "%.9g", v)
        if !s.contains(".") && !s.contains("e") && !s.contains("E") {
            s += ".0"
        }
        return s
    }
}
