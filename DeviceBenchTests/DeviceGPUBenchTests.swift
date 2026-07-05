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
// WHAT THIS MEASURES (and does not): the GPU KERNEL cost of one march — a
// relative comparator across optimization rounds. It is NOT the true delivered
// frame cost: the real AVP frame renders two FOVEATED per-eye views through the
// compositor, none of which this offscreen single-texture dispatch reproduces.
// The GPU clock is also not pinned (DVFS/thermal float absolute ms), so compare
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

/// The distribution plus enough provenance for CI to diff runs and to PROVE the
/// numbers came from AVP silicon (deviceName) rather than a Mac/simulator GPU.
private struct DeviceBenchReport: Codable {
    let deviceName: String
    let width: Int
    let height: Int
    let deKey: String
    let maxSteps: Int
    let result: FrameBenchmark.Result
}

@Suite("Device GPU bench", .serialized)
struct DeviceGPUBenchTests {

    @Test
    func mandelbulbGPUCost() throws {
        // FAIL, don't skip, when there's no Metal device — see file header.
        guard let mtl = MTLCreateSystemDefaultDevice() else {
            Issue.record("""
                No Metal device: the device bench must run on real hardware \
                (physical Apple Vision Pro), inside an app host — not a UI-less \
                test process or the offscreen simulator.
                """)
            return
        }

        let size = envInt("THRESHOLD_BENCH_SIZE", 1024)
        let frames = envInt("THRESHOLD_BENCH_FRAMES", 120)
        let warmup = envInt("THRESHOLD_BENCH_WARMUP", 20)
        let maxSteps = envInt("THRESHOLD_BENCH_MAXSTEPS", 256)

        let context = try GPUContext()
        let renderer = try OffscreenRenderer(context: context)

        // Public-API mandelbulb request — same scene the render smoke test uses
        // (camera (0,0,3) → origin, fov 60°, power-8 bulb = deIndex 1), scaled to
        // `size`. No warp ops: this benchmarks the bare march kernel.
        var engine = EngineParams()
        engine.maxSteps = Float(maxSteps)
        let (params, deParamOffset) = ParamTableLayout.build(engine: engine, deParams: [8.0])
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(0, 0, 3), target: .zero,
            fovYRadians: Float.pi / 3,
            opCount: 0, deIndex: 1,
            paramCount: params.count, deParamOffset: deParamOffset)
        let request = RenderRequest(
            uniforms: uniforms, params: params, ops: [],
            width: size, height: size)

        // Warmup then measured frames through the identical path. readback:false
        // skips the pixel copy so we time GPU work only; gpuMilliseconds comes
        // from commandBuffer.gpuEndTime − gpuStartTime (device-measured).
        let result = try FrameBenchmark.run(warmup: warmup, frames: frames) { _, _ in
            try renderer.render(request, readback: false).stats
        }

        let report = DeviceBenchReport(
            deviceName: mtl.name, width: size, height: size,
            deKey: "mandelbulb", maxSteps: maxSteps, result: result)

        // (1) Human-readable line — lands in the xcodebuild log and .xcresult.
        print("DEVICE-BENCH device=\(mtl.name) \(size)x\(size) maxSteps=\(maxSteps): "
              + result.summaryLine)

        // (2) JSON into the host app's container for `devicectl device copy from`.
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

        // Sanity: the run actually produced GPU work on real hardware.
        #expect(result.measuredFrames == frames)
        #expect(result.medianMs > 0, "GPU frame time must be positive on real hardware")
        #expect(result.totalSteps > 0, "the raymarch must accumulate steps")
    }
}
