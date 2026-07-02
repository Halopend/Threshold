// threshold-render — headless deterministic renderer + perf/regression
// harness (plan §9, ARCHITECTURE.md §8). The end-to-end integration path:
// scene file → catalog/engine (scene lane) → resolve → warp ops (simplified)
// → GPU compute march → PNG + stats JSON.
//
// Determinism: FixedStepClock, no ambient time, mathMode-safe kernel — the
// same invocation produces byte-identical PNGs (the golden-image contract).

import Foundation
import ImageIO
import UniformTypeIdentifiers
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
import ThresholdRender

// MARK: - CLI options

struct Options {
    var scenePath: String?
    var outPath = "threshold-out.png"
    var statsPath: String?
    var comparePath: String?
    var writeDefaultScenePath: String?
    var width = 512
    var height = 512
    var frames = 1
    var step = 1.0 / 60.0
    var deKey = "mandelbulb"
    var quiet = false

    static func parse(_ args: [String]) -> Options {
        var opts = Options()
        var i = 0
        func next(_ flag: String) -> String {
            i += 1
            guard i < args.count else { die("missing value for \(flag)") }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--out": opts.outPath = next(arg)
            case "--stats": opts.statsPath = next(arg)
            case "--compare": opts.comparePath = next(arg)
            case "--write-default-scene": opts.writeDefaultScenePath = next(arg)
            case "--width", "-w": opts.width = intValue(next(arg), for: arg)
            case "--height", "-h": opts.height = intValue(next(arg), for: arg)
            case "--frames": opts.frames = intValue(next(arg), for: arg)
            case "--step": opts.step = doubleValue(next(arg), for: arg)
            case "--de": opts.deKey = next(arg)
            case "--quiet": opts.quiet = true
            case "--help":
                print(usage)
                exit(0)
            default:
                if arg.hasPrefix("-") { die("unknown flag \(arg)\n\(usage)") }
                opts.scenePath = arg
            }
            i += 1
        }
        guard opts.width > 0, opts.height > 0, opts.frames > 0, opts.step > 0 else {
            die("width/height/frames/step must be positive")
        }
        return opts
    }
}

let usage = """
usage: threshold-render [scene.threshscene] [options]
  --out <path.png>              output image (default threshold-out.png)
  --stats <path.json>           write march stats JSON
  --compare <golden.png>        byte-compare output against a golden; exit 2 on mismatch
  --write-default-scene <path>  emit a starter .threshscene and exit
  --width, -w / --height, -h    output size (default 512x512)
  --frames <n>                  advance the fixed-step clock n frames; render each (default 1)
  --step <seconds>              fixed clock step (default 1/60)
  --de <key>                    built-in DE when no scene is given (default mandelbulb)
  --quiet                       suppress progress output
"""

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("threshold-render: \(message)\n".utf8))
    exit(1)
}

func intValue(_ s: String, for flag: String) -> Int {
    guard let v = Int(s) else { die("\(flag) expects an integer, got '\(s)'") }
    return v
}

func doubleValue(_ s: String, for flag: String) -> Double {
    guard let v = Double(s) else { die("\(flag) expects a number, got '\(s)'") }
    return v
}

// MARK: - Catalog wiring

/// Engine catalog + every built-in DE's params registered under its
/// namespace. Slots for a DE's params are recovered via ParamKey.de.
func buildLayout() -> CatalogLayout {
    let catalog = Catalog.withEngineDefaults()
    for descriptor in DERegistry.builtin {
        do {
            _ = try descriptor.registerParams(into: catalog)
        } catch {
            die("catalog registration failed for \(descriptor.key): \(error)")
        }
    }
    return catalog.freeze()
}

/// Pull a DE's declared param values out of the resolved table.
func deParamValues(_ descriptor: DEDescriptor, layout: CatalogLayout, resolved: ResolvedParams) -> [Float] {
    descriptor.paramLayout.map { param in
        guard let slot = layout.slot(for: ParamKey.de(descriptor.key, param.name)) else {
            die("catalog is missing \(descriptor.key).\(param.name) — registration bug")
        }
        return resolved.values[slot]
    }
}

// MARK: - PNG I/O

func writePNG(_ result: RenderResult, to path: String) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let data = CFDataCreate(nil, result.rgba8, result.rgba8.count)!
    let provider = CGDataProvider(data: data)!
    guard let image = CGImage(
        width: result.width, height: result.height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: result.width * 4,
        space: colorSpace,
        // Straight (non-premultiplied) alpha: the kernel's NaN sentinel is
        // RGB(255,0,255) with alpha 0, which is INVALID premultiplied data —
        // declaring premultiplied would let ImageIO zero it out and hide the
        // sentinel from golden diffs.
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { die("could not build CGImage") }

    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { die("could not open \(path) for writing") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { die("PNG write failed for \(path)") }
}

// MARK: - Stats

struct FrameStats: Codable {
    let frame: Int
    let time: Double
    let totalSteps: UInt64
    let gpuMilliseconds: Double
}

struct RunStats: Codable {
    let width: Int
    let height: Int
    let frames: Int
    let deKey: String
    let opCount: Int
    let simplifiedOpCount: Int
    let totalSteps: UInt64
    let averageGpuMilliseconds: Double
    let perFrame: [FrameStats]
}

// MARK: - Main

let opts = Options.parse(Array(CommandLine.arguments.dropFirst()))
let layout = buildLayout()
let clock = FixedStepClock(step: opts.step)
let engine = ModulationEngine(layout: layout, clock: clock)

// Resolve the scene: explicit file, or a default built from the catalog.
var envelope: SceneEnvelope
if let scenePath = opts.scenePath {
    guard let data = FileManager.default.contents(atPath: scenePath) else {
        die("cannot read \(scenePath)")
    }
    do {
        envelope = try SceneCodec.decode(data)
    } catch {
        die("scene decode failed: \(error)")
    }
} else {
    envelope = SceneCodec.snapshot(
        layout: layout, engine: engine, fractalTypeKey: opts.deKey,
        camera: .default, name: "default")
}

if let path = opts.writeDefaultScenePath {
    do {
        try SceneCodec.encode(envelope).write(to: URL(fileURLWithPath: path))
        if !opts.quiet { print("wrote \(path)") }
        exit(0)
    } catch {
        die("scene write failed: \(error)")
    }
}

if envelope.embeddedDE != nil {
    // The envelope contract says fractalTypeKey is IGNORED when embeddedDE is
    // set — silently rendering the wrong DE would violate it.
    die("this harness does not support embedded DEs yet (scene declares one)")
}
guard let descriptor = DERegistry.descriptor(forKey: envelope.fractalTypeKey) else {
    die("unknown fractal type '\(envelope.fractalTypeKey)' "
        + "(known: \(DERegistry.builtin.map(\.key).joined(separator: ", ")))")
}

let report = SceneCodec.apply(envelope, layout: layout, engine: engine)
if !opts.quiet {
    if !report.unknownParams.isEmpty {
        print("warning: unknown params preserved but not applied: "
            + report.unknownParams.joined(separator: ", "))
    }
    if !report.foreignParams.isEmpty {
        print("warning: foreign-shaped params preserved: "
            + report.foreignParams.joined(separator: ", "))
    }
    if !report.skippedNonScene.isEmpty {
        print("warning: non-scene-persisted params skipped by policy: "
            + report.skippedNonScene.joined(separator: ", "))
    }
    if !report.componentMismatches.isEmpty {
        print("warning: component-count mismatches not applied: "
            + report.componentMismatches.joined(separator: ", "))
    }
}

// Warp stack: DTO → ABI ops → exact simplification. The GPU sees the
// simplified buffer; the scene keeps the authored stack (plan §5.2).
let (rawOps, unknownKinds) = [ThreshWarpOp].fromDTOs(envelope.warpStack)
if !unknownKinds.isEmpty && !opts.quiet {
    print("warning: unknown warp op kinds preserved but not rendered: \(unknownKinds)")
}
let ops = WarpSimplifier.simplify(rawOps)

let camera = envelope.camera
let context: GPUContext
let renderer: OffscreenRenderer
do {
    context = try GPUContext()
    renderer = try OffscreenRenderer(context: context)
} catch {
    die("GPU init failed (the harness needs a Metal device): \(error)")
}

var perFrame: [FrameStats] = []
var lastResult: RenderResult?

for frame in 0..<opts.frames {
    clock.advance()
    let resolved = engine.resolve()

    var engineParams = EngineParams()
    engineParams.maxSteps = resolved.values[Int(THRESH_SLOT_MAX_STEPS)]
    engineParams.maxDist = resolved.values[Int(THRESH_SLOT_MAX_DIST)]
    engineParams.stepSafety = resolved.values[Int(THRESH_SLOT_STEP_SAFETY)]
    engineParams.iterations = resolved.values[Int(THRESH_SLOT_ITERATIONS)]
    engineParams.aoStrength = resolved.values[Int(THRESH_SLOT_AO_STRENGTH)]
    engineParams.shadowSoft = resolved.values[Int(THRESH_SLOT_SHADOW_SOFT)]
    let (params, deParamOffset) = ParamTableLayout.build(
        engine: engineParams,
        deParams: deParamValues(descriptor, layout: layout, resolved: resolved))

    var uniforms = ThreshFrameUniforms()
    uniforms.camPosFov = SIMD4(
        camera.position[0], camera.position[1], camera.position[2],
        tan(camera.fovYRadians * 0.5))
    // The kernel's quatRotate requires a unit quaternion; scene files carry
    // arbitrary floats. Degenerate orientations fall back to identity.
    let rawQuat = SIMD4(
        camera.orientation[0], camera.orientation[1],
        camera.orientation[2], camera.orientation[3])
    let quatLength = (rawQuat * rawQuat).sum().squareRoot()
    uniforms.camQuat = quatLength > 1e-6 && quatLength.isFinite
        ? rawQuat / quatLength
        : SIMD4(0, 0, 0, 1)
    uniforms.scaleCtx = SIMD4(Float(clock.now), 1e-3, 1, 1)
    uniforms.meta = SIMD4(
        UInt32(ops.count), descriptor.index,
        UInt32(params.count), UInt32(deParamOffset))

    let request = RenderRequest(
        uniforms: uniforms, params: params, ops: ops,
        width: opts.width, height: opts.height)
    do {
        let result = try renderer.render(request)
        perFrame.append(FrameStats(
            frame: frame, time: clock.now,
            totalSteps: result.stats.totalSteps,
            gpuMilliseconds: result.stats.gpuMilliseconds))
        lastResult = result
    } catch {
        die("render failed at frame \(frame): \(error)")
    }
}

guard let final = lastResult else { die("no frames rendered") }
writePNG(final, to: opts.outPath)

if let statsPath = opts.statsPath {
    let stats = RunStats(
        width: opts.width, height: opts.height, frames: opts.frames,
        deKey: descriptor.key,
        opCount: envelope.warpStack.count, simplifiedOpCount: ops.count,
        totalSteps: perFrame.reduce(0) { $0 + $1.totalSteps },
        averageGpuMilliseconds: perFrame.map(\.gpuMilliseconds).reduce(0, +)
            / Double(perFrame.count),
        perFrame: perFrame)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        try encoder.encode(stats).write(to: URL(fileURLWithPath: statsPath))
    } catch {
        die("stats write failed: \(error)")
    }
}

if !opts.quiet {
    let steps = perFrame.reduce(0) { $0 + $1.totalSteps }
    let ms = perFrame.map(\.gpuMilliseconds).reduce(0, +) / Double(perFrame.count)
    print("rendered \(opts.frames) frame(s) \(opts.width)x\(opts.height) de=\(descriptor.key) "
        + "ops=\(ops.count) steps=\(steps) avgGpu=\(String(format: "%.2f", ms))ms → \(opts.outPath)")
}

// Golden gate: byte compare (plan §9 — byte-compare on same GPU family).
if let goldenPath = opts.comparePath {
    guard let golden = FileManager.default.contents(atPath: goldenPath) else {
        die("cannot read golden \(goldenPath)")
    }
    let produced = FileManager.default.contents(atPath: opts.outPath)
    if produced == golden {
        if !opts.quiet { print("golden match: \(goldenPath)") }
    } else {
        FileHandle.standardError.write(Data("golden MISMATCH vs \(goldenPath)\n".utf8))
        exit(2)
    }
}
