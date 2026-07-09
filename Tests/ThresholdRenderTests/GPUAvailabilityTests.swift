// GPUAvailabilityTests.swift — the CI "fail-not-skip" guard.
//
// The 63 GPU-gated render tests use `.enabled(if: GPU.available)`: on a
// machine with no Metal device they record as SKIPPED, not failed, so local
// runs on a device-less box stay green. That is the right default locally, but
// in CI it is a trap — a runner that lost its Metal device (or a misconfigured
// image) would exercise ZERO GPU coverage and still report all-green.
//
// This test closes that hole: when THRESHOLD_REQUIRE_GPU=1 is set (CI sets it
// on the Apple-silicon runner), a would-be skip becomes a hard failure.

import Foundation
import Testing

struct GPUAvailabilityTests {
    @Test func gpuPresentWhenRequired() {
        guard ProcessInfo.processInfo.environment["THRESHOLD_REQUIRE_GPU"] == "1"
        else { return }  // opt-in; locally this test is a no-op.
        #expect(GPU.available, """
                THRESHOLD_REQUIRE_GPU=1 but MTLCreateSystemDefaultDevice() is nil — \
                the GPU-gated render tests would silently skip. Fix the runner \
                (Apple-silicon, Metal available) or unset the flag.
                """)
    }
}
