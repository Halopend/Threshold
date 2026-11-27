// LegacyFormulaTests.swift — the original app's user-authored embedded
// formulas (fractalType "custom"), migrated through LegacyFormulaShim onto
// the rebuild's external-DE pipeline, must actually compile, link, and pass
// the probe on this build's ABI (plan §7.2/§7.3 — the corpus is the contract).

import Foundation
import Testing
import ThresholdCore
import ThresholdShaderABI
@testable import ThresholdRender

@Suite("Legacy embedded formulas", .serialized)
struct LegacyFormulaTests {
    private var scenesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus/legacy/scenes")
    }

    @Test func coreABIVersionMirrorsTheHeader() {
        // ThresholdCore cannot import the ABI header (Foundation-only rule);
        // migrations stamp EmbeddedDE.currentABIVersion instead. The two
        // MUST move together.
        #expect(EmbeddedDE.currentABIVersion == Int(THRESHOLD_ABI_VERSION))
    }

    @Test(.enabled(if: GPU.available))
    func everyLegacyCustomFormulaCompilesLinksAndProbes() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: scenesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "threshscene" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let loader = try ExternalDELoader(context: GPU.ctx())
        var customCount = 0
        for file in files {
            let envelope = try SceneCodec.decode(try Data(contentsOf: file))
            guard let embedded = envelope.embeddedDE else { continue }
            customCount += 1
            let name = Comment(rawValue: file.lastPathComponent)
            do {
                let program = try loader.load(embedded)
                #expect(program.descriptor.paramLayout.count == embedded.params.count, name)
            } catch {
                Issue.record("\(file.lastPathComponent): \(error)")
            }
        }
        #expect(customCount == 15, "the corpus carries 15 custom scenes, saw \(customCount)")
    }

    @Test func authoredFormulaValuesMigrateByLegacySlot() throws {
        // Box authors CSize X = -0.592 against a declared default of 0.486:
        // the scene must carry the authored value, not fall back.
        let box = try SceneCodec.decode(Data(
            contentsOf: scenesDir.appendingPathComponent("Box.threshscene")))
        let csx = try #require(box.params["de.external.CSize X"]?.first)
        #expect(abs(csx - -0.59239715) < 1e-6)
        #expect(abs((box.params["de.external.TwiddleRXY"]?.first ?? 0) - 0.9025176) < 1e-6)
        // Undeclared formulaParamValues slots get no external param.
        #expect(box.params.keys.filter { $0.hasPrefix("de.external.") }.count == 6)
    }

    @Test func sparseLegacySlotsRouteToTheirOwnIndex() throws {
        // Embedded Mandelbulb declares slots 0,1,2,4: PolarRotation is the
        // 4th declared param (ctx.params[3]) but the formula reads params[4].
        let scene = try SceneCodec.decode(Data(
            contentsOf: scenesDir.appendingPathComponent("Embedded Mandelbulb.threshscene")))
        let source = try #require(scene.embeddedDE?.source)
        #expect(source.contains("fp.params[4] = ctx.params[3];"))
        #expect(!source.contains("fp.params[3] = ctx.params[3];"))
        #expect(scene.params["de.external.PolarRotation"] == [0])
        // Contiguous formulas keep the original loop text (stable hash).
        let box = try SceneCodec.decode(Data(
            contentsOf: scenesDir.appendingPathComponent("Box.threshscene")))
        #expect(box.embeddedDE?.source.contains("i < 6 && uint(i) + 1u < ctx.paramCount") == true)
    }

    @Test(.enabled(if: GPU.available))
    func migratedFormulaRendersEndToEnd() throws {
        // One exemplar all the way to pixels: decode → load → render the
        // scene's own params through the offscreen path.
        let data = try Data(
            contentsOf: scenesDir.appendingPathComponent("Great_sphere.threshscene"))
        let envelope = try SceneCodec.decode(data)
        let embedded = try #require(envelope.embeddedDE)
        #expect(embedded.params.count == 6)  // CSize xyz, Size, DEfactor, TwiddleRXY

        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let program = try loader.load(embedded)

        var engine = EngineParams()
        engine.iterations = envelope.params[ParamKey.engineIterations.rawValue]?.first ?? 9
        let deParams = program.descriptor.paramLayout.map(\.default)
        let (params, deParamOffset) = ParamTableLayout.build(
            engine: engine, deParams: deParams)
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0, 0, 4), target: .zero,
            fovYRadians: Float.pi / 3,
            opCount: 0, deIndex: Int(program.descriptor.index),
            paramCount: params.count, deParamOffset: deParamOffset)
        let renderer = try OffscreenRenderer(context: ctx)
        let result = try renderer.render(
            RenderRequest(uniforms: uniforms, params: params, ops: [],
                          width: 64, height: 64),
            program: program)
        #expect(
            stride(from: 3, to: result.rgba8.count, by: 4).allSatisfy { result.rgba8[$0] == 255 },
            "no NaN sentinel pixels")
        #expect(result.stats.totalSteps > 0)
    }
}
