// PostProcessor.swift — ordered full-frame GPU filter composition.
//
// Every enabled, known DTO becomes one compute dispatch in authored order.
// Stages ping-pong through rgba16Float so a long stack does not accumulate
// 8-bit quantization; a final identity dispatch converts into a texture that
// is blit-compatible with the presentation target. Separate encoders provide
// Metal's normal write→read hazard ordering between stages.

import Metal
import ThresholdCore

/// Render-thread-confined post-processing encoder shared by the offscreen,
/// interactive, and compositor compute/raster shells.
final class PostProcessor {
    struct SpatialPass {
        let input: MTLTexture
        let output: MTLTexture
    }

    /// Live encoders can have three command buffers in flight. Intermediate
    /// textures must be ringed with the command buffers; sharing one
    /// ping-pong pair across frames creates a GPU write-after-read hazard.
    static let defaultInFlightSlots = 3
    /// A hostile scene must not turn one frame into an unbounded number of GPU
    /// dispatches. Unknown/disabled entries do not consume the budget and
    /// remain untouched in the authored stack for forward-compatible saves.
    static let maximumRenderedFilters = 32

    private let device: MTLDevice
    private let pipeline2D: MTLComputePipelineState
    private let pipelineArray: MTLComputePipelineState
    private let spatialUpscalePipeline: MTLComputePipelineState

    private var ping: [MTLTexture?]
    private var inputCopy: [MTLTexture?]
    private var presentation: [MTLTexture?]
    private var spatialInput: [MTLTexture?]
    private var spatialOutput: [MTLTexture?]

    /// Private Swift mirror of `ThreshPostUniforms` in PostProcess.metal.
    /// Four 16-byte lanes = 64 bytes with no implicit tail padding.
    private struct Uniforms {
        var size: SIMD2<Float>
        var invSize: SIMD2<Float>
        var a: SIMD4<Float>
        var b: SIMD4<Float>
        var strength: Float
        var time: Float
        var kind: UInt32
        var stage: UInt32
    }

    init(context: GPUContext) throws {
        self.device = context.device
        let library = try context.postProcessLibrary()
        guard let function2D = library.makeFunction(name: "post_process_2d") else {
            throw RenderError.missingFunction("post_process_2d")
        }
        guard let functionArray = library.makeFunction(name: "post_process_array") else {
            throw RenderError.missingFunction("post_process_array")
        }
        guard let spatialFunction = library.makeFunction(name: "spatial_upscale_2d") else {
            throw RenderError.missingFunction("spatial_upscale_2d")
        }
        do {
            pipeline2D = try context.device.makeComputePipelineState(function: function2D)
            pipelineArray = try context.device.makeComputePipelineState(function: functionArray)
            spatialUpscalePipeline = try context.device.makeComputePipelineState(
                function: spatialFunction)
        } catch {
            throw RenderError.pipelineCreationFailed(
                "post processing: \(String(describing: error))")
        }
        ping = [MTLTexture?](repeating: nil, count: Self.defaultInFlightSlots * 2)
        inputCopy = [MTLTexture?](repeating: nil, count: Self.defaultInFlightSlots)
        presentation = [MTLTexture?](repeating: nil, count: Self.defaultInFlightSlots)
        spatialInput = [MTLTexture?](repeating: nil, count: Self.defaultInFlightSlots)
        spatialOutput = [MTLTexture?](repeating: nil, count: Self.defaultInFlightSlots)
    }

    /// Allocate/reuse a reduced-resolution march target and a full-resolution
    /// sampleable presentation target for one in-flight frame.
    func prepareSpatialPass(
        inputWidth: Int,
        inputHeight: Int,
        matching destination: MTLTexture,
        inFlightSlot: Int
    ) throws -> SpatialPass {
        guard destination.textureType == .type2D else {
            throw RenderError.badRequest("spatial upscale requires a 2D destination")
        }
        let slot = max(0, min(inFlightSlot, Self.defaultInFlightSlots - 1))
        let input = try cachedTexture(
            &spatialInput[slot], width: inputWidth, height: inputHeight,
            pixelFormat: destination.pixelFormat, label: "spatial upscale input")
        let output = try cachedTexture(
            &spatialOutput[slot], width: destination.width,
            height: destination.height, pixelFormat: destination.pixelFormat,
            label: "spatial upscale output")
        return SpatialPass(input: input, output: output)
    }

    func encodeSpatial(
        commandBuffer: MTLCommandBuffer, pass: SpatialPass
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.allocationFailed("spatial upscale encoder")
        }
        encoder.label = "spatial upscale"
        encoder.setComputePipelineState(spatialUpscalePipeline)
        encoder.setTexture(pass.input, index: 0)
        encoder.setTexture(pass.output, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (pass.output.width + 7) / 8,
                height: (pass.output.height + 7) / 8,
                depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    /// Encode the enabled/known filters in exact array order and copy the
    /// final image into `destination`. Empty/fully-disabled stacks are a true
    /// identity: same-texture calls encode nothing, distinct textures receive
    /// a plain blit. Returns the number of logical filter stages encoded.
    @discardableResult
    func encode(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        stack: [PostProcessFilterDTO],
        time: Float,
        inFlightSlot: Int = 0
    ) throws -> Int {
        let slot = max(0, min(inFlightSlot, Self.defaultInFlightSlots - 1))
        guard source.width == destination.width,
              source.height == destination.height,
              source.textureType == destination.textureType,
              source.arrayLength == destination.arrayLength
        else {
            throw RenderError.badRequest("post-process source/destination shape mismatch")
        }
        guard source.textureType == .type2D || source.textureType == .type2DArray else {
            throw RenderError.badRequest(
                "unsupported post-process texture type \(source.textureType.rawValue)")
        }

        let active = Self.activeFilters(stack)
        guard !active.isEmpty else {
            if source !== destination {
                try encodeBlit(
                    commandBuffer: commandBuffer, source: source,
                    destination: destination, label: "post identity copy")
            }
            return 0
        }

        // Some system drawables (notably Compositor Services) permit raster
        // writes and blits but do not advertise shaderRead. Copy once into a
        // private sampleable texture in that case; ordinary intermediates and
        // CAMetalLayer textures take the zero-copy path.
        var current = source
        if !source.usage.contains(.shaderRead) {
            let readable = try cachedTexture(
                &inputCopy[slot], matching: source, pixelFormat: source.pixelFormat,
                label: "post input copy")
            try encodeBlit(
                commandBuffer: commandBuffer, source: source,
                destination: readable, label: "post input copy")
            current = readable
        }

        for (index, filter) in active.enumerated() {
            let target = try cachedTexture(
                &ping[slot * 2 + (index & 1)], matching: destination,
                pixelFormat: .rgba16Float,
                label: "post HDR ping \(index & 1)")
            let uniforms = Self.uniforms(
                filter: filter, source: current,
                time: time, stage: UInt32(index))
            try encodeStage(
                commandBuffer: commandBuffer, source: current,
                destination: target, uniforms: uniforms,
                label: "post \(filter.kind) [\(index)]")
            current = target
        }

        // Convert HDR stage output into the destination's exact format, then
        // blit. This avoids ever requesting compute-write access on a system
        // drawable while retaining high precision between logical filters.
        let final = try cachedTexture(
            &presentation[slot], matching: destination,
            pixelFormat: destination.pixelFormat,
            label: "post presentation")
        var copyUniforms = Self.identityUniforms(
            source: current, time: time, stage: UInt32(active.count))
        // Keep a mutable value alive through setBytes' copy (and make the
        // identity intent visible at the call site).
        copyUniforms.kind = 0
        try encodeStage(
            commandBuffer: commandBuffer, source: current,
            destination: final, uniforms: copyUniforms,
            label: "post output conversion")
        try encodeBlit(
            commandBuffer: commandBuffer, source: final,
            destination: destination, label: "post presentation copy")
        return active.count
    }

    /// Known + enabled, preserving duplicates and authored order exactly.
    static func activeFilters(
        _ stack: [PostProcessFilterDTO]
    ) -> [PostProcessFilterDTO] {
        Array(stack.lazy.filter {
            $0.enabled && PostProcessKind(rawValue: $0.kind) != nil
        }.prefix(maximumRenderedFilters))
    }

    private static func uniforms(
        filter: PostProcessFilterDTO, source: MTLTexture,
        time: Float, stage: UInt32
    ) -> Uniforms {
        func finite(_ value: Float, fallback: Float = 0) -> Float {
            value.isFinite ? value : fallback
        }
        func vector(_ values: [Float]) -> SIMD4<Float> {
            guard values.count == 4 else { return .zero }
            return SIMD4(
                finite(values[0]), finite(values[1]),
                finite(values[2]), finite(values[3]))
        }
        let width = Float(source.width)
        let height = Float(source.height)
        return Uniforms(
            size: SIMD2(width, height),
            invSize: SIMD2(1 / max(width, 1), 1 / max(height, 1)),
            a: vector(filter.a),
            b: vector(filter.b),
            strength: finite(filter.strength),
            time: finite(time),
            kind: filter.kind,
            stage: stage)
    }

    private static func identityUniforms(
        source: MTLTexture, time: Float, stage: UInt32
    ) -> Uniforms {
        let width = Float(source.width)
        let height = Float(source.height)
        return Uniforms(
            size: SIMD2(width, height),
            invSize: SIMD2(1 / max(width, 1), 1 / max(height, 1)),
            a: .zero, b: .zero, strength: 0,
            time: time.isFinite ? time : 0,
            kind: 0, stage: stage)
    }

    private func encodeStage(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        uniforms: Uniforms,
        label: String
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.allocationFailed("\(label) encoder")
        }
        encoder.label = label
        encoder.setComputePipelineState(
            source.textureType == .type2DArray ? pipelineArray : pipeline2D)
        var copied = uniforms
        withUnsafeBytes(of: &copied) { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        let slices = source.textureType == .type2DArray ? source.arrayLength : 1
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (destination.width + 7) / 8,
                height: (destination.height + 7) / 8,
                depth: slices),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    private func cachedTexture(
        _ cached: inout MTLTexture?, matching reference: MTLTexture,
        pixelFormat: MTLPixelFormat, label: String
    ) throws -> MTLTexture {
        try cachedTexture(
            &cached, width: reference.width, height: reference.height,
            pixelFormat: pixelFormat, textureType: reference.textureType,
            arrayLength: reference.arrayLength, label: label)
    }

    private func cachedTexture(
        _ cached: inout MTLTexture?,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        textureType: MTLTextureType = .type2D,
        arrayLength: Int = 1,
        label: String
    ) throws -> MTLTexture {
        if let cached,
           cached.textureType == textureType,
           cached.pixelFormat == pixelFormat,
           cached.width == width,
           cached.height == height,
           cached.arrayLength == arrayLength {
            return cached
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = textureType
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = 1
        descriptor.mipmapLevelCount = 1
        descriptor.arrayLength = textureType == .type2DArray ? arrayLength : 1
        descriptor.sampleCount = 1
        descriptor.storageMode = .private
        // Blit participation is implicit in Metal; texture usage only needs
        // to declare shader access.
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.allocationFailed(label)
        }
        texture.label = label
        cached = texture
        return texture
    }

    private func encodeBlit(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        label: String
    ) throws {
        guard source.width == destination.width,
              source.height == destination.height,
              source.arrayLength == destination.arrayLength
        else { throw RenderError.badRequest("\(label) shape mismatch") }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RenderError.allocationFailed("\(label) encoder")
        }
        blit.label = label
        let size = MTLSize(width: source.width, height: source.height, depth: 1)
        let slices = source.textureType == .type2DArray ? source.arrayLength : 1
        for slice in 0..<slices {
            blit.copy(
                from: source, sourceSlice: slice, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
                to: destination, destinationSlice: slice, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
    }
}
