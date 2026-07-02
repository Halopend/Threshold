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

    // MARK: app.*

    public static let appTime = SignalID("app.time")

    /// Everything a default session registers today. Hand/gesture/crown
    /// namespaces join this list in their build phases.
    public static let standardSession: [SignalID] = standardAudio + [.appTime]
}
