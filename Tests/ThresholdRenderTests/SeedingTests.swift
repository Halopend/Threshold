// SeedingTests.swift — phase A2 of the temporal-reconstruction plan:
// temporal seeding (history warm-start for the primary march, fc 12).
//
// The contract under test:
//   1. Seeding CUTS march steps on a converged, hit-dominated frame — the
//      whole point. The bar (seeded/unseeded step ratio ≤ 0.8) needs a
//      hit-DOMINATED framing (camera ~2.35 from origin): miss rays can never
//      be seeded (surfaces must be able to morph into empty space), so a
//      wide framing dilutes the ratio toward 1.
//   2. The restart valve fires when the world morphs under a seed: the one
//      mapScene tap rejects stale seeds (counted in stats.seedRestarts) and
//      the frame stays correct.
//   3. Converged image quality is preserved within the measured cost
//      (seeded rays inherit last frame's surface estimate → slightly less
//      independent sub-pixel information; prior measurement −0.6 dB).
//   4. Every gate that DISARMS seeding is byte-invisible: high volatility
//      (≥ 0.5) or seedingEnabled=false must produce exactly the phase-A
//      image, frame for frame.
//
// The opt-in SeedingBenchTests suite at the bottom is the long-run
// interleaved A/B cost harness (THRESHOLD_SEED_BENCH=1) — not part of the
// regular suite.

import Foundation
import Metal
import simd
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

// MARK: - Shared fixture (the TemporalResolveTests shape)

enum SeedingFixture {

    /// Hit-dominated camera: ~2.35 from origin along the parity tests' view
    /// axis — the mandelbulb fills the frame, so nearly every ray is
    /// seedable. (The step-cut assertion is meaningless on a wide framing.)
    static let hitDominatedCamera = SIMD3<Float>(0.290, 0.218, 2.322)

    static func makeRequest(
        width: Int, height: Int, scale: Float,
        cameraPos: SIMD3<Float>? = nil, deParams: [Float]? = nil
    ) -> RenderRequest {
        var engine = EngineParams()
        engine.aoStrength = 0.6
        let de = DERegistry.descriptor(forKey: "mandelbulb")!
        let (params, deParamOffset) = ParamTableLayout.build(
            engine: engine, deParams: deParams ?? de.paramLayout.map(\.default))
        let uniforms = CameraMath.makeUniforms(
            cameraPos: cameraPos ?? SIMD3(0.4, 0.3, 3.2), target: .zero,
            fovYRadians: Float.pi / 3,
            epsilonBase: 1.5e-3, modelScale: 1,
            opCount: 0, deIndex: Int(de.index),
            paramCount: params.count, deParamOffset: deParamOffset)
        var request = RenderRequest(
            uniforms: uniforms, params: params, ops: [],
            palette: PaletteWire.defaultStops,
            width: width, height: height, renderScale: scale)
        request.tuning.specializationEnabled = false
        return request
    }

    static func makeView(_ request: RenderRequest) -> ThreshViewUniforms {
        CompositorViewMath.viewUniforms(
            projection: CompositorViewMath.pinholeProjection(
                fovTan: request.uniforms.camPosFov.w,
                aspect: Float(request.width) / Float(request.height)),
            eyeToRoom: matrix_identity_float4x4,
            anchorPosition: .zero,
            base: request.uniforms)
    }

    static func makeTargets(
        _ device: MTLDevice, width: Int, height: Int
    ) throws -> (color: MTLTexture, depth: MTLTexture) {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = [.shaderRead]
        depthDesc.storageMode = .shared
        return (try #require(device.makeTexture(descriptor: colorDesc)),
                try #require(device.makeTexture(descriptor: depthDesc)))
    }

    /// One frame through the real encoder; waits for completion and returns
    /// the frame's completed stats (steps, restart count, GPU ms). The stats
    /// slot is written on Metal's completion thread — poll until it moves
    /// past `prior`.
    @discardableResult
    static func renderFrame(
        _ request: RenderRequest, encoder: ViewComputeEncoder,
        view: ThreshViewUniforms, prevView: ThreshViewUniforms?,
        recon: TemporalReconstructor?,
        targets: (color: MTLTexture, depth: MTLTexture),
        queue: MTLCommandQueue
    ) throws -> FrameStatsSlot.Stats {
        let prior = encoder.lastCompleted()
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let ok = encoder.encode(
            request, views: [view],
            colorTargets: [(targets.color, 0)], depthTargets: [(targets.depth, 0)],
            commandBuffer: commandBuffer, recon: recon,
            prevViews: prevView.map { [$0] })
        #expect(ok, "encode must accept the request")
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.error == nil)
        for _ in 0..<500 {
            let s = encoder.lastCompleted()
            if s.gpuMilliseconds != prior.gpuMilliseconds
                || s.totalSteps != prior.totalSteps {
                return s
            }
            usleep(200)
        }
        return encoder.lastCompleted()
    }

    static func readRGBA(_ texture: MTLTexture) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        rgba.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0)
        }
        return rgba
    }

    /// PSNR over RGB (alpha is presentation semantics).
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sse = 0.0
        var n = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            for c in i..<(i + 3) {
                let d = Double(a[c]) - Double(b[c])
                sse += d * d
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mse = sse / Double(n)
        guard mse > 0 else { return .infinity }
        return 10 * log10(255.0 * 255.0 / mse)
    }

    /// The scene at 2× the target size, box-downfiltered — the band-limited
    /// reference (the TemporalResolveTests convention).
    static func renderSupersampledGolden(
        _ ctx: GPUContext, width: Int, height: Int,
        cameraPos: SIMD3<Float>? = nil, queue: MTLCommandQueue
    ) throws -> [UInt8] {
        let request = makeRequest(
            width: width * 2, height: height * 2, scale: 1, cameraPos: cameraPos)
        let encoder = try ViewComputeEncoder(context: ctx, colorFormat: .rgba8Unorm)
        let targets = try makeTargets(ctx.device, width: width * 2, height: height * 2)
        try renderFrame(
            request, encoder: encoder, view: makeView(request), prevView: nil,
            recon: nil, targets: targets, queue: queue)
        let big = readRGBA(targets.color)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let bw = width * 2
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<4 {
                    var sum = 0
                    for dy in 0...1 {
                        for dx in 0...1 {
                            sum += Int(big[((y * 2 + dy) * bw + x * 2 + dx) * 4 + c])
                        }
                    }
                    out[(y * width + x) * 4 + c] = UInt8((sum + 2) / 4)
                }
            }
        }
        return out
    }
}

// MARK: - Phase A2 acceptance

@Suite("Temporal seeding (phase A2)", .serialized)
struct SeedingTests {
    private typealias F = SeedingFixture

    /// 1 — the win: on a converged, hit-dominated TAAU frame, seeded march
    /// steps come in at ≤ 0.8× the unseeded count (measured ~0.5–0.65 on
    /// close framings; 0.847 wide-framed is exactly why the camera matters).
    @Test(.enabled(if: GPU.available))
    func seedingCutsStepsOnAConvergedHistory() throws {
        let ctx = try GPU.ctx()
        let (w, h) = (128, 128)
        let queue = try #require(ctx.device.makeCommandQueue())
        let request = F.makeRequest(
            width: w, height: h, scale: 0.5,
            cameraPos: F.hitDominatedCamera)
        let encoder = try ViewComputeEncoder(context: ctx, colorFormat: .rgba8Unorm)
        let recon = try TemporalReconstructor(context: ctx, colorFormat: .rgba8Unorm)
        recon.mode = .taau
        let view = F.makeView(request)
        let targets = try F.makeTargets(ctx.device, width: w, height: h)

        // Converge unseeded, then measure one more unseeded frame.
        for _ in 0..<12 {
            try F.renderFrame(request, encoder: encoder, view: view,
                              prevView: view, recon: recon, targets: targets,
                              queue: queue)
        }
        let unseeded = try F.renderFrame(
            request, encoder: encoder, view: view, prevView: view,
            recon: recon, targets: targets, queue: queue)
        #expect(unseeded.totalSteps > 0, "step telemetry must be live")
        #expect(unseeded.seedRestarts == 0, "no seeding → no restarts")

        // Arm seeding for the measured frame.
        recon.seedingEnabled = true
        let seeded = try F.renderFrame(
            request, encoder: encoder, view: view, prevView: view,
            recon: recon, targets: targets, queue: queue)
        let ratio = Double(seeded.totalSteps) / Double(max(unseeded.totalSteps, 1))
        #expect(ratio <= 0.8,
                Comment(rawValue: "seeded steps must be ≤0.8× unseeded (got \(ratio): \(seeded.totalSteps) vs \(unseeded.totalSteps))"))
    }

    /// The morph fixture shared by the two valve claims: converge unseeded,
    /// then render ONE frame of a morphed world with seeding forced past the
    /// host gate (volatility deliberately left 0 — the per-ray DE tap is the
    /// layer under test).
    private func morphFrame(
        _ ctx: GPUContext, queue: MTLCommandQueue, power: Float,
        seedFinalFrame: Bool
    ) throws -> (image: [UInt8], stats: FrameStatsSlot.Stats) {
        let (w, h) = (128, 128)
        let request = F.makeRequest(
            width: w, height: h, scale: 0.5, cameraPos: F.hitDominatedCamera)
        let de = DERegistry.descriptor(forKey: "mandelbulb")!
        var morphedParams = de.paramLayout.map(\.default)
        morphedParams[0] = power
        let morphed = F.makeRequest(
            width: w, height: h, scale: 0.5, cameraPos: F.hitDominatedCamera,
            deParams: morphedParams)
        let encoder = try ViewComputeEncoder(context: ctx, colorFormat: .rgba8Unorm)
        let recon = try TemporalReconstructor(context: ctx, colorFormat: .rgba8Unorm)
        recon.mode = .taau
        let view = F.makeView(request)
        let targets = try F.makeTargets(ctx.device, width: w, height: h)
        for _ in 0..<10 {
            try F.renderFrame(request, encoder: encoder, view: view,
                              prevView: view, recon: recon,
                              targets: targets, queue: queue)
        }
        recon.seedingEnabled = seedFinalFrame
        let stats = try F.renderFrame(
            morphed, encoder: encoder, view: view, prevView: view,
            recon: recon, targets: targets, queue: queue)
        return (F.readRGBA(targets.color), stats)
    }

    /// 2a — the restart valve fires: a HARD morph (power 8 → 6, a change the
    /// production volatility gate would never seed through — bypassed here
    /// on purpose) leaves converged hit distances inside the new surface;
    /// the DE validation tap must catch rays and count them. (Image quality
    /// under a hard morph is NOT asserted — that morph is outside the
    /// seeding envelope by design; the volatility gate owns it.)
    @Test(.enabled(if: GPU.available))
    func seedRestartValveFiresOnAHardMorph() throws {
        let ctx = try GPU.ctx()
        let queue = try #require(ctx.device.makeCommandQueue())
        let seeded = try morphFrame(ctx, queue: queue, power: 6, seedFinalFrame: true)
        #expect(seeded.stats.seedRestarts > 0,
                Comment(rawValue: "a hard morph must trip the valve (restarts=\(seeded.stats.seedRestarts))"))
    }

    /// 2b — the seeding envelope preserves the image: a SMALL morph (power
    /// 8 → 7.9, the kind of continuous parameter drift seeding exists to
    /// survive) rendered seeded vs unseeded from identical histories must
    /// agree — the valve plus the backoff absorb the surface motion.
    @Test(.enabled(if: GPU.available))
    func seededSmallMorphMatchesUnseeded() throws {
        let ctx = try GPU.ctx()
        let queue = try #require(ctx.device.makeCommandQueue())
        let seeded = try morphFrame(ctx, queue: queue, power: 7.9, seedFinalFrame: true)
        let unseeded = try morphFrame(ctx, queue: queue, power: 7.9, seedFinalFrame: false)
        let agreement = F.psnr(seeded.image, unseeded.image)
        #expect(agreement >= 30,
                Comment(rawValue: "seeded small-morph frame must match unseeded (\(agreement) dB)"))
    }

    /// 3 — image preservation: seeding from frame 2 onward converges within
    /// 1.2 dB of the never-seeded run against the supersampled golden (the
    /// measured cost was −0.6 dB: seeded rays inherit last frame's surface
    /// estimate, so accumulation carries slightly less independent
    /// sub-pixel information).
    @Test(.enabled(if: GPU.available))
    func seedingPreservesTheConvergedImage() throws {
        let ctx = try GPU.ctx()
        let (w, h) = (128, 128)
        let queue = try #require(ctx.device.makeCommandQueue())
        let golden = try F.renderSupersampledGolden(
            ctx, width: w, height: h, cameraPos: F.hitDominatedCamera,
            queue: queue)
        let request = F.makeRequest(
            width: w, height: h, scale: 0.5, cameraPos: F.hitDominatedCamera)

        func converge(seeding: Bool) throws -> [UInt8] {
            let encoder = try ViewComputeEncoder(context: ctx, colorFormat: .rgba8Unorm)
            let recon = try TemporalReconstructor(context: ctx, colorFormat: .rgba8Unorm)
            recon.mode = .taau
            recon.seedingEnabled = seeding
            let view = F.makeView(request)
            let targets = try F.makeTargets(ctx.device, width: w, height: h)
            for _ in 0..<32 {
                try F.renderFrame(request, encoder: encoder, view: view,
                                  prevView: view, recon: recon,
                                  targets: targets, queue: queue)
            }
            return F.readRGBA(targets.color)
        }

        let psnrUnseeded = F.psnr(try converge(seeding: false), golden)
        let psnrSeeded = F.psnr(try converge(seeding: true), golden)
        #expect(psnrSeeded >= psnrUnseeded - 1.2,
                Comment(rawValue: "seeding may cost at most 1.2 dB converged (unseeded \(psnrUnseeded), seeded \(psnrSeeded))"))
    }

    /// 4 — disarm paths are byte-invisible: with seeding ENABLED but the
    /// volatility gate blocking (≥ 0.5), every frame must equal the
    /// seeding-disabled run exactly — the phase-A path, bit for bit. (Also
    /// pins the host gate itself: a fresh reconstructor with no history
    /// hands out no seed texture.)
    @Test(.enabled(if: GPU.available))
    func blockedSeedingIsByteInvisible() throws {
        let ctx = try GPU.ctx()
        let (w, h) = (96, 96)
        let queue = try #require(ctx.device.makeCommandQueue())
        var request = F.makeRequest(
            width: w, height: h, scale: 0.5, cameraPos: F.hitDominatedCamera)
        request.worldVolatility = 0.6   // above the 0.5 seeding gate

        func run(seedingEnabled: Bool) throws -> [UInt8] {
            let encoder = try ViewComputeEncoder(context: ctx, colorFormat: .rgba8Unorm)
            let recon = try TemporalReconstructor(context: ctx, colorFormat: .rgba8Unorm)
            recon.mode = .taau
            recon.seedingEnabled = seedingEnabled
            #expect(recon.seedTexture(volatility: 0, accWidth: w, accHeight: h,
                                      slices: 1) == nil,
                    "no history yet → no seed texture, regardless of arming")
            let view = F.makeView(request)
            let targets = try F.makeTargets(ctx.device, width: w, height: h)
            for _ in 0..<8 {
                try F.renderFrame(request, encoder: encoder, view: view,
                                  prevView: view, recon: recon,
                                  targets: targets, queue: queue)
            }
            return F.readRGBA(targets.color)
        }

        let blocked = try run(seedingEnabled: true)
        let disabled = try run(seedingEnabled: false)
        #expect(blocked == disabled,
                "volatility-blocked seeding must be EXACTLY the phase-A path")
    }
}

// MARK: - Long-run interleaved cost bench (opt-in)

/// The equalized-number harness: interleaves configurations round-robin
/// (unseeded/seeded × modes) so thermal and DVFS drift hits every config
/// equally, then reports per-round and pooled medians. Not a pass/fail perf
/// gate — it PRINTS and RECORDS; the only assertions are sanity.
///
/// Run:
///   THRESHOLD_SEED_BENCH=1 swift test --filter SeedingBenchTests
/// Knobs (env):
///   THRESHOLD_SEED_BENCH_SIZE    output side, default 2048
///   THRESHOLD_SEED_BENCH_SCALE   march scale, default 0.5
///   THRESHOLD_SEED_BENCH_FRAMES  measured frames per segment, default 120
///   THRESHOLD_SEED_BENCH_WARMUP  warmup frames per segment, default 16
///   THRESHOLD_SEED_BENCH_ROUNDS  interleaved rounds, default 4
@Suite("Seeding bench (opt-in)", .serialized)
struct SeedingBenchTests {
    private typealias F = SeedingFixture

    private static var armed: Bool {
        ProcessInfo.processInfo.environment["THRESHOLD_SEED_BENCH"] == "1"
    }

    private static func envInt(_ key: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? fallback
    }

    private struct Config {
        let name: String
        let mode: TemporalReconstructor.Mode?   // nil = phase-0 spatial
        let seeding: Bool
    }

    private struct Segment {
        var gpuMs: [Double] = []
        var steps: [UInt64] = []
        var restarts: [UInt64] = []
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2]
            : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    @Test(.enabled(if: GPU.available && armed))
    func interleavedSeedBench() throws {
        let ctx = try GPU.ctx()
        let size = Self.envInt("THRESHOLD_SEED_BENCH_SIZE", 2048)
        let scale = Float(ProcessInfo.processInfo
            .environment["THRESHOLD_SEED_BENCH_SCALE"].flatMap(Double.init) ?? 0.5)
        let frames = Self.envInt("THRESHOLD_SEED_BENCH_FRAMES", 120)
        let warmup = Self.envInt("THRESHOLD_SEED_BENCH_WARMUP", 16)
        let rounds = Self.envInt("THRESHOLD_SEED_BENCH_ROUNDS", 4)
        let queue = try #require(ctx.device.makeCommandQueue())

        let request = F.makeRequest(
            width: size, height: size, scale: scale,
            cameraPos: F.hitDominatedCamera)
        let view = F.makeView(request)
        let targets = try F.makeTargets(ctx.device, width: size, height: size)

        let configs: [Config] = [
            Config(name: "spatial",        mode: nil,        seeding: false),
            Config(name: "stabilize",      mode: .stabilize, seeding: false),
            Config(name: "stabilize+seed", mode: .stabilize, seeding: true),
            Config(name: "taau",           mode: .taau,      seeding: false),
            Config(name: "taau+seed",      mode: .taau,      seeding: true),
        ]

        // One persistent encoder+recon per config: history convergence is
        // part of the steady state being measured, and reusing them across
        // rounds means later rounds measure a converged pipeline.
        var encoders: [ViewComputeEncoder] = []
        var recons: [TemporalReconstructor] = []
        for config in configs {
            encoders.append(try ViewComputeEncoder(context: ctx, colorFormat: .rgba8Unorm))
            let recon = try TemporalReconstructor(context: ctx, colorFormat: .rgba8Unorm)
            recon.mode = config.mode ?? .off
            recon.seedingEnabled = config.seeding
            recons.append(recon)
        }

        var results: [[Segment]] = Array(
            repeating: [], count: configs.count)

        let clock = ContinuousClock()
        let started = clock.now
        for round in 0..<rounds {
            for (i, _) in configs.enumerated() {
                var segment = Segment()
                for frame in 0..<(warmup + frames) {
                    let stats = try F.renderFrame(
                        request, encoder: encoders[i], view: view,
                        prevView: view, recon: recons[i], targets: targets,
                        queue: queue)
                    if ProcessInfo.processInfo.environment["THRESHOLD_SEED_BENCH_DEBUG"] != nil,
                       frame < 3 {
                        print("DBG \(configs[i].name) f\(frame): ms=\(stats.gpuMilliseconds) steps=\(stats.totalSteps) restarts=\(stats.seedRestarts)")
                    }
                    if frame >= warmup {
                        segment.gpuMs.append(stats.gpuMilliseconds)
                        segment.steps.append(stats.totalSteps)
                        segment.restarts.append(stats.seedRestarts)
                    }
                }
                results[i].append(segment)
                print(String(
                    format: "round %d %-14s median %7.3f ms  steps %9d  restarts %7d",
                    round, (configs[i].name as NSString).utf8String!,
                    Self.median(segment.gpuMs),
                    Int(Self.median(segment.steps.map { Double($0) })),
                    Int(Self.median(segment.restarts.map { Double($0) }))))
            }
        }
        let wall = clock.now - started

        // Converged-quality readout (once, after the bench, so the PSNR pass
        // never sits inside the timed segments): each config's current frame
        // against the supersampled golden.
        let golden = try F.renderSupersampledGolden(
            ctx, width: size, height: size,
            cameraPos: F.hitDominatedCamera, queue: queue)
        var psnrs: [Double] = []
        for (i, _) in configs.enumerated() {
            try F.renderFrame(request, encoder: encoders[i], view: view,
                              prevView: view, recon: recons[i],
                              targets: targets, queue: queue)
            psnrs.append(F.psnr(F.readRGBA(targets.color), golden))
        }

        // Report: pooled medians + per-round spread (the equalization check —
        // if round medians drift monotonically, the run was thermally dirty).
        var csv = "config,round,medianMs,p25Ms,p75Ms,medianSteps,medianRestarts,psnrDb\n"
        print("\n=== seed bench: \(size)²@\(String(format: "%.2f", scale)), "
              + "\(frames)f × \(rounds) rounds, generic pipeline, 1 view, "
              + "wall \(wall) ===")
        for (i, config) in configs.enumerated() {
            let all = results[i].flatMap(\.gpuMs)
            let sorted = all.sorted()
            let p25 = sorted[sorted.count / 4]
            let p75 = sorted[(sorted.count * 3) / 4]
            let roundMedians = results[i].map { Self.median($0.gpuMs) }
            let pooled = Self.median(all)
            let steps = Self.median(results[i].flatMap(\.steps).map { Double($0) })
            let restarts = Self.median(results[i].flatMap(\.restarts).map { Double($0) })
            print(String(
                format: "%-14s pooled %7.3f ms  (p25 %7.3f, p75 %7.3f)  rounds %@  steps %9d  restarts %7d  psnr %5.2f dB",
                (config.name as NSString).utf8String!, pooled, p25, p75,
                roundMedians.map { String(format: "%.2f", $0) }
                    .joined(separator: "/"),
                Int(steps), Int(restarts), psnrs[i]))
            for (r, m) in roundMedians.enumerated() {
                csv += "\(config.name),\(r),\(String(format: "%.4f", m)),"
                    + "\(String(format: "%.4f", p25)),\(String(format: "%.4f", p75)),"
                    + "\(Int(steps)),\(Int(restarts)),\(String(format: "%.3f", psnrs[i]))\n"
            }
        }

        // Record next to the other bench artifacts (bench-results/ is
        // git-ignored on this branch; history.csv stays untouched — its
        // schema belongs to bench-suite.sh).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ThresholdRenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let out = root.appendingPathComponent(
            "bench-results/seed-bench-\(size).csv")
        try? csv.write(to: out, atomically: true, encoding: .utf8)
        print("csv: \(out.path)")

        // Sanity only — the numbers are the deliverable, not a gate.
        #expect(results.allSatisfy { !$0.isEmpty })
    }
}
