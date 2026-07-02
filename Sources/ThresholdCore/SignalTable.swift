// SignalTable.swift — the seqlock signal table (plan §4.1, ARCHITECTURE.md
// §2, ADR-004 action item 1).
//
// ============================ AUDIT NOTICE =================================
// `SignalTable` is one of the TWO types in this codebase permitted to be
// `@unchecked Sendable` (ADR-004; the CI grep gate allows exactly the named
// files). Its correctness is proven by hand + the contention torture test in
// `Tests/ThresholdCoreTests/SignalTableTests.swift`, not by the compiler.
//
// Safety argument:
// - All storage is fixed at `init` (capacity = registered SignalIDs); no
//   allocation, resize, or pointer re-seating ever happens after init, so
//   the raw pointers themselves are safely shared.
// - Each slot is a SEQLOCK: an `Atomic<UInt64>` version plus a plain payload
//   cell. Writers (any thread) CAS the version to ODD (acquiring — payload
//   stores cannot hoist above it), write the payload, then store version+2
//   EVEN (releasing — payload stores cannot sink below it). The CAS also
//   makes concurrent writers to the SAME slot mutually exclusive: a writer
//   that observes an odd version spins.
// - Readers load the version (acquiring), reject odd, copy the payload,
//   fence (acquiring), re-load the version, and retry on change. Retries are
//   bounded (64); on exhaustion the reader returns its last-good copy.
// - The payload copy itself is a racy non-atomic read, as in every seqlock;
//   torn data is DISCARDED by the version re-check and never escapes. This
//   is the standard, deliberately TSAN-exempt seqlock pattern the ADR calls
//   for (litmus-tested on Apple silicon via the torture test).
// - `read`/`snapshot` mutate the `lastGood` cache; they are render-thread-
//   confined by contract (ADR-004: the resolver is the single reader).
//   `publish` is safe from any thread and never allocates.
// ===========================================================================

import Synchronization

// MARK: - SignalID / Signal

/// Stable identity of an input signal (`"hand.left.pinchStrength"`,
/// `"audio.onset"`, `"crown.delta"` — plan §4.1 namespaces).
public struct SignalID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// One published signal sample. Scalars live in `value.x`; vectors use more
/// lanes. `confidence` 0…1 (0 = "no sample yet" for never-published slots).
public struct Signal: Sendable, Equatable {
    public let id: SignalID
    public let value: SIMD4<Float>
    public let confidence: Float
    public let timestamp: Double

    public init(id: SignalID, value: SIMD4<Float>, confidence: Float, timestamp: Double) {
        self.id = id
        self.value = value
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

// MARK: - SignalTable

/// Fixed-capacity latest-value signal table. Writers on any thread
/// (`publish`), single reader on the render thread (`read`/`snapshot`).
/// See the audit notice at the top of this file.
public final class SignalTable: @unchecked Sendable {
    /// POD payload cell guarded by the slot's seqlock version word.
    fileprivate struct Payload {
        var value: SIMD4<Float> = .zero
        var confidence: Float = 0
        var _pad: Float = 0
        var timestamp: Double = 0
    }

    private let indexByID: [SignalID: Int]
    private let ids: [SignalID]
    private let capacity: Int
    /// One seqlock version word per slot. Even = stable, odd = write in
    /// progress.
    private let versions: UnsafeMutablePointer<Atomic<UInt64>>
    /// Contiguous payload storage, one cell per slot.
    private let payloads: UnsafeMutablePointer<Payload>
    /// Reader-owned last-good copies (render-thread confined; see audit).
    private let lastGood: UnsafeMutablePointer<Payload>

    private static let maxReadRetries = 64

    /// Capacity is fixed from the registered IDs; publishing an unregistered
    /// ID is dropped (documented: sources register their namespace up front).
    public init(ids: [SignalID]) {
        // Deduplicate, preserving first-seen order.
        var seen = Set<SignalID>()
        var unique: [SignalID] = []
        for id in ids where seen.insert(id).inserted { unique.append(id) }

        self.ids = unique
        self.capacity = unique.count
        var index: [SignalID: Int] = [:]
        index.reserveCapacity(unique.count)
        for (i, id) in unique.enumerated() { index[id] = i }
        self.indexByID = index

        let n = max(1, unique.count)  // avoid zero-sized allocations
        versions = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: n)
        payloads = UnsafeMutablePointer<Payload>.allocate(capacity: n)
        lastGood = UnsafeMutablePointer<Payload>.allocate(capacity: n)
        for i in 0..<n {
            (versions + i).initialize(to: Atomic(0))
            (payloads + i).initialize(to: Payload())
            (lastGood + i).initialize(to: Payload())
        }
    }

    deinit {
        let n = max(1, capacity)
        versions.deinitialize(count: n)
        versions.deallocate()
        payloads.deinitialize(count: n)
        payloads.deallocate()
        lastGood.deinitialize(count: n)
        lastGood.deallocate()
    }

    /// All registered IDs, in slot order.
    public var registeredIDs: [SignalID] { ids }

    // MARK: Writer path (any thread; no allocation)

    /// Publish the latest value for a signal. Callable from any thread
    /// (ARKit callbacks, the audio tap queue, gesture recognizers). Unknown
    /// IDs are dropped. Never allocates, never blocks on the reader; blocks
    /// only briefly against another writer racing the SAME slot.
    public func publish(id: SignalID, value: SIMD4<Float>, confidence: Float, timestamp: Double) {
        guard let i = indexByID[id] else { return }
        let version = versions + i

        // Acquire the slot: CAS even → odd. Odd means another writer is
        // mid-write on this slot; spin until it finishes (writes are a few
        // stores — bounded and brief).
        var observed = version.pointee.load(ordering: .relaxed)
        while true {
            if observed & 1 == 1 {
                observed = version.pointee.load(ordering: .relaxed)
                continue
            }
            let (exchanged, original) = version.pointee.compareExchange(
                expected: observed,
                desired: observed &+ 1,
                successOrdering: .acquiring,
                failureOrdering: .relaxed)
            if exchanged { break }
            observed = original
        }

        // StoreStore barrier: the odd version MUST become visible before any
        // payload store does, or a reader can pair a stale even version with
        // half-new payload and accept a torn read. The CAS's `.acquiring`
        // success ordering does not provide this (it orders the CAS's load,
        // not its store, against the stores below). Mirror of the reader's
        // `.acquiring` fence.
        atomicMemoryFence(ordering: .releasing)

        (payloads + i).pointee = Payload(
            value: value, confidence: confidence, _pad: 0, timestamp: timestamp)

        // Publish: odd → even, releasing so the payload stores above cannot
        // sink past it.
        version.pointee.store(observed &+ 2, ordering: .releasing)
    }

    // MARK: Reader path (render thread)

    /// Latest sample for `id`, or nil for an unregistered ID. Never-published
    /// slots read as zeros with `confidence == 0`. Render thread only (the
    /// last-good cache is reader-owned — see audit notice).
    public func read(id: SignalID) -> Signal? {
        guard let i = indexByID[id] else { return nil }
        return Signal(id: id, payload: readPayload(at: i))
    }

    /// Latest samples for every registered signal, in slot order. Render
    /// thread only. (Allocates the result array; call at frame start, not in
    /// inner loops.)
    public func snapshot() -> [Signal] {
        var result: [Signal] = []
        result.reserveCapacity(capacity)
        for i in 0..<capacity {
            result.append(Signal(id: ids[i], payload: readPayload(at: i)))
        }
        return result
    }

    private func readPayload(at i: Int) -> Payload {
        let version = versions + i
        for _ in 0..<Self.maxReadRetries {
            let v1 = version.pointee.load(ordering: .acquiring)
            if v1 & 1 == 1 { continue }  // write in progress
            let copy = (payloads + i).pointee  // racy read; validated below
            // The fence keeps the payload read from drifting past the
            // version re-check (an acquiring load only orders LATER accesses).
            atomicMemoryFence(ordering: .acquiring)
            let v2 = version.pointee.load(ordering: .acquiring)
            if v1 == v2 {
                (lastGood + i).pointee = copy
                return copy
            }
        }
        // Contention exhausted the retry budget: fall back to the last
        // validated copy rather than stalling the frame.
        return (lastGood + i).pointee
    }
}

extension Signal {
    fileprivate init(id: SignalID, payload: SignalTable.Payload) {
        self.init(
            id: id, value: payload.value,
            confidence: payload.confidence, timestamp: payload.timestamp)
    }
}
