// LFOEngine.swift — the render-thread machine that evaluates the active
// `LFOSpec`s each frame and PUBLISHES each into the `SignalTable` as an `lfo.*`
// signal (LFO.swift doc). It writes NO lanes itself: an LFO reaches a parameter
// only through an ordinary `Binding` the `BindingEngine` executes, so LFO
// modulation reuses the entire signal→binding spine (mapping curve, range,
// deadzone, scale, per-component addressing, staleness) with zero new engine
// behavior. This is the "like the music ones but without music" mechanism.
//
// Concurrency (ADR-004, same confinement pattern as BindingEngine /
// AnimationPlayer): final class, deliberately NOT Sendable, render-thread
// confined. Spec edits arrive from the UI through the session command mailbox
// (SessionCommand.setLFOs) between frames.
//
// Determinism (Invariant 9): the engine evaluates off the caller's `now`
// (AppClock content time), never wall time — golden captures reproduce.

/// One LFO in a bank could not be executed (duplicate slot). Surfaced for
/// telemetry like AnimationPlayer/BindingEngine's `lastSkippedCount`.
public final class LFOEngine {
    /// The active LFO bank. Assignment rebuilds the evaluation cache (seed
    /// derivation and duplicate-slot resolution happen once here, not per frame).
    public var lfos: [LFOSpec] {
        didSet { rebuildCache() }
    }

    /// How many specs in the current bank were dropped as duplicates of an
    /// earlier spec's slot (last-writer-wins would make them invisible; we drop
    /// them at cache build so the count is honest). Disabled specs are NOT
    /// skips — they are simply not published, and their slot goes stale.
    public private(set) var lastSkippedCount = 0

    /// One executable spec with its noise seed pre-derived from the slot.
    private struct CachedLFO {
        let spec: LFOSpec
        let seed: UInt64
    }

    private var cache: [CachedLFO] = []

    public init(lfos: [LFOSpec] = []) {
        self.lfos = lfos
        rebuildCache()  // didSet does not fire during init
    }

    private func rebuildCache() {
        cache.removeAll(keepingCapacity: true)
        var claimed = Set<SignalID>()
        var skips = 0
        for spec in lfos {
            guard spec.enabled else { continue }
            // One publisher per slot: a later spec on a claimed slot would just
            // overwrite the earlier one's value each frame. Drop it and count it.
            guard claimed.insert(spec.slot).inserted else {
                skips += 1
                continue
            }
            cache.append(CachedLFO(spec: spec, seed: Self.seed(for: spec.slot)))
        }
        lastSkippedCount = skips
    }

    /// Evaluate every enabled spec at `now` and publish it into `signals`. Call
    /// on the render thread once per frame, BEFORE `bindingEngine.apply`, so the
    /// LFO value is in the table before the binding reads it THIS frame (no
    /// one-frame lag). `now` is `AppClock.now` (content time — frozen while
    /// paused, so LFOs freeze with everything else).
    ///
    /// Published with confidence 1 and timestamp `now`: a continuously-fresh
    /// source, so a `momentary` LFO binding never stale-clears (an LFO is always
    /// "playing"). A disabled/removed spec simply stops publishing; its slot
    /// then ages past `BindingEngine.staleAfter` and bound params release.
    public func publish(into signals: SignalTable, now: Double) {
        for cached in cache {
            let v = cached.spec.value(at: now, seed: cached.seed)
            signals.publish(
                id: cached.spec.slot,
                value: SIMD4(v, 0, 0, 0),
                confidence: 1,
                timestamp: now)
        }
    }

    /// Stable 64-bit seed from a slot's identity (FNV-1a over UTF-8). Keeps
    /// `noise` components on different slots decorrelated without any per-run
    /// randomness.
    private static func seed(for slot: SignalID) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for byte in slot.rawValue.utf8 {
            h = (h ^ UInt64(byte)) &* 0x100000001B3
        }
        return h
    }
}
