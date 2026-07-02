// BindingEngine.swift — executes the signal→lane bindings each frame
// (plan §4.2, §3.2; ARCHITECTURE.md §2). Bindings are DATA (Binding.swift);
// this is the render-thread machine that reads signals and turns them into
// lane writes.
//
// Concurrency (ADR-004, same confinement pattern as `ModulationEngine`):
// `BindingEngine` is a final class and deliberately NOT Sendable. It is
// confined to the render thread: `apply` reads the `SignalTable` (whose
// read path is single-reader, render-thread-only by contract) and writes
// the `ModulationEngine`'s lanes directly. Binding EDITS arrive from the UI
// through the session command mailbox (`SessionCommand.setBindings`), which
// assigns `bindings` on the render thread between frames — never mid-apply.

public final class BindingEngine {
    public let layout: CatalogLayout

    /// A signal sample is FRESH when `now - timestamp <= staleAfter` AND its
    /// confidence is > 0; otherwise it is stale. Settable (e.g. hand tracking
    /// may want a tighter window than audio).
    ///
    /// Interaction with music decay: a stale `momentary` binding clears its
    /// lane slot explicitly. For the music lane this fires after the value
    /// has already decayed for `staleAfter` seconds (≈ 3 time constants at
    /// the default music tau of 0.08 s), so the residual jump is negligible —
    /// but setting `staleAfter` below the music tau will visibly truncate
    /// the decay tail.
    public var staleAfter: Double = 0.25

    /// How many bindings in the current set could NOT be executed by the last
    /// `apply` (unbindable lane, unknown param key, or component out of
    /// range). Skips are structural — determined when `bindings` is set — so
    /// this is also refreshed on assignment, before the first `apply`.
    public private(set) var lastSkippedCount: Int = 0

    /// The active binding set. Assignment rebuilds the slot-resolution cache
    /// (param-key lookups happen once here, not per frame) and resets the
    /// per-binding stale-clear bookkeeping.
    public var bindings: [Binding] {
        didSet { rebuildCache() }
    }

    /// One executable binding with its param key pre-resolved to a slot.
    private struct CachedBinding {
        let signal: SignalID
        let lane: Lane
        let slot: Int
        let mapping: SignalMapping
        let policy: BindingPolicy
        let scale: Float
        /// True once the momentary stale-clear has fired; reset when the
        /// signal is fresh again. Guarantees the clear happens ONCE per
        /// stale episode, so it cannot stomp later writes to the same slot
        /// (another binding, HandOpWriter, tests poking the lane, …).
        var clearedWhileStale: Bool
    }

    private var cache: [CachedBinding] = []
    private var structuralSkips: Int = 0

    public init(layout: CatalogLayout) {
        self.layout = layout
        self.bindings = []
        rebuildCache()  // didSet does not fire during init
    }

    private func rebuildCache() {
        cache.removeAll(keepingCapacity: true)
        var skips = 0
        for binding in bindings {
            // Only the transient lanes are writable via bindings (plan §4.2):
            // scene/animation/system/user in a Binding are data errors.
            guard binding.lane == .gesture || binding.lane == .music else {
                skips += 1
                continue
            }
            // Unknown param key (stale scene file, removed param): skip, never crash.
            guard let entry = layout.entry(for: binding.param) else {
                skips += 1
                continue
            }
            // Vector component addressing: component must fit the param kind.
            guard binding.component >= 0, binding.component < entry.kind.slotWidth else {
                skips += 1
                continue
            }
            cache.append(CachedBinding(
                signal: binding.signal,
                lane: binding.lane,
                slot: entry.slot + binding.component,
                mapping: binding.mapping,
                policy: binding.policy,
                scale: binding.scale,
                clearedWhileStale: false))
        }
        structuralSkips = skips
        lastSkippedCount = skips
    }

    /// Execute every binding against the current signal table state. Render
    /// thread only; call once per frame BEFORE `engine.resolve()` so this
    /// frame's writes participate in this frame's composition.
    ///
    /// - `signals`: read with the table's single-reader path.
    /// - `engine`: must share this engine's `layout` (same slot numbering —
    ///   both are built from the same frozen catalog).
    /// - `now`: SESSION clock time (`AppClock.now`), never wall time
    ///   (Invariant 9). Staleness compares `now` against each signal's
    ///   published timestamp, so sources must publish timestamps in the same
    ///   timebase (see `AudioAnalyzer.timebaseOffset` for the sample-clock →
    ///   session-clock bridge).
    ///
    /// Per binding:
    /// - FRESH signal (see `staleAfter`): writes
    ///   `mapping.apply(value.x) * scale` to `(lane, slot)`. Non-finite
    ///   mapped values are never written (`SignalMapping.apply` already
    ///   guards non-finite RAW input; this additionally guards a non-finite
    ///   scale or output range — and the engine's ingress guard would drop
    ///   it anyway, defense in depth).
    /// - STALE signal, `.momentary`: `engine.clearLane(lane, slot:)`, once
    ///   per stale episode (music would decay to neutral on its own —
    ///   plan §3.2 — but a gesture-lane momentary binding holds forever
    ///   without this explicit clear).
    /// - STALE signal, `.latched`: leaves the last written value. (On the
    ///   music lane the engine's always-on decay still applies — a music
    ///   value only "holds" while it keeps being re-written.)
    /// - Signals not registered in `signals` behave like never-published
    ///   ones (confidence 0): permanently stale.
    public func apply(signals: SignalTable, engine: ModulationEngine, now: Double) {
        lastSkippedCount = structuralSkips
        for i in cache.indices {
            let b = cache[i]
            let sample = signals.read(id: b.signal)
            let isFresh: Bool
            if let sample {
                isFresh = sample.confidence > 0 && now - sample.timestamp <= staleAfter
            } else {
                isFresh = false
            }

            if isFresh, let sample {
                let mapped = b.mapping.apply(sample.value.x) * b.scale
                guard mapped.isFinite else { continue }
                engine.write(lane: b.lane, slot: b.slot, value: mapped)
                cache[i].clearedWhileStale = false
            } else {
                switch b.policy {
                case .momentary:
                    if !cache[i].clearedWhileStale {
                        engine.clearLane(b.lane, slot: b.slot)
                        cache[i].clearedWhileStale = true
                    }
                case .latched:
                    break  // hold the last written value
                }
            }
        }
    }
}
