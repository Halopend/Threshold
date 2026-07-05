import Testing
@testable import ThresholdCore

// The starter (out-of-the-box) assignable bindings are intentionally empty: the
// only default gestures are the hardwired camera controls (translate + grab),
// not param bindings. A fresh install must not seed finger→param bindings (they
// caused params to drift on noisy pinch detection).

@Suite("Starter gesture defaults")
struct GestureDefaultsTests {

    @Test func starterIsEmpty() {
        #expect(GestureBindingSet.starter().isEmpty)
    }

    @Test func starterSeedsNoBindingForAnyBuiltInFractal() {
        let set = GestureBindingSet.starter()
        for deKey in ["mandelbox", "mandelbulb", "mandelbulbJulia", "quaternionJulia",
                      "kleinian", "mengerSponge", "mandelboxSphereProjection"] {
            #expect(set.resolvedTable(forFractal: deKey).isEmpty)
        }
    }
}
