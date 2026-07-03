// SignalIDs.swift — the standard signal namespaces (plan §4.1). Declared
// constants per Invariant 14; sources publish these, bindings reference them.
// The SignalTable's capacity is fixed at init, so apps register the standard
// sets up front.

extension SignalID {
    // MARK: audio.* (published by ThresholdInputs.AudioAnalyzer)

    public static let audioRMS = SignalID("audio.rms")
    public static let audioOnset = SignalID("audio.onset")
    public static let audioBandLow = SignalID("audio.band.low")
    public static let audioBandMid = SignalID("audio.band.mid")
    public static let audioBandHigh = SignalID("audio.band.high")
    public static let audioCentroid = SignalID("audio.centroid")

    /// The audio signals every session registers.
    public static let standardAudio: [SignalID] = [
        .audioRMS, .audioOnset, .audioBandLow, .audioBandMid, .audioBandHigh,
        .audioCentroid,
    ]

    // MARK: hand.* (published by ThresholdInputs.HandTracker on visionOS)

    /// Pinch strength 0…1 in `.x` (thumb–index distance, 1 = touching).
    public static let handLeftPinch = SignalID("hand.left.pinch")
    public static let handRightPinch = SignalID("hand.right.pinch")
    /// Wrist position in room space, meters, in `.xyz`.
    public static let handLeftPosition = SignalID("hand.left.position")
    public static let handRightPosition = SignalID("hand.right.position")
    /// Palm center (middle-finger metacarpal joint) in room space, `.xyz` —
    /// the hand-attract op's center (plan §4.3 spatial path).
    public static let handLeftPalm = SignalID("hand.left.palm")
    public static let handRightPalm = SignalID("hand.right.palm")
    /// Forearm point (elbow-ward joint) in room space, `.xyz` — the far end
    /// of the forearm-carve capsule (near end = the wrist position signal).
    public static let handLeftForearm = SignalID("hand.left.forearm")
    public static let handRightForearm = SignalID("hand.right.forearm")

    /// The hand signals every session registers (published only where a hand
    /// tracker runs; registered everywhere so bindings referencing them are
    /// portable across platforms — Invariant 14).
    public static let standardHands: [SignalID] = [
        .handLeftPinch, .handRightPinch, .handLeftPosition, .handRightPosition,
        .handLeftPalm, .handRightPalm, .handLeftForearm, .handRightForearm,
    ]

    // MARK: app.*

    public static let appTime = SignalID("app.time")

    /// Everything a default session registers today. Gesture/crown
    /// namespaces join this list in their build phases.
    public static let standardSession: [SignalID] =
        standardAudio + standardHands + [.appTime]
}
