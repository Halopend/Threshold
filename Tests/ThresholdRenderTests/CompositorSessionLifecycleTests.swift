import Testing
@testable import ThresholdRender

@Suite("Compositor layer lifecycle")
struct CompositorSessionLifecycleTests {
    @Test func immersiveLayerCanReopenAfterInvalidation() {
        var lifecycle = CompositorSessionLifecycle()
        for _ in 0..<3 {
            let started = lifecycle.begin()
            #expect(started)
            let overlappingStart = lifecycle.begin()
            #expect(!overlappingStart, "never overlap render loops")
            lifecycle.end()
        }
    }

    @Test func explicitStopIsTerminalEvenAfterLoopExits() {
        var lifecycle = CompositorSessionLifecycle()
        let started = lifecycle.begin()
        #expect(started)
        let firstStopNeedsJoin = lifecycle.requestStop()
        #expect(firstStopNeedsJoin)
        let secondStopNeedsJoin = lifecycle.requestStop()
        #expect(!secondStopNeedsJoin, "join only once")
        lifecycle.end()
        let restarted = lifecycle.begin()
        #expect(!restarted)
    }

    @Test func stoppingAnIdleSessionDoesNotJoin() {
        var lifecycle = CompositorSessionLifecycle()
        let needsJoin = lifecycle.requestStop()
        #expect(!needsJoin)
        let started = lifecycle.begin()
        #expect(!started)
    }
}
