// DeviceGPUBenchTests.swift — headless GPU-cost benchmark that runs on the
// REAL Apple Vision Pro GPU (the "Path A" measurement).
//
// It drives the existing FrameBenchmark over OffscreenRenderer's pure
// Metal-compute path — NO immersive space, NO Compositor Services, NO drawable
// — so `xcodebuild test` against a *physical* visionOS device measures the
// raymarch kernel's GPU command-buffer time on Apple Vision Pro silicon (not
// the Mac GPU, not the simulator, and with no headset-worn requirement).
//
// This is an APP-HOSTED unit-test target on purpose: on a physical device there
// is no host-less "logic test" fast-path, and MTLCreateSystemDefaultDevice()
// returns nil in a UI-less process — so the bundle runs inside Threshold.app to
// get a real Metal device. If it ever runs without one, the test FAILS (it does
// not silently skip), so a green-but-empty run can't hide a mis-hosted setup.
//
// WHAT THIS MEASURES (and does not): the GPU KERNEL cost of a frame — a
// relative comparator across optimization rounds. It sweeps a MATRIX of
// (per-eye resolution × eye count) in one run (the matrix is baked in code
// because shell env vars do NOT forward to an on-device test process). A stereo
// frame renders BOTH eye views and sums their GPU time, so fps is a stereo-frame
// rate. It is still NOT the true delivered frame cost: the real AVP per-eye
// views are FOVEATED (peripheral pixels cost less), so two FULL views here is an
// UPPER BOUND on the raymarch cost, and the compositor adds overhead on top. The
// GPU clock is also not pinned (DVFS/thermal float absolute ms), so compare
// deltas on the same warm device; for absolute numbers pin a performance state
// in Instruments' Metal Application instrument.
//
// Pull the result JSON off the headset with:
//   xcrun devicectl device copy from --device <UDID> \
//     --domain-type appDataContainer --domain-identifier com.pupppower.thresholdb3 \
//     --source Documents/threshold-device-bench.json --destination ./bench.json
// (or read the "DEVICE-BENCH …" line straight from the xcodebuild / xcresult log).

import Foundation
import Metal
import simd
import Testing
import ThresholdRender

private func envInt(_ key: String, _ fallback: Int) -> Int {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? fallback
}

/// One matrix cell: the distribution for a given (per-eye resolution × eyes).
private struct RunEntry: Codable {
    let size: Int
    let views: Int
    let result: FrameBenchmark.Result
}

/// Full sweep + provenance — deviceName PROVES the numbers came from AVP silicon
/// (not a Mac/simulator GPU); `runs` is one entry per matrix cell.
private struct SweepReport: Codable {
    let deviceName: String
    let deKey: String
    let maxSteps: Int
    let frames: Int
    let warmup: Int
    let runs: [RunEntry]
}

@Suite("Device GPU bench", .serialized)
struct DeviceGPUBenchTests {

    @Test
    func mandelbulbGPUSweep() throws {
        // FAIL, don't skip, when there's no Metal device — see file header.
        guard let mtl = MTLCreateSystemDefaultDevice() else {
            Issue.record("""
                No Metal device: the device bench must run on real hardware \
                (physical Apple Vision Pro), inside an app host — not a UI-less \
                test process or the offscreen simulator.
                """)
            return
        }

        let frames = envInt("THRESHOLD_BENCH_FRAMES", 120)
        let warmup = envInt("THRESHOLD_BENCH_WARMUP", 20)
        let maxSteps = envInt("THRESHOLD_BENCH_MAXSTEPS", 256)

        // Sweep matrix: one MONO reference, then a STEREO per-eye-resolution ramp
        // toward AVP-native (~1920² per eye) and up to the Mac suite's 2048² top
        // end. Baked here because shell env does not reach the on-device process.
        let matrix: [(size: Int, views: Int)] = [
            (1024, 1), (1024, 2), (1512, 2), (1920, 2), (2048, 2),
        ]

        let context = try GPUContext()
        let renderer = try OffscreenRenderer(context: context)

        // Public-API mandelbulb scene (camera (0,0,3) → origin, fov 60°, power-8
        // bulb = deIndex 1, no warp ops). Eyes step ±halfIPD along +X and
        // re-converge; the separation barely moves cost, it just keeps the two
        // eye dispatches from being byte-identical.
        var engine = EngineParams()
        engine.maxSteps = Float(maxSteps)
        let (params, deParamOffset) = ParamTableLayout.build(engine: engine, deParams: [8.0])
        let halfIPD: Float = 0.03
        func request(size: Int, eyeX: Float) -> RenderRequest {
            RenderRequest(
                uniforms: CameraMath.makeUniforms(
                    cameraPos: SIMD3(eyeX, 0, 3), target: .zero,
                    fovYRadians: Float.pi / 3,
                    opCount: 0, deIndex: 1,
                    paramCount: params.count, deParamOffset: deParamOffset),
                params: params, ops: [], width: size, height: size)
        }

        var runs: [RunEntry] = []
        for cfg in matrix {
            let eyeXs: [Float] = cfg.views >= 2 ? [-halfIPD, halfIPD] : [0]
            let requests = eyeXs.map { request(size: cfg.size, eyeX: $0) }
            // Each measured frame dispatches every eye view and sums their GPU
            // time; readback:false skips the pixel copy so we time GPU work only.
            let result = try FrameBenchmark.run(warmup: warmup, frames: frames) { _, _ in
                var gpuMs = 0.0
                var steps: UInt64 = 0
                for request in requests {
                    let s = try renderer.render(request, readback: false).stats
                    gpuMs += s.gpuMilliseconds
                    steps += s.totalSteps
                }
                return MarchStats(totalSteps: steps, gpuMilliseconds: gpuMs)
            }
            runs.append(RunEntry(size: cfg.size, views: cfg.views, result: result))
            // One line per cell — lands in the xcodebuild log / .xcresult.
            print("DEVICE-BENCH device=\(mtl.name) \(cfg.size)x\(cfg.size)×\(cfg.views)view "
                  + "maxSteps=\(maxSteps): " + result.summaryLine)
            #expect(result.medianMs > 0, "GPU frame time must be positive on real hardware")
            #expect(result.totalSteps > 0, "the raymarch must accumulate steps")
        }

        // JSON (one object, runs[]) into the host container for devicectl pull.
        let report = SweepReport(
            deviceName: mtl.name, deKey: "mandelbulb", maxSteps: maxSteps,
            frames: frames, warmup: warmup, runs: runs)
        if let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent("threshold-device-bench.json")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try enc.encode(report).write(to: url)
                print("DEVICE-BENCH wrote \(url.path)")
            } catch {
                print("DEVICE-BENCH could not write JSON: \(error)")
            }
        }

        #expect(runs.count == matrix.count)
    }
}
