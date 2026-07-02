// PipelineTests.swift — runtime shader compile, pipeline creation, and DE
// visible-function-table population.

import Foundation
import Metal
import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdRender

@Suite("GPU context & pipelines")
struct PipelineTests {

    @Test func abiStructLayoutsMatchTheHeaderAsserts() {
        #expect(MemoryLayout<ThreshWarpOp>.stride == 48)
        #expect(MemoryLayout<ThreshWarpOp>.alignment == 16)
        #expect(MemoryLayout<ThreshFrameUniforms>.stride == 64)
    }

    @Test(.enabled(if: GPU.available))
    func libraryCompilesAndAllPipelinesBuild() throws {
        let ctx = try GPU.ctx()
        #expect(ctx.deFunctionCount == 2)
        #expect(ctx.marchPipeline.maxTotalThreadsPerThreadgroup >= 64)
        #expect(ctx.evalOpsPipeline.maxTotalThreadsPerThreadgroup >= 64)
        #expect(ctx.evalDistPipeline.maxTotalThreadsPerThreadgroup >= 64)
        #expect(ctx.evalDEPipeline.maxTotalThreadsPerThreadgroup >= 64)
    }

    /// The function table is populated in index order (0 = mandelbox,
    /// 1 = mandelbulb): both entries must dispatch, return finite estimates,
    /// and disagree with each other (a mis-populated table would alias them).
    @Test(.enabled(if: GPU.available))
    func deFunctionTableDispatchesBothBuiltins() throws {
        let ctx = try GPU.ctx()
        let evaluator = try DEEvaluator(context: ctx)
        let points: [SIMD3<Float>] = [SIMD3(5, 0.5, -0.25), SIMD3(0, 4.5, 1)]

        let box = try evaluator.evaluate(points: points, deIndex: 0,
                                         deParams: [2.0, 0.5, 1.0, 1.0], iterations: 12)
        let bulb = try evaluator.evaluate(points: points, deIndex: 1,
                                          deParams: [8.0], iterations: 12)
        #expect(box.count == 2 && bulb.count == 2)
        for value in box + bulb {
            #expect(value.x.isFinite && value.y.isFinite)
            #expect(value.x > 0, "exterior points must report positive distance")
        }
        #expect(box[0].x != bulb[0].x, "table entries 0 and 1 must be distinct DEs")
    }

    @Test(.enabled(if: GPU.available))
    func evaluatorsRejectBadInput() throws {
        let ctx = try GPU.ctx()
        let de = try DEEvaluator(context: ctx)
        #expect(throws: RenderError.self) {
            _ = try de.evaluate(points: [SIMD3(1, 1, 1)], deIndex: 99,
                                deParams: [8.0], iterations: 4)
        }
        let ops = try OpsEvaluator(context: ctx)
        #expect(throws: RenderError.self) {
            _ = try ops.applyDistanceOps(points: [SIMD3(0, 0, 0)], distances: [],
                                         ops: [])
        }
    }
}
