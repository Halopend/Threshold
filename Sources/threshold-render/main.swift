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
    var outPathExplicit = false
    var statsPath: String?
    var comparePath: String?
    var writeDefaultScenePath: String?
    var width = 512
    var height = 512
    var frames = 1
    var step = 1.0 / 60.0
    var deKey = "mandelbulb"
    var quiet = false
    var specialize = false
    var skipVolume = false     // world-space empty-space skip (fc 11) A/B
    var skipGrid = 64
    var skipDense = false       // dense direct-index vs hashed occupancy
    var distanceCache = false
    var cacheExtent: Float?
    var cacheCapacity = 4
    var cacheDiagnosticPath: String?
    var benchFrames = 0        // > 0 → benchmark mode
    var benchWarmup = 8
    var benchJSONPath: String?
    var maxStepsOverride: Int?  // engine.maxSteps is device-local, not
                                // scene-persisted — the bench suite pins it

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
            case "--out": opts.outPath = next(arg); opts.outPathExplicit = true
            case "--stats": opts.statsPath = next(arg)
            case "--compare": opts.comparePath = next(arg)
            case "--write-default-scene": opts.writeDefaultScenePath = next(arg)
            case "--width", "-w": opts.width = intValue(next(arg), for: arg)
            case "--height", "-h": opts.height = intValue(next(arg), for: arg)
            case "--frames": opts.frames = intValue(next(arg), for: arg)
            case "--step": opts.step = doubleValue(next(arg), for: arg)
            case "--de": opts.deKey = next(arg)
            case "--quiet": opts.quiet = true
            case "--specialize": opts.specialize = true
            case "--skip-volume": opts.skipVolume = true
            case "--skip-grid": opts.skipGrid = intValue(next(arg), for: arg)
            case "--skip-dense": opts.skipDense = true
            case "--distance-cache": opts.distanceCache = true
            case "--cache-extent": opts.cacheExtent = Float(next(arg))
            case "--cache-capacity": opts.cacheCapacity = intValue(next(arg), for: arg)
            case "--cache-diagnostic": opts.cacheDiagnosticPath = next(arg)
            case "--bench": opts.benchFrames = intValue(next(arg), for: arg)
            case "--bench-warmup": opts.benchWarmup = intValue(next(arg), for: arg)
            case "--bench-json": opts.benchJSONPath = next(arg)
            case "--max-steps": opts.maxStepsOverride = intValue(next(arg), for: arg)
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
  --specialize                  render built-ins through the direct-call DE
                                pipeline variant (perf A/B; identical image)
  --bench <n>                   benchmark mode: warmup then n measured frames;
                                print median/p95 GPU ms + fps, skip PNG unless
                                --out was given explicitly
  --bench-warmup <n>            warmup frames before measuring (default 8)
  --bench-json <path>           write the benchmark result JSON
  --max-steps <n>               override engine.maxSteps (device-local, not
                                scene-persisted; the perf suite pins it)
  --distance-cache              view-invariant final-distance volume (A/B)
  --cache-extent <world units>  half-extent around model origin (default 8)
  --cache-capacity <n>          geometry-state LRU entries (default 4)
  --cache-diagnostic <path.png> write a centre-slice cache diagnostic
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

// Envelope contract: fractalTypeKey is IGNORED when embeddedDE is set. The
// external program loads after GPU init below (compile needs the device).
let builtinDescriptor: DEDescriptor?
if envelope.embeddedDE != nil {
    builtinDescriptor = nil
} else if let known = DERegistry.descriptor(forKey: envelope.fractalTypeKey) {
    builtinDescriptor = known
} else {
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

// Skip-volume (function_constant 11) A/B: constructed only for --skip-volume
// so a plain run is untouched. Built-ins only — ignored under an external DE.
let skipVolume: SkipVolume?
if opts.skipVolume || opts.distanceCache {
    do {
        skipVolume = try SkipVolume(
            context: context, gridResolution: opts.skipGrid,
            mode: opts.distanceCache ? .distance : (opts.skipDense ? .dense : .hashed),
            worldHalfExtent: opts.cacheExtent,
            cacheCapacity: opts.cacheCapacity)
        if !opts.quiet {
            print("skip-volume ON (grid \(opts.skipGrid)³, "
                + "\(opts.distanceCache ? "view-invariant distance cache" : (opts.skipDense ? "dense" : "hashed")))")
        }
    } catch {
        die("--skip-volume failed: \(error)")
    }
} else {
    skipVolume = nil
}

// External DE: compile → probe → accept, or die with the diagnostics
// (plan §7.2 — rejection surfaces the compiler output, never a crash).
let program: ExternalDEProgram?
let descriptor: DEDescriptor
if let embedded = envelope.embeddedDE {
    do {
        let loader = try ExternalDELoader(context: context)
        let loaded = try loader.load(embedded)
        program = loaded
        descriptor = loaded.descriptor
        if !opts.quiet {
            print("external DE \(descriptor.key): compiled, linked, probe passed")
        }
    } catch {
        die("embedded DE rejected: \(error)")
    }
} else {
    program = nil
    descriptor = builtinDescriptor!  // guaranteed by the guard above
}

// --specialize: compile the direct-call variant up front (the CLI is a
// batch tool — synchronous compile is fine here; the live session compiles
// asynchronously through SpecializationCache).
let specialized: SpecializedMarch?
if opts.specialize, program == nil {
    do {
        // Bake the function-constant knobs each env flag enables, from the
        // resolved values (function constants 1–5; the image is identical —
        // SpecializationTests). A/B harness: THRESHOLD_SPEC_ITERATIONS /
        // _MAXSTEPS / _HASOPS / _MAPMODE / _AO = 1. Read once here: a static
        // scene resolves constant values; an animated value keeps this initial
        // one and would surface as a --compare mismatch, not a silent drift.
        // All bakes ON by default. The constant bakes (iterations/steps/ops/
        // map/AO) are byte-identical; --specialize as a whole is the PERF
        // pipeline (fast math since block 8, cone prepass since block 9) and
        // NO LONGER byte-identical to generic — goldens gate the generic
        // pipeline. THRESHOLD_SPEC_<KNOB>=0 disables one knob for A/B.
        let r = engine.resolve().values
        let flags = ProcessInfo.processInfo.environment
        func on(_ key: String) -> Bool { flags[key] != "0" }
        let spec = MarchSpec(
            iterations: on("THRESHOLD_SPEC_ITERATIONS")
                ? Int(r[Int(THRESH_SLOT_ITERATIONS)]) : nil,
            maxSteps: on("THRESHOLD_SPEC_MAXSTEPS")
                ? (opts.maxStepsOverride ?? Int(r[Int(THRESH_SLOT_MAX_STEPS)])) : nil,
            hasWarpOps: on("THRESHOLD_SPEC_HASOPS") ? !ops.isEmpty : nil,
            colorMapMode: on("THRESHOLD_SPEC_MAPMODE")
                ? Int(r[Int(THRESH_SLOT_MAP_MODE)]) : nil,
            aoEnabled: on("THRESHOLD_SPEC_AO")
                ? (r[Int(THRESH_SLOT_AO_STRENGTH)] > 0) : nil,
            hasDistanceOps: ops.contains {
                $0.kind >= UInt32(THRESH_WARP_KIND_DISTANCE_OP_BASE)
            },
            // Benchmark runs drop the per-pixel stats atomic unless --stats
            // asked for step counts (pure telemetry; image unchanged).
            statsEnabled: !(opts.benchFrames > 0 && opts.statsPath == nil),
            // Hierarchical tile prepass (THRESHOLD_SPEC_CONE=0 for A/B).
            coneMarch: on("THRESHOLD_SPEC_CONE"),
            // Cone stop margin (shimmer↔speed): THRESHOLD_CONE_MARGIN=<int>,
            // default nil → the shader's 3× (block-9 baseline preserved).
            coneMargin: on("THRESHOLD_SPEC_CONE")
                ? flags["THRESHOLD_CONE_MARGIN"].flatMap(Int.init) : nil,
            // Distance-LOD falloff (iterations shed across the depth range):
            // THRESHOLD_LOD_FALLOFF=<int>, default off — an approximation
            // lever, so it is opt-in even on the perf pipeline until the
            // A/B (perf block 15) settles a default.
            lodFalloff: flags["THRESHOLD_LOD_FALLOFF"].flatMap(Int.init))
        specialized = try context.makeSpecializedMarch(
            deFunctionName: descriptor.mslFunctionName, spec: spec)
        if !opts.quiet {
            print("specialized pipeline: \(descriptor.mslFunctionName)"
                + (spec.isEmpty ? "" : " baked[\(spec.summary)]"))
        }
    } catch {
        die("--specialize failed: \(error)")
    }
} else {
    specialized = nil
    if opts.specialize && !opts.quiet {
        print("warning: --specialize ignored (external DE active)")
    }
}

/// External DE params are not catalog-registered (the catalog froze before
/// the scene was read) — they resolve from the scene file directly under
/// `de.external.<name>`, falling back to declared defaults.
func externalDEParamValues(_ descriptor: DEDescriptor, envelope: SceneEnvelope) -> [Float] {
    descriptor.paramLayout.map { param in
        envelope.params["de.external.\(param.name)"]?.first ?? param.default
    }
}

var perFrame: [FrameStats] = []
var lastResult: RenderResult?

// Immutable snapshot for the render closure (top-level `var` is main-actor
// isolated under Swift 6; the scene never mutates past this point).
let scene = envelope

/// One frame through the full scene path: advance the fixed-step clock,
/// resolve, build the request, render. Shared by the normal frame loop and
/// --bench mode so the benchmark measures exactly the production path.
// Env measurement seams, parsed once (ProcessInfo.environment re-bridges the
// whole dictionary per access — not free inside the frame loop).
let envStepMultiplier = ProcessInfo.processInfo.environment["THRESHOLD_STEP_MULTIPLIER"]
    .flatMap(Float.init)
let envEpsScale = ProcessInfo.processInfo.environment["THRESHOLD_EPS_SCALE"]
    .flatMap(Float.init) ?? 1

/// `readback: false` skips the pixel copy for timing-only bench frames.
@MainActor
func renderOneFrame(_ frame: Int, readback: Bool = true) throws -> RenderResult {
    clock.advance()
    let resolved = engine.resolve()

    var engineParams = EngineParams()
    engineParams.maxSteps = opts.maxStepsOverride.map(Float.init)
        ?? resolved.values[Int(THRESH_SLOT_MAX_STEPS)]
    engineParams.maxDist = resolved.values[Int(THRESH_SLOT_MAX_DIST)]
    engineParams.stepSafety = resolved.values[Int(THRESH_SLOT_STEP_SAFETY)]
    // Over-relaxed sphere tracing by default: when the resolved safety is the
    // conservative legacy default (≤ 1), march at this DE's per-formula ω cap
    // — the kernel's overshoot retreat keeps surfaces intact.
    if engineParams.stepSafety <= 1.0 {
        engineParams.stepSafety = descriptor.stepRelaxation
    }
    // Measurement override: engine.stepSafety is .deviceLocal (not scene-
    // persisted), so THRESHOLD_STEP_MULTIPLIER is the CLI A/B knob for the
    // over-relaxation factor ω.
    if let omega = envStepMultiplier {
        engineParams.stepSafety = omega
    }
    engineParams.iterations = resolved.values[Int(THRESH_SLOT_ITERATIONS)]
    engineParams.aoStrength = resolved.values[Int(THRESH_SLOT_AO_STRENGTH)]
    engineParams.shadowSoft = resolved.values[Int(THRESH_SLOT_SHADOW_SOFT)]
    engineParams.gradientRepeat = resolved.values[Int(THRESH_SLOT_GRAD_REPEAT)]
    engineParams.gradientOffset = resolved.values[Int(THRESH_SLOT_GRAD_OFFSET)]
    engineParams.gradientSmoothing = resolved.values[Int(THRESH_SLOT_GRAD_SMOOTH)]
    engineParams.colorMapMode = resolved.values[Int(THRESH_SLOT_MAP_MODE)]
    engineParams.saturation = resolved.values[Int(THRESH_SLOT_SATURATION)]
    engineParams.contrast = resolved.values[Int(THRESH_SLOT_CONTRAST)]
    engineParams.vibrance = resolved.values[Int(THRESH_SLOT_VIBRANCE)]
    engineParams.brightness = resolved.values[Int(THRESH_SLOT_BRIGHTNESS)]
    engineParams.gamma = resolved.values[Int(THRESH_SLOT_GAMMA)]
    engineParams.tonemap = resolved.values[Int(THRESH_SLOT_TONEMAP)]
    engineParams.bubbleEnabled = resolved.values[Int(THRESH_SLOT_BUBBLE_ENABLED)]
    engineParams.bubbleRadius = resolved.values[Int(THRESH_SLOT_BUBBLE_RADIUS)]
    engineParams.bubbleShape = resolved.values[Int(THRESH_SLOT_BUBBLE_SHAPE)]
    engineParams.bubbleBlend = resolved.values[Int(THRESH_SLOT_BUBBLE_BLEND)]
    let dbgDE = program != nil
            ? externalDEParamValues(descriptor, envelope: scene)
            : deParamValues(descriptor, layout: layout, resolved: resolved)
    let (params, deParamOffset) = ParamTableLayout.build(
        engine: engineParams,
        deParams: dbgDE)

    // Camera: base pose + resolved rig offsets, same derivation as the
    // interactive session (SessionCore.step). CameraRig handles degenerate
    // quaternions (identity fallback).
    var uniforms = ThreshFrameUniforms()
    func rigValue(_ key: ParamKey, _ fallback: Float) -> Float {
        layout.slot(for: key).map { resolved.values[$0] } ?? fallback
    }
    let pose = CameraRig.pose(
        base: camera,
        yaw: rigValue(.cameraOrbitYaw, 0),
        pitch: rigValue(.cameraOrbitPitch, 0),
        dolly: rigValue(.cameraDolly, 1))
    uniforms.camPosFov = SIMD4(pose.position, tan(camera.fovYRadians * 0.5))
    uniforms.camQuat = pose.orientation
    // Zoom (plan §6.3): resolved scale.zoom → ScaleContext, same derivation
    // as the interactive session (SessionCore.step).
    let scaleContext = ScaleContext(
        zoomOctaves: layout.slot(for: .scaleZoom).map { resolved.values[$0] } ?? 0,
        octave: scene.scaleOctave)
    // Measurement seam: THRESHOLD_EPS_SCALE multiplies the cone-epsilon base
    // (accuracy↔steps A/B knob; > 1 accepts surfaces earlier).
    uniforms.scaleCtx = SIMD4(
        Float(clock.now), scaleContext.epsilonBase * envEpsScale,
        scaleContext.modelScale, 1)
    uniforms.meta = SIMD4(
        UInt32(ops.count), descriptor.index,
        UInt32(params.count), UInt32(deParamOffset))

    let request = RenderRequest(
        uniforms: uniforms, params: params, ops: ops,
        palette: scene.palette?.stops ?? [],
        width: opts.width, height: opts.height)
    return try renderer.render(request, program: program,
                               specialized: specialized, readback: readback,
                               skipVolume: skipVolume)
}

if opts.benchFrames > 0 {
    // Benchmark mode: warmup + measured frames through the identical path.
    // (Loop stays at top level — the render state is main-actor; the
    // statistics live in the library's FrameBenchmark.summarize.)
    do {
        for frame in 0..<max(0, opts.benchWarmup) {
            _ = try renderOneFrame(frame, readback: false)
        }
        var samples: [Double] = []
        var benchSteps: UInt64 = 0
        for frame in 0..<opts.benchFrames {
            // Pixels are only needed on the final frame, and only for --out.
            let last = frame == opts.benchFrames - 1
            let r = try renderOneFrame(opts.benchWarmup + frame,
                                       readback: last && opts.outPathExplicit)
            samples.append(r.stats.gpuMilliseconds)
            benchSteps += r.stats.totalSteps
            lastResult = r
        }
        let result = FrameBenchmark.summarize(
            warmup: max(0, opts.benchWarmup), samples: samples,
            totalSteps: benchSteps)
        print("bench \(opts.width)x\(opts.height) de=\(descriptor.key) "
            + "ops=\(ops.count)\(specialized != nil ? " specialized" : ""): "
            + result.summaryLine)
        if let path = opts.benchJSONPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: URL(fileURLWithPath: path))
        }
        if opts.outPathExplicit, let final = lastResult {
            writePNG(final, to: opts.outPath)
        }
        if let path = opts.cacheDiagnosticPath,
           let diagnostic = skipVolume?.diagnosticImage() {
            writePNG(RenderResult(
                rgba8: diagnostic.rgba8, width: diagnostic.width,
                height: diagnostic.height,
                stats: MarchStats(totalSteps: 0, gpuMilliseconds: 0)),
                to: path)
        }
        if let cache = skipVolume, opts.distanceCache, !opts.quiet {
            let m = cache.cacheMetrics
            let residentMiB = String(
                format: "%.2f", Double(m.residentBytes) / 1_048_576)
            print("distance-cache hits=\(m.hits) misses=\(m.misses) "
                + "builds=\(m.builds) evictions=\(m.evictions) "
                + "residentMiB=\(residentMiB)")
        }
    } catch {
        die("benchmark failed: \(error)")
    }
    exit(0)
}

for frame in 0..<opts.frames {
    do {
        let result = try renderOneFrame(frame)
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
if let path = opts.cacheDiagnosticPath,
   let diagnostic = skipVolume?.diagnosticImage() {
    let image = RenderResult(
        rgba8: diagnostic.rgba8, width: diagnostic.width,
        height: diagnostic.height,
        stats: MarchStats(totalSteps: 0, gpuMilliseconds: 0))
    writePNG(image, to: path)
}

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
