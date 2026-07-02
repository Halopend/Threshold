// RenderRequest.swift — value types crossing into the offscreen renderer,
// plus the param-table layout helper implementing the DE-slice convention.

import Foundation
import ThresholdShaderABI

/// One offscreen render: everything the march kernel consumes, by value.
/// `uniforms.meta.x` (opCount) is overwritten from `ops.count` at encode time
/// so the two can never disagree.
public struct RenderRequest: Sendable {
    public var uniforms: ThreshFrameUniforms
    /// The FULL resolved param table (catalog slot order): reserved engine
    /// slots [0, THRESH_SLOT_ENGINE_COUNT), then content params, with the DE
    /// slice at `uniforms.meta.w` and iterations as the slice's LAST entry.
    public var params: [Float]
    public var ops: [ThreshWarpOp]
    public var width: Int
    public var height: Int

    public init(uniforms: ThreshFrameUniforms, params: [Float],
                ops: [ThreshWarpOp], width: Int, height: Int) {
        self.uniforms = uniforms
        self.params = params
        self.ops = ops
        self.width = width
        self.height = height
    }
}

/// In-kernel instrumentation from one dispatch.
public struct MarchStats: Sendable {
    /// Sum of march-loop steps across all pixels (device atomic counter).
    public let totalSteps: UInt64
    /// GPU execution time from the command buffer's gpuStartTime/gpuEndTime.
    public let gpuMilliseconds: Double

    public init(totalSteps: UInt64, gpuMilliseconds: Double) {
        self.totalSteps = totalSteps
        self.gpuMilliseconds = gpuMilliseconds
    }
}

/// Readback of one offscreen render.
///
/// `rgba8` holds LINEAR values in rgba8unorm layout, row-major, y-down
/// (row 0 = top of image, matching texture coordinates), width*height*4
/// bytes. No gamma is applied — PNG/sRGB encoding is the harness's concern.
public struct RenderResult: Sendable {
    public let rgba8: [UInt8]
    public let width: Int
    public let height: Int
    public let stats: MarchStats

    public init(rgba8: [UInt8], width: Int, height: Int, stats: MarchStats) {
        self.rgba8 = rgba8
        self.width = width
        self.height = height
        self.stats = stats
    }
}

/// Reserved engine slot values (docs/op-semantics.md "March defaults").
public struct EngineParams: Sendable {
    public var maxSteps: Float = 256
    public var maxDist: Float = 64.0
    public var stepSafety: Float = 0.9
    public var iterations: Float = 12
    public var aoStrength: Float = 0.5
    public var shadowSoft: Float = 8.0

    public init() {}
}

/// Builds the full resolved param table with the encoder's DE-slice
/// convention: `[engine slots 0..<16][DE declared params][iterations]`.
///
/// The DE slice handed to the GPU (`params + deParamOffset`, length
/// `paramCount - deParamOffset`) is the declared DE params with iterations
/// appended as the LAST entry; DEs read
/// `iterations = int(ctx.params[ctx.paramCount - 1])`.
public enum ParamTableLayout {
    public static func build(engine: EngineParams = EngineParams(),
                             deParams: [Float]) -> (params: [Float], deParamOffset: Int) {
        var table = [Float](repeating: 0, count: Int(THRESH_SLOT_ENGINE_COUNT))
        table[Int(THRESH_SLOT_MAX_STEPS)] = engine.maxSteps
        table[Int(THRESH_SLOT_MAX_DIST)] = engine.maxDist
        table[Int(THRESH_SLOT_STEP_SAFETY)] = engine.stepSafety
        table[Int(THRESH_SLOT_ITERATIONS)] = engine.iterations
        table[Int(THRESH_SLOT_AO_STRENGTH)] = engine.aoStrength
        table[Int(THRESH_SLOT_SHADOW_SOFT)] = engine.shadowSoft
        let offset = table.count
        table.append(contentsOf: deParams)
        table.append(engine.iterations)
        return (table, offset)
    }
}
