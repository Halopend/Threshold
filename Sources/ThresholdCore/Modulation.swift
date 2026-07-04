// Modulation.swift — the modulation engine: lanes, smoothing, decay,
// composition, integrators, and THE single clamp site (plan §3,
// ARCHITECTURE.md §2–3, ADR-003, ADR-004).
//
// Concurrency (ADR-004): `ModulationEngine` is a final class and deliberately
// NOT Sendable. It is confined to the render thread; the compiler enforces
// that nothing else can touch live lane storage. The only cross-thread
// ingress is the engine's `LaneMailbox` (Sendable), drained at resolve start.
// The only egress is `ResolvedParams` (immutable, Sendable).

import Foundation
import Synchronization

// MARK: - Bitset

/// Minimal dense bitset over slot indices (per-lane "has explicit value"
/// tracking — needed for replace composition and neutral handling).
struct Bitset {
    private(set) var words: [UInt64]

    init(bitCount: Int) {
        words = [UInt64](repeating: 0, count: (bitCount + 63) / 64)
    }

    func contains(_ i: Int) -> Bool {
        (words[i >> 6] >> UInt64(i & 63)) & 1 == 1
    }

    mutating func insert(_ i: Int) {
        words[i >> 6] |= 1 << UInt64(i & 63)
    }

    mutating func remove(_ i: Int) {
        words[i >> 6] &= ~(1 << UInt64(i & 63))
    }

    mutating func removeAll() {
        for i in words.indices { words[i] = 0 }
    }

    var isEmpty: Bool { words.allSatisfy { $0 == 0 } }

    /// Visit set bit indices in ascending order.
    func forEachSetBit(_ body: (Int) -> Void) {
        for (wi, w) in words.enumerated() {
            var word = w
            while word != 0 {
                body(wi << 6 | word.trailingZeroBitCount)
                word &= word &- 1
            }
        }
    }
}

// MARK: - LaneWrite / LaneMailbox

/// One lane write: latest-value-wins per (lane, slot).
public struct LaneWrite: Sendable, Hashable {
    public let lane: Lane
    public let slot: Int
    public let value: Float

    public init(lane: Lane, slot: Int, value: Float) {
        self.lane = lane
        self.slot = slot
        self.value = value
    }
}

/// Thread-safe MPSC mailbox for lane writes. Publish from any thread;
/// `drainInto(_:)` is called by the engine on the render thread at resolve
/// start (Invariant 13: signal table + mailboxes are the ONLY channels into
/// the render thread).
///
/// Implementation: `Mutex`-protected preallocated ring (default capacity
/// 4096). If the ring fills, it GROWS UNDER THE LOCK — this allocation on the
/// publish path is documented as PROVISIONAL versus ADR-004 action item 2
/// (allocation-free publish); `didGrowBeyondInitialCapacity` exposes the
/// condition so telemetry/tests can flag an undersized ring. Compiler-checked
/// Sendable: the only stored property is a `Mutex` over Sendable state — no
/// `@unchecked` needed.
public final class LaneMailbox: Sendable {
    private struct State: Sendable {
        var buffer: [LaneWrite]
        var head: Int = 0
        var count: Int = 0
        var didGrow: Bool = false
    }

    private let state: Mutex<State>

    public init(capacity: Int = 4096) {
        precondition(capacity > 0)
        let placeholder = LaneWrite(lane: .scene, slot: 0, value: 0)
        state = Mutex(State(buffer: [LaneWrite](repeating: placeholder, count: capacity)))
    }

    /// Callable from any thread. FIFO; allocation-free unless the ring must
    /// grow (see class doc).
    public func publish(_ write: LaneWrite) {
        state.withLock { s in
            if s.count == s.buffer.count {
                // Grow: double capacity, un-wrap into a fresh buffer.
                var grown = [LaneWrite]()
                grown.reserveCapacity(s.buffer.count * 2)
                for i in 0..<s.count {
                    grown.append(s.buffer[(s.head + i) % s.buffer.count])
                }
                grown.append(contentsOf: [LaneWrite](
                    repeating: LaneWrite(lane: .scene, slot: 0, value: 0),
                    count: s.buffer.count * 2 - s.count))
                s.buffer = grown
                s.head = 0
                s.didGrow = true
            }
            s.buffer[(s.head + s.count) % s.buffer.count] = write
            s.count += 1
        }
    }

    /// Apply all pending writes to `engine` in publish order and empty the
    /// ring. Render thread only (the engine is not Sendable; whoever owns the
    /// engine owns this call). Allocation-free.
    public func drainInto(_ engine: ModulationEngine) {
        state.withLock { s in
            for i in 0..<s.count {
                let w = s.buffer[(s.head + i) % s.buffer.count]
                engine.write(lane: w.lane, slot: w.slot, value: w.value)
            }
            s.head = 0
            s.count = 0
        }
    }

    /// True if the ring ever exceeded its initial capacity (ADR-004 action
    /// item 2 observability).
    public var didGrowBeyondInitialCapacity: Bool {
        state.withLock { $0.didGrow }
    }
}

// MARK: - SceneTransition

/// How a scene apply reaches the screen (ADR-005). `nil` at the call sites
/// means SNAP — the harness/tests/startup default, byte-identical to the
/// pre-transition behavior. A duration means the legacy "Same Scene
/// Transition Time" tween: continuous params ease from their current smoothed
/// values toward the new scene over `duration` seconds, then land exactly.
public struct SceneTransition: Sendable, Equatable, Hashable {
    /// Seconds from apply to landing. Non-positive durations mean snap.
    public var duration: Double

    public init(duration: Double) {
        self.duration = duration
    }

    /// The legacy default scene-transition time (0.5 s).
    public static let `default` = SceneTransition(duration: 0.5)
}

// MARK: - ResolvedParams

/// The immutable per-frame output of `resolve()`. `values` is the dense float
/// table uploaded VERBATIM to the GPU — slot order is the GPU layout (plan
/// §5.4). Downstream consumers (encoder, UI mirror, harness) read this and
/// never live lanes.
public struct ResolvedParams: Sendable {
    public let values: [Float]
    /// Monotonic resolve counter (1 for the first resolve).
    public let generation: UInt64
}

// MARK: - ModulationEngine

/// The modulation heart: per-lane dense storage, smoothing, music decay,
/// lane composition, integrator phases, and the single clamp site.
///
/// NOT Sendable — render-thread confined per ADR-004. Cross-thread writers
/// publish into `mailbox`; `resolve()` drains it first.
public final class ModulationEngine {
    public let layout: CatalogLayout
    /// Cross-thread ingress for lane writes. Hand this (it is Sendable) to
    /// input sources / the UI at setup time.
    public let mailbox: LaneMailbox

    private let clock: any AppClock

    // Per-slot spec tables, dense (index == slot). `registered[slot] == false`
    // for the 6..15 engine gap and unclaimed dynamic-arena slots; unregistered
    // slots resolve to 0 and are skipped everywhere else. Static entries fill
    // these at init and never change; arena slots are filled/cleared at
    // runtime by `registerDynamic`/`unregisterDynamic` (render thread — the
    // engine is thread-confined, so no synchronization is needed).
    private var registered: [Bool]
    private var compositionBySlot: [Composition]
    private var rangeLo: [Float]
    private var rangeHi: [Float]
    private var defaults: [Float]
    /// `tauByLane[lane.rawValue][slot]`, seconds; 0 = instant.
    private var tauByLane: [[Double]]
    /// Scene transitions may tween this slot (ADR-005): float-kind AND not
    /// flagged `.snapOnSceneTransition`. Bool/enum kinds are always false —
    /// and additionally have every lane tau forced to 0 at registration
    /// (a lerped enum index is a garbage frame, no matter the lane).
    private var tweenable: [Bool]

    // Per-lane state: written targets, smoothed currents, explicit-value bits.
    private var target: [[Float]]
    private var current: [[Float]]
    private var hasValue: [Bitset]
    /// Music-lane slots written since the last resolve; anything set-but-not-
    /// written decays toward neutral (plan §3.2: music is ALWAYS transient).
    private var musicWritten: Bitset
    /// Per-lane slots in graceful release (ADR-005): the lane value decays
    /// toward its composition neutral at the lane's tau and the slot is
    /// CLEARED on arrival — the smooth counterpart of `clearLane`. Used by
    /// slider release (user) and momentary binding release (gesture). A fresh
    /// write to a releasing slot cancels the release (re-grab). Music has its
    /// own always-on decay and never enters this set.
    private var releasing: [Bitset]

    // Scene transition state (ADR-005). While `sceneTransitionRemaining > 0`,
    // tweenable slots smooth scene-lane writes with `sceneTransitionTau`
    // instead of their spec tau; when the window closes they land EXACTLY
    // (current = target) and deferred clears release.
    private var sceneTransitionRemaining: Double = 0
    private var sceneTransitionTau: Double = 0
    /// Slots owed a scene-lane clear when the transition lands (authoritative
    /// apply of a scene that lacks the param: ramp to default, then release).
    private var pendingSceneClears: Bitset

    // Integrator state (Invariant 17: every stateful resolved value is a
    // declared integrator entry; the engine owns NO other state).
    private struct Integrator {
        let phaseSlot: Int
        let rateSlot: Int
        let lo: Float
        let hi: Float
        var phase: Float
    }
    private var integrators: [Integrator]
    private var integratorIndexByPhaseSlot: [Int: Int]

    private var generation: UInt64 = 0

    /// `mailbox` is injectable so a session can hand the (Sendable) mailbox to
    /// clients BEFORE the engine exists on the render thread (the engine is
    /// created on the render thread; its ingress must not wait for it). The
    /// default preserves the original always-fresh behavior for existing call
    /// sites.
    public init(layout: CatalogLayout, clock: any AppClock, mailbox: LaneMailbox = LaneMailbox()) {
        self.layout = layout
        self.clock = clock
        self.mailbox = mailbox

        let n = layout.slotCount
        var registered = [Bool](repeating: false, count: n)
        var composition = [Composition](repeating: .additive, count: n)
        var lo = [Float](repeating: 0, count: n)
        var hi = [Float](repeating: 0, count: n)
        var defaults = [Float](repeating: 0, count: n)
        var taus = [[Double]](repeating: [Double](repeating: 0, count: n), count: Lane.allCases.count)
        var tweenable = [Bool](repeating: false, count: n)
        var integrators: [Integrator] = []
        var integratorIndex: [Int: Int] = [:]

        for entry in layout.entries {
            let smoothableKind = Self.isSmoothableKind(entry.spec.kind)
            for (component, slot) in entry.slotRange.enumerated() {
                precondition(slot < n, "entry \(entry.key) slot \(slot) out of layout bounds")
                precondition(!registered[slot], "slot \(slot) doubly assigned (catalog bug)")
                registered[slot] = true
                composition[slot] = entry.spec.composition
                lo[slot] = entry.spec.range.lowerBound
                hi[slot] = entry.spec.range.upperBound
                defaults[slot] = entry.spec.defaultValue[component]
                for lane in Lane.allCases {
                    // Bool/enum kinds are forced instant on EVERY lane — a
                    // fractional enum index is a garbage frame (ADR-005).
                    taus[lane.rawValue][slot] =
                        smoothableKind ? entry.spec.smoothing.tau(for: lane) : 0
                }
                tweenable[slot] = smoothableKind
                    && !entry.spec.capabilities.contains(.snapOnSceneTransition)
            }
            if let rateKey = entry.spec.integratorRateKey {
                guard let rateSlot = layout.slot(for: rateKey) else {
                    preconditionFailure(
                        "integrator phase \(entry.key) references unregistered rate key \(rateKey)")
                }
                integratorIndex[entry.slot] = integrators.count
                integrators.append(Integrator(
                    phaseSlot: entry.slot,
                    rateSlot: rateSlot,
                    lo: entry.spec.range.lowerBound,
                    hi: entry.spec.range.upperBound,
                    phase: entry.spec.defaultValue[0]))
            }
        }

        self.registered = registered
        self.compositionBySlot = composition
        self.rangeLo = lo
        self.rangeHi = hi
        self.defaults = defaults
        self.tauByLane = taus
        self.tweenable = tweenable
        self.integrators = integrators
        self.integratorIndexByPhaseSlot = integratorIndex

        let laneCount = Lane.allCases.count
        self.target = [[Float]](repeating: [Float](repeating: 0, count: n), count: laneCount)
        self.current = [[Float]](repeating: [Float](repeating: 0, count: n), count: laneCount)
        self.hasValue = [Bitset](repeating: Bitset(bitCount: n), count: laneCount)
        self.musicWritten = Bitset(bitCount: n)
        self.releasing = [Bitset](repeating: Bitset(bitCount: n), count: laneCount)
        self.pendingSceneClears = Bitset(bitCount: n)
    }

    /// Kinds whose values interpolate meaningfully (ADR-005): floats and
    /// float vectors. Bools and enum indices do not.
    private static func isSmoothableKind(_ kind: ParamKind) -> Bool {
        switch kind {
        case .float, .float3, .float4: return true
        case .bool, .enumeration: return false
        }
    }

    // MARK: Writes

    /// Direct render-thread write (animation evaluator, HandOpWriter, …).
    /// Cross-thread callers use `mailbox.publish` instead.
    ///
    /// Values are stored UNCLAMPED — writes outside the param's range are not
    /// rejected; clamping happens exactly once, at resolution.
    ///
    /// Non-finite values are DROPPED at ingress: NaN passes `min(max(v,lo),hi)`
    /// untouched (Swift's Comparable min/max return the first argument when a
    /// NaN comparison is false), and once in lane state it self-sustains —
    /// smoothing arithmetic keeps producing NaN and music decay never
    /// converges. One 0/0 from an input source must not poison the GPU table.
    public func write(lane: Lane, slot: Int, value: Float) {
        precondition(slot >= 0 && slot < layout.slotCount, "slot \(slot) out of bounds")
        guard value.isFinite else { return }
        let li = lane.rawValue
        if !hasValue[li].contains(slot) {
            hasValue[li].insert(slot)
            // First write: seed the smoothed value so tau > 0 lanes ramp IN
            // from a sensible origin — the composition neutral (scene ramps
            // from the param default; replace jumps, it has no neutral).
            current[li][slot] = seedValue(lane: lane, slot: slot, written: value)
        }
        target[li][slot] = value
        // A fresh write re-grabs a releasing slot (ADR-005) and, on the scene
        // lane, supersedes any clear a transition still owes this slot.
        releasing[li].remove(slot)
        if lane == .scene { pendingSceneClears.remove(slot) }
        if lane == .music { musicWritten.insert(slot) }
    }

    /// `write` that bypasses smoothing: the smoothed current jumps WITH the
    /// target. For writes that must not animate — non-transition scene applies
    /// (the harness/startup path) and commit-on-release rebasing, where the
    /// resolved value is already at the written position (ADR-005).
    ///
    /// On a FIRST write to a slot, `write` first seeds current to the lane's
    /// composition neutral (default for scene) before this overwrites it to
    /// `value`; the net effect is still current == target == value, so the
    /// first post-write resolve reads `value` with no ramp. For the scene lane
    /// specifically the distinction is moot — scene tau is 0 everywhere, so a
    /// plain `write` already lands current == target at the next resolve; the
    /// explicit jump here keeps the "no animation" contract independent of that.
    public func snapWrite(lane: Lane, slot: Int, value: Float) {
        write(lane: lane, slot: slot, value: value)
        guard value.isFinite else { return }
        current[lane.rawValue][slot] = value
    }

    /// Smooth counterpart of `clearLane(_:slot:)` (ADR-005): the lane value
    /// decays toward its composition neutral at the lane's tau, and the slot
    /// clears on arrival. Replace-composition and instant (tau 0) slots clear
    /// immediately — there is nothing to glide through. Music is excluded
    /// (its always-on decay IS this mechanism).
    public func releaseLane(_ lane: Lane, slot: Int) {
        precondition(slot >= 0 && slot < layout.slotCount)
        precondition(lane != .music, "music decays on its own (plan §3.2)")
        let li = lane.rawValue
        guard hasValue[li].contains(slot) else { return }
        guard registered[slot], tauByLane[li][slot] > 0,
              compositionBySlot[slot] != .replace,
              current[li][slot].isFinite
        else {
            clearLane(lane, slot: slot)
            return
        }
        releasing[li].insert(slot)
    }

    /// Convenience: write all components of a param by key. Returns false if
    /// the key is unregistered or the component count mismatches.
    /// `snap: true` routes through `snapWrite` (no smoothing).
    @discardableResult
    public func write(lane: Lane, key: ParamKey, values: [Float], snap: Bool = false) -> Bool {
        guard let entry = layout.entry(for: key), values.count == entry.kind.slotWidth else {
            return false
        }
        for (i, v) in values.enumerated() {
            if snap {
                snapWrite(lane: lane, slot: entry.slot + i, value: v)
            } else {
                write(lane: lane, slot: entry.slot + i, value: v)
            }
        }
        return true
    }

    private func seedValue(lane: Lane, slot: Int, written: Float) -> Float {
        guard registered[slot] else { return written }
        if lane == .scene { return defaults[slot] }
        switch compositionBySlot[slot] {
        case .additive: return 0
        case .multiplicative: return 1
        case .replace: return written
        }
    }

    /// Scene apply writes ONLY the scene lane (Invariant 11) and clears
    /// nothing else — user/gesture/music offsets survive a scene apply.
    /// Unknown keys and mismatched component counts are ignored
    /// (forward-compatibility: scene files may carry newer params).
    public func applyScene(values: [ParamKey: [Float]]) {
        for (key, components) in values {
            write(lane: .scene, key: key, values: components)
        }
    }

    // MARK: Scene transitions (ADR-005)

    /// True while a scene-transition window is open.
    public var sceneTransitionActive: Bool { sceneTransitionRemaining > 0 }

    /// Open a scene-transition window: for the next `duration` seconds of
    /// CONTENT time (AppClock — pausing freezes the window), scene-lane
    /// smoothing on tweenable slots uses τ = duration/4 (≈ 98% of the way by
    /// the deadline) instead of the spec tau; when the window closes those
    /// slots land EXACTLY on their targets and deferred clears release.
    /// Call BEFORE the apply's scene-lane writes. Non-positive/non-finite
    /// durations are ignored (the apply snaps, as without a transition).
    /// A second transition beginning mid-flight simply re-aims: exponential
    /// smoothing is memoryless, values glide from wherever they are.
    public func beginSceneTransition(duration: Double) {
        guard duration > 0, duration.isFinite else { return }
        sceneTransitionRemaining = duration
        sceneTransitionTau = duration / 4
    }

    /// Authoritative-apply clear for a param the incoming scene does not
    /// carry. Inside a transition window, tweenable slots RAMP to the catalog
    /// default and release when the window closes (a snap-to-default next to
    /// tweening neighbors reads as a glitch); otherwise — and for
    /// non-tweenable slots — this is an immediate `clearLane`.
    public func scheduleSceneClear(slot: Int) {
        precondition(slot >= 0 && slot < layout.slotCount)
        guard sceneTransitionActive, registered[slot], tweenable[slot],
              hasValue[Lane.scene.rawValue].contains(slot)
        else {
            clearLane(.scene, slot: slot)
            return
        }
        write(lane: .scene, slot: slot, value: defaults[slot])
        pendingSceneClears.insert(slot)
    }

    /// Clear every explicit value in a lane (binding policy: e.g. a
    /// `momentary` gesture binding clears on release; `latched` holds).
    public func clearLane(_ lane: Lane) {
        hasValue[lane.rawValue].removeAll()
        releasing[lane.rawValue].removeAll()
        if lane == .music { musicWritten.removeAll() }
        if lane == .scene { pendingSceneClears.removeAll() }
    }

    /// Clear one slot in a lane.
    public func clearLane(_ lane: Lane, slot: Int) {
        precondition(slot >= 0 && slot < layout.slotCount)
        hasValue[lane.rawValue].remove(slot)
        releasing[lane.rawValue].remove(slot)
        if lane == .music { musicWritten.remove(slot) }
        if lane == .scene { pendingSceneClears.remove(slot) }
    }

    // MARK: Dynamic arena registration

    /// Register a spec into the dynamic arena at runtime (external DE params,
    /// warp-slot fields — Catalog.freeze doc). The GPU-facing slot count never
    /// changes; only the spec tables for already-reserved arena slots fill in.
    /// Render thread only (the engine is thread-confined).
    ///
    /// Dynamic params cannot be integrators — integrator state is wired at
    /// init (Invariant 17's "declared" is load-bearing).
    public func registerDynamic(_ spec: ParamSpec, atSlot slot: Int) {
        precondition(spec.integratorRateKey == nil,
                     "dynamic param \(spec.key) cannot declare an integrator")
        let smoothableKind = Self.isSmoothableKind(spec.kind)
        for (component, s) in (slot..<(slot + spec.kind.slotWidth)).enumerated() {
            precondition(layout.arenaRange.contains(s),
                         "dynamic slot \(s) outside arena \(layout.arenaRange)")
            precondition(!registered[s], "arena slot \(s) already registered")
            registered[s] = true
            compositionBySlot[s] = spec.composition
            rangeLo[s] = spec.range.lowerBound
            rangeHi[s] = spec.range.upperBound
            defaults[s] = spec.defaultValue[component]
            for lane in Lane.allCases {
                tauByLane[lane.rawValue][s] =
                    smoothableKind ? spec.smoothing.tau(for: lane) : 0
            }
            tweenable[s] = smoothableKind
                && !spec.capabilities.contains(.snapOnSceneTransition)
        }
    }

    /// Recycle arena slots: unregister and clear EVERY lane's state there, so
    /// the next registration starts clean (a recycled slot must never leak the
    /// previous occupant's lane values). No-op components outside the arena
    /// trap — static slots are never recyclable.
    public func unregisterDynamic(slots: Range<Int>) {
        for s in slots {
            precondition(layout.arenaRange.contains(s),
                         "cannot unregister non-arena slot \(s)")
            registered[s] = false
            tweenable[s] = false
            for lane in Lane.allCases {
                hasValue[lane.rawValue].remove(s)
                releasing[lane.rawValue].remove(s)
            }
            musicWritten.remove(s)
            pendingSceneClears.remove(s)
        }
    }

    // MARK: Introspection

    /// The lane's current SMOOTHED value, or nil if the lane has no explicit
    /// value at this slot. (UI "why is this value X" story, tests, inversion.)
    public func currentValue(lane: Lane, slot: Int) -> Float? {
        precondition(slot >= 0 && slot < layout.slotCount)
        let li = lane.rawValue
        return hasValue[li].contains(slot) ? current[li][slot] : nil
    }

    /// What `resolve()` would produce for one slot RIGHT NOW from the current
    /// smoothed lane state: compose in lane order, clamp. Integrator phase
    /// slots are NOT overridden here (this is the lane view, used by
    /// commit-on-release continuity — phases are not user-editable anyway).
    public func resolvedValue(slot: Int) -> Float {
        precondition(slot >= 0 && slot < layout.slotCount)
        guard registered[slot] else { return 0 }
        var acc = baseValue(slot: slot)
        let comp = compositionBySlot[slot]
        for li in (Lane.scene.rawValue + 1)...Lane.music.rawValue
        where hasValue[li].contains(slot) {
            switch comp {
            case .additive: acc += current[li][slot]
            case .multiplicative: acc *= current[li][slot]
            case .replace: acc = current[li][slot]
            }
        }
        return acc.isFinite
            ? min(max(acc, rangeLo[slot]), rangeHi[slot])
            : defaults[slot]
    }

    // MARK: Integrator phase access (scene snapshotting)

    /// Current integrator phase for a phase param's slot, nil if the slot is
    /// not an integrator phase.
    public func readIntegratorPhase(slot: Int) -> Float? {
        integratorIndexByPhaseSlot[slot].map { integrators[$0].phase }
    }

    /// Overwrite an integrator phase (scene snapshot restore). The value is
    /// wrapped into the phase param's range. No-op for non-integrator slots.
    public func setIntegratorPhase(slot: Int, value: Float) {
        guard let i = integratorIndexByPhaseSlot[slot] else { return }
        integrators[i].phase = Self.wrap(value, lo: integrators[i].lo, hi: integrators[i].hi)
    }

    // MARK: Resolve

    /// One frame: drain mailbox → smooth → decay music → compose lanes in
    /// Lane order → integrator post-pass → clamp (THE single clamp site).
    ///
    /// Pausing: when `clock.paused` or `delta == 0`, smoothing, music decay,
    /// and integrators do NOT advance. Lanes with tau == 0 ("instant") still
    /// jump to freshly written targets — pausing time must not disable the
    /// user's sliders.
    public func resolve() -> ResolvedParams {
        mailbox.drainInto(self)

        let dt = clock.paused ? 0 : max(0, clock.delta)
        let musicLane = Lane.music.rawValue

        // 1. Smoothing: move each explicit lane value toward its target by
        //    alpha = 1 - exp(-dt/tau); tau == 0 jumps. Music slots NOT written
        //    this frame are skipped here — the decay pass owns them; releasing
        //    slots are skipped too — the release pass owns them (ADR-005).
        //    An open scene-transition window REPLACES the scene tau on
        //    tweenable slots with the transition tau (D/4): every tweened
        //    param moves in lockstep at the transition rate — coordinated —
        //    and reaches ~98% by the deadline so pass 1c's exact landing is a
        //    negligible snap, not a visible pop. It overrides the spec tau in
        //    BOTH directions on purpose: the transition duration governs, not
        //    each param's live-edit feel.
        let sceneLaneIndex = Lane.scene.rawValue
        let inTransition = sceneTransitionRemaining > 0
        let transitionTau = sceneTransitionTau
        for lane in Lane.allCases {
            let li = lane.rawValue
            hasValue[li].forEachSetBit { slot in
                if li == musicLane && !musicWritten.contains(slot) { return }
                if releasing[li].contains(slot) { return }
                var tau = tauByLane[li][slot]
                if inTransition && li == sceneLaneIndex && tweenable[slot] {
                    tau = transitionTau
                }
                if tau <= 0 {
                    current[li][slot] = target[li][slot]
                } else if dt > 0 {
                    let alpha = Float(1 - exp(-dt / tau))
                    current[li][slot] += (target[li][slot] - current[li][slot]) * alpha
                }
            }
        }

        // 1b. Release pass (ADR-005): releasing slots decay toward their
        //     composition neutral at the lane tau and CLEAR on arrival — the
        //     smooth `clearLane`. Same shape as music decay below; music
        //     itself never enters `releasing`.
        if dt > 0 {
            for lane in Lane.allCases where lane != .music {
                let li = lane.rawValue
                var landed: [Int] = []
                releasing[li].forEachSetBit { slot in
                    let neutral: Float
                    switch compositionBySlot[slot] {
                    case .additive: neutral = 0
                    case .multiplicative: neutral = 1
                    case .replace:
                        landed.append(slot)
                        return
                    }
                    let tau = tauByLane[li][slot]
                    guard tau > 0, current[li][slot].isFinite else {
                        landed.append(slot)
                        return
                    }
                    let alpha = Float(1 - exp(-dt / tau))
                    current[li][slot] += (neutral - current[li][slot]) * alpha
                    if abs(current[li][slot] - neutral) < 1e-6 {
                        landed.append(slot)
                    }
                }
                for slot in landed { clearLane(lane, slot: slot) }
            }
        }

        // 1c. Scene-transition close (ADR-005): the window is CONTENT time,
        //     frozen with the clock. On close, tweenable scene slots land
        //     exactly (τ = D/4 leaves ≈ 2%) and deferred clears release —
        //     their currents already sit on the defaults they ramped to, so
        //     the handoff to defaults-as-base is seamless.
        if sceneTransitionRemaining > 0 && dt > 0 {
            sceneTransitionRemaining -= dt
            if sceneTransitionRemaining <= 0 {
                sceneTransitionRemaining = 0
                hasValue[sceneLaneIndex].forEachSetBit { slot in
                    if tweenable[slot] {
                        current[sceneLaneIndex][slot] = target[sceneLaneIndex][slot]
                    }
                }
                var owed: [Int] = []
                pendingSceneClears.forEachSetBit { owed.append($0) }
                for slot in owed { clearLane(.scene, slot: slot) }
            }
        }

        // 2. Music decay (plan §3.2): any music slot not re-written this
        //    frame ALWAYS decays toward its composition neutral, and is
        //    cleared on arrival. Replace-composition music values have no
        //    numeric neutral: they clear immediately. Gesture, by contrast,
        //    HOLDS until `clearLane` (binding policy decides).
        if dt > 0 {
            var finished: [Int] = []
            hasValue[musicLane].forEachSetBit { slot in
                guard !musicWritten.contains(slot) else { return }
                guard registered[slot] else {
                    finished.append(slot)
                    return
                }
                // Defense in depth behind the ingress guard: a non-finite
                // current value can never converge (|NaN - neutral| < ε is
                // false forever) — clear it immediately so "music is ALWAYS
                // transient" (plan §3.2) holds even if one slips through.
                guard current[musicLane][slot].isFinite else {
                    finished.append(slot)
                    return
                }
                let neutral: Float
                switch compositionBySlot[slot] {
                case .additive: neutral = 0
                case .multiplicative: neutral = 1
                case .replace:
                    finished.append(slot)
                    return
                }
                let tau = tauByLane[musicLane][slot]
                if tau <= 0 {
                    finished.append(slot)
                    return
                }
                let alpha = Float(1 - exp(-dt / tau))
                current[musicLane][slot] += (neutral - current[musicLane][slot]) * alpha
                if abs(current[musicLane][slot] - neutral) < 1e-6 {
                    finished.append(slot)
                }
            }
            for slot in finished { hasValue[musicLane].remove(slot) }
        }
        musicWritten.removeAll()

        // 3. Compose lanes in Lane order (Invariant 16). The scene lane, when
        //    set, IS the base (plan §3.2 "authoritative base"); otherwise the
        //    catalog default is. Unset lanes contribute their neutral, i.e.
        //    nothing: additive +0, multiplicative ×1, replace 'unset' (skip).
        var values = [Float](repeating: 0, count: layout.slotCount)
        let sceneLane = Lane.scene.rawValue
        for slot in 0..<layout.slotCount where registered[slot] {
            var acc = hasValue[sceneLane].contains(slot) ? current[sceneLane][slot] : defaults[slot]
            let comp = compositionBySlot[slot]
            for li in (sceneLane + 1)...musicLane where hasValue[li].contains(slot) {
                switch comp {
                case .additive: acc += current[li][slot]
                case .multiplicative: acc *= current[li][slot]
                case .replace: acc = current[li][slot]
                }
            }
            values[slot] = acc
        }

        // 4. Integrator post-pass (ARCHITECTURE.md §3 "Stateful params"):
        //    phase += resolvedRate × dt × timeScale, wrapped into the phase
        //    param's range. The engine owns the phase; it OVERRIDES the lane
        //    composition at the phase slot. Frozen while paused.
        let scaledDt = Float(dt * clock.timeScale)
        for i in integrators.indices {
            if dt > 0 {
                // The rate is consumed at its RESOLVED value, i.e. clamped to
                // its own range (same range step 5 applies to the output).
                // A non-finite rate freezes the phase for the frame — the
                // phase is persistent state (Invariant 17) and one bad frame
                // must not poison it (NaN survives clamp AND wrap).
                let rateSlot = integrators[i].rateSlot
                let rate = min(max(values[rateSlot], rangeLo[rateSlot]), rangeHi[rateSlot])
                if rate.isFinite {
                    integrators[i].phase = Self.wrap(
                        integrators[i].phase + rate * scaledDt,
                        lo: integrators[i].lo, hi: integrators[i].hi)
                }
            }
            values[integrators[i].phaseSlot] = integrators[i].phase
        }

        // 5. Clamp — THE single clamp site (plan §2.2 "Range validation:
        //    clamping happens in exactly one place"). Per component.
        //    NaN-proof: min/max pass NaN through (first-argument semantics),
        //    and this table is uploaded VERBATIM to the GPU — a non-finite
        //    composition result falls back to the param default.
        for slot in 0..<layout.slotCount where registered[slot] {
            let v = values[slot]
            values[slot] = v.isFinite
                ? min(max(v, rangeLo[slot]), rangeHi[slot])
                : defaults[slot]
        }

        generation &+= 1
        return ResolvedParams(values: values, generation: generation)
    }

    /// Wrap `x` into `[lo, hi)`; degenerate ranges collapse to `lo`.
    /// Non-finite `x` collapses to `lo` — `setIntegratorPhase` routes through
    /// here, so persistent phase state can never store NaN.
    static func wrap(_ x: Float, lo: Float, hi: Float) -> Float {
        guard x.isFinite else { return lo }
        let span = hi - lo
        guard span > 0 else { return lo }
        let r = (x - lo).truncatingRemainder(dividingBy: span)
        return (r < 0 ? r + span : r) + lo
    }

    // MARK: Internal access for Inversion (same-module, pure readers)

    func compositionForSlot(_ slot: Int) -> Composition? {
        registered[slot] ? compositionBySlot[slot] : nil
    }

    func clampToRange(_ value: Float, slot: Int) -> Float {
        guard registered[slot] else { return value }
        return min(max(value, rangeLo[slot]), rangeHi[slot])
    }

    /// Base term for composition: scene lane's smoothed value if set, else
    /// the catalog default.
    func baseValue(slot: Int) -> Float {
        let sceneLane = Lane.scene.rawValue
        return hasValue[sceneLane].contains(slot) ? current[sceneLane][slot] : defaults[slot]
    }
}
