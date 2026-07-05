// GestureDefaults.swift — the out-of-the-box ASSIGNABLE gesture bindings.
//
// Currently EMPTY on purpose. The only default gestures right now are the two
// hardwired camera controls in HandTracker — right-hand index-pinch drag =
// translate (move in XYZ), and two-hand index-pinch = grab (scale + rotate the
// environment 1:1). Neither is an assignable param binding, so the default
// binding set carries nothing.
//
// An earlier revision seeded per-fractal finger→param bindings here; they were
// removed because noisy middle/ring pinch detection made bound params drift
// even with the fingers at rest ("params jumping around when not pinching").
// Users can still create bindings in the Gestures editor; there just are no
// defaults until a curated, reliably-detected set is designed.

extension GestureBindingSet {
    /// The default binding set for a fresh install: empty (see file header).
    public static func starter() -> GestureBindingSet {
        GestureBindingSet()
    }
}
