// AudioFocusBand.swift — the user's ONE tunable audio band: the "LFO equivalent
// for music." Where an LFO is a procedural signal source you shape, the Focus
// Band is a *listened* source you tune: a low/high-Hz window over the mic
// spectrum published into the `audio.band.user` signal slot, routable to any
// param exactly like Bass/Mid/Treble.
//
// It is DATA, like LFOs and bindings — but its energy is computed in the mic
// DSP (ThresholdInputs, app-shell-owned), NOT in the render session, so unlike
// LFOs it does not flow through a SessionCommand. The app shell keeps the
// analyzer, the mirror, and the saved scene in sync. Scenes persist it so a
// scene stays a self-contained audio-visual preset (SceneEnvelope.focusBand).
//
// Everything here is a Sendable value type; forward-compatible decoding follows
// the LFOSpec/WarpOpDTO convention (missing fields degrade to defaults).

public struct AudioFocusBand: Codable, Sendable, Equatable, Hashable {
    /// Low edge of the band in Hz (clamped to a sane audible range in use).
    public var lowHz: Float
    /// High edge of the band in Hz. Swapped with `lowHz` at compute time if
    /// inverted, so the editor never has to enforce ordering.
    public var highHz: Float
    /// Output multiplier on the extracted level before it is published.
    public var gain: Float
    /// When false the analyzer stops publishing `audio.band.user` (the slot
    /// then reads 0 / goes stale and bound params fall back to rest).
    public var enabled: Bool

    public init(
        lowHz: Float = 60, highHz: Float = 250, gain: Float = 1, enabled: Bool = true
    ) {
        self.lowHz = lowHz
        self.highHz = highHz
        self.gain = gain
        self.enabled = enabled
    }

    /// A bass-focused starting point (60–250 Hz), enabled so the feature is
    /// live the moment the mic turns on.
    public static let `default` = AudioFocusBand()

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowHz = try c.decodeIfPresent(Float.self, forKey: .lowHz) ?? 60
        highHz = try c.decodeIfPresent(Float.self, forKey: .highHz) ?? 250
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
