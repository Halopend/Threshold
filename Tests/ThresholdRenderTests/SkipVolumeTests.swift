// SkipVolumeTests.swift — the world-space empty-space skip-volume (BorgVR
// hashed-brick port, function_constant 11): the occupancy build runs, the
// march consults it, the image is unchanged (no tunnelling), and marks the
// step-count delta so the A/B has a correctness floor under it. "Does it pay?"
// is the bench's question (Scripts + --skip-volume); this file owns "is it
// correct?".

import Foundation
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("Skip-volume (function_constant 11)", .serialized)
struct SkipVolumeTests {

    private func makeRequest(_ descriptor: DEDescriptor,
                             cameraPos: SIMD3<Float> = SIMD3(0.3, 0.4, 3.1),
                             size: Int = 96) -> RenderRequest {
        var engine = EngineParams()
        engine.aoStrength = 0.5
        let (params, deParamOffset) = ParamTableLayout.build(
            engine: engine, deParams: descriptor.paramLayout.map(\.default))
        let uniforms = CameraMath.makeUniforms(
            cameraPos: cameraPos, target: .zero,
            fovYRadians: Float.pi / 3,
            epsilonBase: 1.5e-3, modelScale: 1,
            opCount: 0, deIndex: Int(descriptor.index),
            paramCount: params.count, deParamOffset: deParamOffset)
        return RenderRequest(
            uniforms: uniforms, params: params, ops: [],
            palette: PaletteWire.defaultStops, width: size, height: size)
    }

    // MARK: Layout pin (private-contract discipline)

    @Test func uniformsLayoutMatchesMSL() {
        typealias U = SkipVolume.Uniforms
        // MSL ThreshSkipUniforms: float4 + uint4 + 4×uint = 48 bytes.
        #expect(MemoryLayout<U>.size == 48)
        #expect(MemoryLayout<U>.stride == 48)
        #expect(MemoryLayout<U>.offset(of: \U.gridDim) == 16)
        #expect(MemoryLayout<U>.offset(of: \U.margin) == 32)
        #expect(MemoryLayout<U>.offset(of: \U.tableSize) == 36)
        #expect(MemoryLayout<U>.offset(of: \U.probeMax) == 40)
    }

    @Test func gridDerivesFromCameraAndFar() throws {
        let ctx = try GPU.ctx()
        let skip = try SkipVolume(context: ctx, gridResolution: 32)
        let request = makeRequest(.mandelbox)
        var uniforms = ThreshFrameUniforms()
        switch EncodePreamble.validatedUniforms(
            request, deFunctionCount: ctx.deFunctionCount) {
        case .success(let u): uniforms = u
        case .failure(let e): Issue.record("uniforms invalid: \(e)"); return
        }
        #expect(skip.prepare(uniforms: uniforms, params: request.params))
        let U = skip.uniforms
        #expect(U.gridDim.x == 32 && U.gridDim.y == 32 && U.gridDim.z == 32)
        let maxDist = request.params[Int(THRESH_SLOT_MAX_DIST)]
        // Camera-centred: origin = camPos − maxDist, brick = 2·maxDist / grid.
        #expect(abs(U.originExtent.x - (0.3 - maxDist)) < 1e-3)
        #expect(abs(U.originExtent.w - (2 * maxDist / 32)) < 1e-3)
        // Table strictly larger than the brick count (headroom for probing).
        #expect(U.tableSize > 32 * 32 * 32)
        #expect(skip.table != nil)
    }

    // MARK: Engagement + correctness — the skip must ACTUALLY skip, and must
    // not change WHAT is rendered.
    //
    // Uses the mandelbulb from a head-on camera: measured to shed ~14% of DE
    // evaluations, so a STRICT step-count drop is the engagement proof — the
    // previous `<=` accepted a no-op skip (equal steps), which is exactly the
    // failure this test now catches. Mandelbox/warped-bulb/kleinian skip zero
    // at this grid (grid too coarse for their near-field geometry), so they
    // would be the WRONG scenes to assert engagement on.
    @Test(.enabled(if: GPU.available), arguments: SkipVolume.Mode.allCases)
    func skipEngagesAndMatchesPlain(mode: SkipVolume.Mode) throws {
        let ctx = try GPU.ctx()
        let renderer = try OffscreenRenderer(context: ctx)
        let request = makeRequest(
            .mandelbulb, cameraPos: SIMD3(0, 0, 3), size: 128)

        let plain = try renderer.render(request)
        let skip = try SkipVolume(context: ctx, gridResolution: 64, mode: mode)
        let skipped = try renderer.render(request, skipVolume: skip)

        #expect(plain.rgba8.contains { $0 > 8 }, "blank proves nothing")
        #expect(plain.stats.totalSteps > 0, "no steps counted — stats path broken")

        // ENGAGEMENT: the skip jumps do not count as march steps, so if the
        // volume actually skipped empty bricks the total DE evaluations MUST
        // fall. A no-op skip (feature silently disabled / found nothing)
        // leaves the count equal — and now fails here instead of passing.
        let cut = plain.stats.totalSteps > 0
            ? Double(Int(plain.stats.totalSteps) - Int(skipped.stats.totalSteps))
                / Double(plain.stats.totalSteps)
            : 0
        #expect(skipped.stats.totalSteps < plain.stats.totalSteps,
                "skip did NOT engage — steps unchanged (\(skipped.stats.totalSteps) vs \(plain.stats.totalSteps))")
        #expect(cut > 0.03,
                "skip engaged only marginally (\(String(format: "%.1f", cut * 100))% of steps); expected the measured ~14%")

        // No NaN sentinel (alpha 0): a skip must never poison a pixel into the
        // bad-DE path (mirrors the cone-prepass conservativeness check).
        var alphaZero = 0
        for i in stride(from: 3, to: skipped.rgba8.count, by: 4)
        where skipped.rgba8[i] == 0 { alphaZero += 1 }
        #expect(alphaZero == 0, "NaN-sentinel pixels under skip-volume")

        // CORRECTNESS: skipping empty space must not change WHAT is hit. The
        // start points shift within the epsilon band (like the cone prepass),
        // so this is a tolerance; tunnelling would read as large means.
        var total = 0, big = 0
        for (a, b) in zip(plain.rgba8, skipped.rgba8) {
            let d = abs(Int(a) - Int(b))
            total += d
            if d > 48 { big += 1 }
        }
        let mean = Double(total) / Double(plain.rgba8.count)
        #expect(mean < 6.0, "skip image drifted (meanΔ \(mean)) — possible tunnelling")
        #expect(Double(big) / Double(plain.rgba8.count) < 0.05,
                "skip image has large-delta regions (\(big) bytes)")
    }

    // MARK: Off-by-default safety

    @Test(.enabled(if: GPU.available))
    func noSkipVolumeIsByteIdenticalToBaseline() throws {
        let ctx = try GPU.ctx()
        let renderer = try OffscreenRenderer(context: ctx)
        let request = makeRequest(.mandelbulb)
        // render() with skipVolume:nil must be the exact pre-feature path.
        let a = try renderer.render(request)
        let b = try renderer.render(request, skipVolume: nil)
        #expect(a.rgba8 == b.rgba8, "skipVolume:nil changed the baseline image")
    }
}
