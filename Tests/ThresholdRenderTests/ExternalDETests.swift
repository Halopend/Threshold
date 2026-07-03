// ExternalDETests.swift — external DE loading (plan §5.1/§7.2, phase 9):
// compile → link → probe → accept/reject, table extension (Invariant 5:
// external index = builtin.count, same dispatch), cache behavior, and every
// rejection path with surfaced diagnostics.

import Foundation
import simd
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("External DEs", .serialized)
struct ExternalDETests {

    /// A unit sphere with a declared radius param — the simplest well-formed
    /// external DE. `.y` returns a constant trap channel.
    static let sphereSource = """
        [[visible]] float2 de_main(float3 p, thread const ThreshDEContext& ctx)
        {
            float radius = ctx.paramCount > 1 ? ctx.params[0] : 1.0f;
            return float2(length(p) - radius, 0.5f);
        }
        """

    private func embedded(
        _ source: String, params: [EmbeddedDEParam] = [], hash: String? = nil,
        abiVersion: Int = Int(THRESHOLD_ABI_VERSION)
    ) -> EmbeddedDE {
        EmbeddedDE(
            source: source,
            abiVersion: abiVersion,
            hash: hash ?? ExternalDELoader.sourceHash(source),
            params: params)
    }

    @Test(.enabled(if: GPU.available))
    func validDECompilesProbesAndEvaluates() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let de = embedded(Self.sphereSource,
                          params: [EmbeddedDEParam(name: "radius", defaultValue: 1, min: 0.1, max: 4)])
        let program = try loader.load(de)

        // Invariant 5: the external's table index is builtin.count.
        #expect(program.descriptor.index == UInt32(DERegistry.builtin.count))
        #expect(program.deFunctionCount == DERegistry.builtin.count + 1)
        #expect(program.descriptor.paramLayout.map(\.name) == ["radius"])

        // Evaluate: |p| − radius, exactly.
        let evaluator = try DEEvaluator(context: ctx)
        let points: [SIMD3<Float>] = [SIMD3(2, 0, 0), SIMD3(0, 0.25, 0), SIMD3(0, 0, -3)]
        let out = try evaluator.evaluate(
            points: points, deIndex: Int(program.descriptor.index),
            deParams: [1.5], iterations: 12, program: program)
        #expect(abs(out[0].x - 0.5) < 1e-5)
        #expect(abs(out[1].x - -1.25) < 1e-5)
        #expect(abs(out[2].x - 1.5) < 1e-5)
        #expect(out[0].y == 0.5)

        // BUILT-IN dispatch through the extended table still works (the
        // program's table is a superset, not a replacement).
        let bulb = try evaluator.evaluate(
            points: [SIMD3(0, 0, 2)], deIndex: 1, deParams: [8.0],
            iterations: 12, program: program)
        let cpu = ReferenceDEs.mandelbulb(SIMD3(0, 0, 2), params: [8.0], iterations: 12)
        #expect(relClose(bulb[0].x, cpu.x, rel: 1e-3))
    }

    @Test(.enabled(if: GPU.available))
    func externalDERendersOffscreen() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let program = try loader.load(embedded(Self.sphereSource))
        let renderer = try OffscreenRenderer(context: ctx)

        var engine = EngineParams()
        engine.iterations = 12
        let (params, offset) = ParamTableLayout.build(engine: engine, deParams: [])
        var uniforms = ThreshFrameUniforms()
        uniforms.camPosFov = SIMD4(0, 0, 3, tan(Float.pi / 6))
        uniforms.camQuat = SIMD4(0, 0, 0, 1)
        uniforms.scaleCtx = SIMD4(0, 1e-3, 1, 1)
        uniforms.meta = SIMD4(0, program.descriptor.index, UInt32(params.count), UInt32(offset))

        let result = try renderer.render(
            RenderRequest(uniforms: uniforms, params: params, ops: [],
                          palette: [], width: 64, height: 64),
            program: program)
        #expect(result.stats.totalSteps > 0)
        // A sphere at the origin, camera on +Z: the center pixel must hit
        // (non-black), the corner must miss (black background).
        let center = (32 * 64 + 32) * 4
        let corner = 0
        #expect(result.rgba8[center] > 0 || result.rgba8[center + 1] > 0
                || result.rgba8[center + 2] > 0)
        #expect(result.rgba8[corner] == 0 && result.rgba8[corner + 1] == 0)
    }

    @Test(.enabled(if: GPU.available))
    func cacheReturnsSameProgramForSameSource() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let de = embedded(Self.sphereSource)
        let first = try loader.load(de)
        let second = try loader.load(de)
        #expect(first === second)
    }

    @Test(.enabled(if: GPU.available))
    func compileFailureSurfacesDiagnostics() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let bad = embedded("[[visible]] float2 de_main(float3 p) { this is not MSL }")
        do {
            _ = try loader.load(bad)
            Issue.record("expected compileFailed")
        } catch let error as ExternalDEError {
            guard case .compileFailed(let diagnostics) = error else {
                Issue.record("expected compileFailed, got \(error)")
                return
            }
            #expect(!diagnostics.isEmpty)
        }
    }

    @Test(.enabled(if: GPU.available))
    func missingEntryPointIsRejected() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let wrongName = embedded("""
            [[visible]] float2 de_other(float3 p, thread const ThreshDEContext& ctx)
            { return float2(length(p) - 1.0f, 0.0f); }
            """)
        #expect(throws: ExternalDEError.self) { try loader.load(wrongName) }
    }

    @Test(.enabled(if: GPU.available))
    func nanProducingDEFailsTheProbe() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        let nan = embedded("""
            [[visible]] float2 de_main(float3 p, thread const ThreshDEContext& ctx)
            { return float2(sqrt(-1.0f), 0.0f); }
            """)
        do {
            _ = try loader.load(nan)
            Issue.record("expected probeFailed")
        } catch let error as ExternalDEError {
            guard case .probeFailed = error else {
                Issue.record("expected probeFailed, got \(error)")
                return
            }
        }
    }

    @Test(.enabled(if: GPU.available))
    func solidUniverseDEFailsTheProbe() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)
        // Finite everywhere but never positive: every ray would march to the
        // step cap. Structurally rejected.
        let solid = embedded("""
            [[visible]] float2 de_main(float3 p, thread const ThreshDEContext& ctx)
            { return float2(-1.0f, 0.0f); }
            """)
        do {
            _ = try loader.load(solid)
            Issue.record("expected probeFailed")
        } catch let error as ExternalDEError {
            guard case .probeFailed = error else {
                Issue.record("expected probeFailed, got \(error)")
                return
            }
        }
    }

    @Test(.enabled(if: GPU.available))
    func abiAndHashMismatchesAreRejected() throws {
        let ctx = try GPU.ctx()
        let loader = try ExternalDELoader(context: ctx)

        let staleABI = embedded(Self.sphereSource, abiVersion: Int(THRESHOLD_ABI_VERSION) - 1)
        #expect(throws: ExternalDEError.self) { try loader.load(staleABI) }

        let tampered = embedded(Self.sphereSource, hash: String(repeating: "0", count: 64))
        #expect(throws: ExternalDEError.self) { try loader.load(tampered) }
    }

    @Test func embeddedDEParamsRoundTripInTheEnvelope() throws {
        let envelope = SceneEnvelope(
            version: SceneCodec.currentVersion,
            fractalTypeKey: "ignored",
            embeddedDE: EmbeddedDE(
                source: Self.sphereSource,
                abiVersion: Int(THRESHOLD_ABI_VERSION),
                hash: ExternalDELoader.sourceHash(Self.sphereSource),
                params: [EmbeddedDEParam(name: "radius", defaultValue: 1, min: 0.1, max: 4)]))
        let decoded = try SceneCodec.decode(SceneCodec.encode(envelope))
        #expect(decoded.embeddedDE == envelope.embeddedDE)
        #expect(decoded.embeddedDE?.params.first?.name == "radius")
    }
}
