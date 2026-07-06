// RenderRequest.swift — value types crossing into the offscreen renderer,
// plus the param-table layout helper implementing the DE-slice convention.

import Foundation
import ThresholdCore
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
    /// Gradient palette stops (linear rgb + position), packed to the ABI's
    /// ThreshPalette at encode time. Empty → the built-in default palette.
    public var palette: [GradientStop]
    public var width: Int
    public var height: Int
    /// Resolution scale in (0, 1]: the live encoder marches into an
    /// intermediate texture of `width×scale` and bilinear-upscales into the
    /// drawable. 1 = march directly into the target (offscreen paths always
    /// pass 1 — goldens never depend on the upscale).
    public var renderScale: Float
    /// Live render-pipeline tuning (specialization on/off, iteration bake) —
    /// read by the interactive encoder to choose a pipeline. Offscreen/golden
    /// paths ignore it (they pass an explicit `specialized:` variant or none).
    public var tuning: RenderTuning

    public init(uniforms: ThreshFrameUniforms, params: [Float],
                ops: [ThreshWarpOp], palette: [GradientStop] = [],
                width: Int, height: Int, renderScale: Float = 1,
                tuning: RenderTuning = RenderTuning()) {
        self.uniforms = uniforms
        self.params = params
        self.ops = ops
        self.palette = palette
        self.width = width
        self.height = height
        self.renderScale = renderScale
        self.tuning = tuning
    }
}

/// ThreshPalette wire packing (plan §5.5). Swift imports the C fixed-array
/// `stops[8]` as a tuple, so we pack the 144-byte struct image by hand and
/// hand the bytes to `setBytes` — one packer for both encoders.
public enum PaletteWire {
    /// sizeof(ThreshPalette): 16-byte header + 16 bytes per stop.
    public static let byteCount = 16 + 16 * Palette.maxStops

    /// The renderer's default palette when a scene ships none: a warm-to-cool
    /// sweep that keeps the classic look readable across the orbit-trap range.
    public static let defaultStops: [GradientStop] = [
        GradientStop(position: 0.00, rgb: (0.02, 0.02, 0.06)),
        GradientStop(position: 0.30, rgb: (0.55, 0.12, 0.30)),
        GradientStop(position: 0.60, rgb: (0.95, 0.55, 0.18)),
        GradientStop(position: 0.85, rgb: (0.98, 0.90, 0.55)),
        GradientStop(position: 1.00, rgb: (0.90, 0.98, 0.95)),
    ]

    /// Pack stops (or the default set, if empty) into ThreshPalette bytes.
    public static func bytes(_ stops: [GradientStop]) -> [UInt8] {
        let source = stops.isEmpty ? defaultStops : stops
        let clamped = Array(source.prefix(Palette.maxStops))
        var data = [UInt8](repeating: 0, count: byteCount)
        let count = UInt32(clamped.count)
        withUnsafeBytes(of: count) { raw in
            for i in 0..<4 { data[i] = raw[i] }
        }
        for (i, s) in clamped.enumerated() {
            let base = 16 + i * 16
            let v = SIMD4<Float>(s.red, s.green, s.blue, s.position)
            withUnsafeBytes(of: v) { raw in
                for j in 0..<16 { data[base + j] = raw[j] }
            }
        }
        return data
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

/// Reserved engine slot values (docs/op-semantics.md "March defaults" +
/// plan §5.5 color defaults). Defaults match `Catalog.withEngineDefaults` so
/// the offscreen harness and the live session render identically before any
/// scene is applied.
public struct EngineParams: Sendable {
    public var maxSteps: Float = 256
    public var maxDist: Float = 64.0
    public var stepSafety: Float = 0.9
    public var iterations: Float = 12
    public var aoStrength: Float = 0.5
    public var shadowSoft: Float = 8.0
    // Color pipeline (plan §5.5).
    public var gradientRepeat: Float = 1
    public var gradientOffset: Float = 0
    public var gradientSmoothing: Float = 0
    public var colorMapMode: Float = 0
    public var saturation: Float = 1
    public var contrast: Float = 1
    public var vibrance: Float = 0
    public var brightness: Float = 1
    public var gamma: Float = 1
    public var tonemap: Float = 0
    // Safety bubble (legacy "safe space"): off by default so authored scenes
    // are untouched. Carved around the camera; see THRESH_SLOT_BUBBLE_*.
    public var bubbleEnabled: Float = 0
    public var bubbleRadius: Float = 1.8
    public var bubbleShape: Float = 0
    public var bubbleBlend: Float = 0.25
    // Atmosphere (legacy Effects ▸ Static): glow, bloom, fog + fog tint. All
    // off by default so authored/golden scenes are byte-identical.
    public var glowEnabled: Float = 0
    public var glowIntensity: Float = 0.3
    public var bloomEnabled: Float = 0
    public var bloomStrength: Float = 0.2
    public var fogEnabled: Float = 0
    public var fogIntensity: Float = 0.32
    public var fogColor: SIMD3<Float> = SIMD3(0.01, 0.015, 0.02)

    public init() {}

    /// The reserved engine region [0, THRESH_SLOT_ENGINE_COUNT) in slot order,
    /// ready to head the GPU param table.
    public func reservedSlots() -> [Float] {
        var table = [Float](repeating: 0, count: Int(THRESH_SLOT_ENGINE_COUNT))
        table[Int(THRESH_SLOT_MAX_STEPS)] = maxSteps
        table[Int(THRESH_SLOT_MAX_DIST)] = maxDist
        table[Int(THRESH_SLOT_STEP_SAFETY)] = stepSafety
        table[Int(THRESH_SLOT_ITERATIONS)] = iterations
        table[Int(THRESH_SLOT_AO_STRENGTH)] = aoStrength
        table[Int(THRESH_SLOT_SHADOW_SOFT)] = shadowSoft
        table[Int(THRESH_SLOT_GRAD_REPEAT)] = gradientRepeat
        table[Int(THRESH_SLOT_GRAD_OFFSET)] = gradientOffset
        table[Int(THRESH_SLOT_GRAD_SMOOTH)] = gradientSmoothing
        table[Int(THRESH_SLOT_MAP_MODE)] = colorMapMode
        table[Int(THRESH_SLOT_SATURATION)] = saturation
        table[Int(THRESH_SLOT_CONTRAST)] = contrast
        table[Int(THRESH_SLOT_VIBRANCE)] = vibrance
        table[Int(THRESH_SLOT_BRIGHTNESS)] = brightness
        table[Int(THRESH_SLOT_GAMMA)] = gamma
        table[Int(THRESH_SLOT_TONEMAP)] = tonemap
        table[Int(THRESH_SLOT_BUBBLE_ENABLED)] = bubbleEnabled
        table[Int(THRESH_SLOT_BUBBLE_RADIUS)] = bubbleRadius
        table[Int(THRESH_SLOT_BUBBLE_SHAPE)] = bubbleShape
        table[Int(THRESH_SLOT_BUBBLE_BLEND)] = bubbleBlend
        table[Int(THRESH_SLOT_GLOW_ENABLED)] = glowEnabled
        table[Int(THRESH_SLOT_GLOW_INTENSITY)] = glowIntensity
        table[Int(THRESH_SLOT_BLOOM_ENABLED)] = bloomEnabled
        table[Int(THRESH_SLOT_BLOOM_STRENGTH)] = bloomStrength
        table[Int(THRESH_SLOT_FOG_ENABLED)] = fogEnabled
        table[Int(THRESH_SLOT_FOG_INTENSITY)] = fogIntensity
        table[Int(THRESH_SLOT_FOG_COLOR_R)] = fogColor.x
        table[Int(THRESH_SLOT_FOG_COLOR_G)] = fogColor.y
        table[Int(THRESH_SLOT_FOG_COLOR_B)] = fogColor.z
        return table
    }
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
        var table = engine.reservedSlots()
        let offset = table.count
        table.append(contentsOf: deParams)
        table.append(engine.iterations)
        return (table, offset)
    }
}
