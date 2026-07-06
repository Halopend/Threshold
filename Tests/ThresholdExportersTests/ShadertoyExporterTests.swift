// ShadertoyExporterTests — string-level contract tests for the GLSL export.
// No GLSL compiler is available in CI, so these assert structure: entry
// point, baked constants, balanced braces, no MSL-isms, per-DE coverage.

import Testing
import ThresholdCore
import ThresholdShaderIR
@testable import ThresholdExporters

private func scene(
    fractal: String = "mandelbox",
    params: [String: [Float]] = [:],
    warpStack: [WarpOpDTO] = [],
    embeddedDE: EmbeddedDE? = nil
) -> SceneEnvelope {
    SceneEnvelope(
        version: 1, name: "Test Scene", fractalTypeKey: fractal,
        embeddedDE: embeddedDE, params: params, warpStack: warpStack)
}

private func balancedBraces(_ s: String) -> Bool {
    var depth = 0
    for ch in s {
        if ch == "{" { depth += 1 }
        if ch == "}" { depth -= 1; if depth < 0 { return false } }
    }
    return depth == 0
}

@Suite struct ShadertoyExporterTests {

    @Test func exportsMainImageAndMarchSkeleton() throws {
        let glsl = try ShadertoyExporter.export(scene())
        #expect(glsl.contains("void mainImage(out vec4 fragColor, in vec2 fragCoord)"))
        #expect(glsl.contains("vec2 deFractal(vec3 p, int iterations)"))
        #expect(glsl.contains("vec2 mapScene(vec3 worldP, float iterScale)"))
        #expect(glsl.contains("vec3 applyPointOps(vec3 p, inout float dScale)"))
        #expect(balancedBraces(glsl))
    }

    @Test func everyBuiltinDEExports() throws {
        for de in DERegistry.builtin {
            let glsl = try ShadertoyExporter.export(scene(fractal: de.key))
            #expect(glsl.contains(de.displayName), "header names \(de.key)")
            #expect(balancedBraces(glsl), "balanced braces for \(de.key)")
            // No MSL leakage.
            #expect(!glsl.contains("float3"))
            #expect(!glsl.contains("fabs("))
            #expect(!glsl.contains("atan2("))
            #expect(!glsl.contains("thread "))
        }
    }

    @Test func bakesSceneParamValues() throws {
        let glsl = try ShadertoyExporter.export(scene(params: [
            "de.mandelbox.scale": [-2.5],
            "engine.maxDist": [32],
            "color.saturation": [1.5],
        ]))
        #expect(glsl.contains("-2.5"))
        #expect(glsl.contains("MAX_DIST    = 32.0"))
        #expect(glsl.contains("SATURATION  = 1.5"))
    }

    @Test func integerLiteralsGetDecimalPoints() throws {
        let glsl = try ShadertoyExporter.export(scene(params: [
            "de.mandelbox.foldLimit": [2],
        ]))
        // The baked param binds as a float literal, not a bare int.
        #expect(glsl.contains("P_foldLimit = 2.0"))
    }

    @Test func warpStackUnrollsPointOpsAndSkipsDistanceOps() throws {
        let stack = [
            WarpOpDTO(kind: 1, strength: 0.5,
                      a: [0, 1, 0, 0], b: [0, 0, 0, 0]),        // Twist
            WarpOpDTO(kind: 64, strength: 1.0,
                      a: [0, 0, 0, 0.2], b: [1, 0.1, 0, 0]),    // HandAttract
        ]
        let glsl = try ShadertoyExporter.export(scene(warpStack: stack))
        #expect(glsl.contains("op 0: twist"))
        #expect(glsl.contains("rotAxis(p, n, 0.5 * t)"))
        #expect(glsl.contains("skipped live-input/bounding warp ops: HandAttract"))
        #expect(!glsl.contains("HandAttract(")) // not emitted as code
    }

    @Test func animatedIntegratorPhaseUsesITime() throws {
        let glsl = try ShadertoyExporter.export(scene(
            fractal: "mandelbulb",
            params: ["de.mandelbulb.rotationSpeed": [0.4]]))
        #expect(glsl.contains("iTime"))
        #expect(glsl.contains("0.4"))
    }

    @Test func staticSceneHasNoITimeInDE() throws {
        let glsl = try ShadertoyExporter.export(scene(fractal: "mandelbulb"))
        // rotationSpeed defaults to 0 — the phase bakes as a constant.
        #expect(!glsl.contains("mod(") || !glsl.contains("* iTime,"))
    }

    @Test func paletteStopsAreBaked() throws {
        var s = scene()
        s.palette = Palette(stops: [
            GradientStop(position: 0, rgb: (0.125, 0.25, 0.375)),
            GradientStop(position: 1, rgb: (1, 1, 1)),
        ])
        let glsl = try ShadertoyExporter.export(s)
        #expect(glsl.contains("PAL_COUNT = 2"))
        #expect(glsl.contains("vec4(0.125, 0.25, 0.375, 0.0)"))
    }

    @Test func embeddedDERefuses() {
        let s = scene(embeddedDE: EmbeddedDE(
            source: "float2 de_main(...)", abiVersion: 2, hash: ""))
        #expect(throws: ShadertoyExportError.embeddedDEUnsupported) {
            try ShadertoyExporter.export(s)
        }
    }

    @Test func unknownFractalRefuses() {
        #expect(throws: ShadertoyExportError.unknownFractal("nope")) {
            try ShadertoyExporter.export(scene(fractal: "nope"))
        }
    }

    @Test func exportIsDeterministic() throws {
        let s = scene(params: ["de.mandelbox.scale": [2.2]])
        #expect(try ShadertoyExporter.export(s) == ShadertoyExporter.export(s))
    }
}
