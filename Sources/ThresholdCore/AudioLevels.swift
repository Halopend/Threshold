// AudioLevels.swift — live audio feature levels surfaced to the UI on the
// RenderSnapshot. The UI must NOT read the SignalTable directly (its `read`
// path mutates a reader-owned cache and is render-thread-confined — ADR-004),
// so the render thread samples the `audio.*` signals once per frame and hands
// them to the mirror through the snapshot; the Music-pane meter displays them.
//
// Pure value type — no engine behavior. Fields mirror the published `audio.*`
// namespace (SignalIDs.swift / AudioDSP.AudioFeatures), plus the user's tunable
// Focus Band. All values are nominally 0…1.

public struct AudioLevels: Sendable, Equatable {
    public var rms: Float
    public var bandLow: Float
    public var bandMid: Float
    public var bandHigh: Float
    public var centroid: Float
    public var onset: Float
    /// The user's tunable Focus Band (`audio.band.user`); 0 when disabled or
    /// while the mic is off.
    public var bandUser: Float

    public init(
        rms: Float = 0, bandLow: Float = 0, bandMid: Float = 0,
        bandHigh: Float = 0, centroid: Float = 0, onset: Float = 0,
        bandUser: Float = 0
    ) {
        self.rms = rms
        self.bandLow = bandLow
        self.bandMid = bandMid
        self.bandHigh = bandHigh
        self.centroid = centroid
        self.onset = onset
        self.bandUser = bandUser
    }

    public static let zero = AudioLevels()
}
