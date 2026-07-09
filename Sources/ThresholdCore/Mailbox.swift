// Mailbox.swift — the generic MPSC command mailbox (ARCHITECTURE.md §2,
// ADR-004, Invariant 13).
//
// Structural changes (scene apply, warp-stack edit, binding change, DE swap)
// reach the render thread ONLY through a mailbox like this one, drained once
// per frame BEFORE resolution — a frame sees either the old structure or the
// new one, never a torn mix. The concrete `Command` enum arrives with scene
// apply in a later phase; the mailbox is generic until then.
//
// Compiler-checked Sendable: the only stored property is a `Mutex` over
// Sendable state — no `@unchecked` needed (the ADR-004 audit budget is spent
// on `SignalTable` alone).

import Synchronization

/// Multi-producer single-consumer FIFO mailbox. `publish` from any thread;
/// `drain()` on the render thread.
///
/// Implementation: `Mutex`-protected preallocated ring (default capacity
/// 4096). If the ring fills, it GROWS UNDER THE LOCK — allocation on the
/// publish path, documented as PROVISIONAL versus ADR-004 action item 2
/// (allocation-free publish); `didGrowBeyondInitialCapacity` exposes the
/// condition for telemetry/tests.
///
/// The ring only ever fills when the single consumer (the render thread) is
/// NOT draining — i.e. it is wedged. A healthy session sits far below the
/// initial capacity. So growth is bounded at `maxCapacity` (default 262144,
/// ~64× the default ring): beyond it the render thread has demonstrably stalled
/// for a very long time and further growth only trades a diagnosable wedge for
/// an out-of-memory crash. At the cap `publish` DROPS the newest element and
/// raises a one-time `.fault`, leaving a trail (the whole point on
/// `debug/lockups`) instead of growing without limit. `didDropUnderBackpressure`
/// exposes the condition for tests/telemetry.
public final class CommandMailbox<Element: Sendable>: Sendable {
    private struct State: Sendable {
        var buffer: [Element?]
        var head: Int = 0
        var count: Int = 0
        var didGrow: Bool = false
        var didDrop: Bool = false
    }

    private let state: Mutex<State>
    private let maxCapacity: Int

    public init(capacity: Int = 4096, maxCapacity: Int = 1 << 18) {
        precondition(capacity > 0)
        precondition(maxCapacity >= capacity)
        self.maxCapacity = maxCapacity
        state = Mutex(State(buffer: [Element?](repeating: nil, count: capacity)))
    }

    /// Enqueue from any thread. FIFO overall; per-producer program order is
    /// preserved (each publish is atomic under the lock). Returns `false` iff
    /// the element was DROPPED because the ring is full at `maxCapacity` (the
    /// consumer is wedged); `true` on every normal enqueue.
    @discardableResult
    public func publish(_ element: Element) -> Bool {
        let dropped: Bool = state.withLock { s in
            if s.count == s.buffer.count {
                guard s.buffer.count < maxCapacity else {
                    // Wedged consumer: cap reached. Drop the newest, don't grow
                    // into an OOM. One-time fault so the wedge is diagnosable.
                    if !s.didDrop {
                        s.didDrop = true
                        ThresholdLog.session.fault(
                            """
                            command mailbox saturated at cap \(self.maxCapacity) \
                            — consumer (render thread) is wedged; dropping \
                            commands until it drains
                            """)
                    }
                    return true
                }
                // Grow: double capacity (clamped to the cap), un-wrap into a
                // fresh buffer.
                let newCapacity = min(s.buffer.count * 2, maxCapacity)
                var grown = [Element?]()
                grown.reserveCapacity(newCapacity)
                for i in 0..<s.count {
                    grown.append(s.buffer[(s.head + i) % s.buffer.count])
                }
                grown.append(contentsOf: [Element?](
                    repeating: nil, count: newCapacity - s.count))
                s.buffer = grown
                s.head = 0
                s.didGrow = true
            }
            s.buffer[(s.head + s.count) % s.buffer.count] = element
            s.count += 1
            return false
        }
        return !dropped
    }

    /// Dequeue everything, in publish order, and empty the ring. Render
    /// thread (the single consumer). Ring slots are nil-ed so drained
    /// elements release promptly.
    public func drain() -> [Element] {
        state.withLock { s in
            var result: [Element] = []
            result.reserveCapacity(s.count)
            for i in 0..<s.count {
                let idx = (s.head + i) % s.buffer.count
                result.append(s.buffer[idx]!)  // count invariant: always non-nil
                s.buffer[idx] = nil
            }
            s.head = 0
            s.count = 0
            return result
        }
    }

    /// True if the ring ever exceeded its initial capacity (ADR-004 action
    /// item 2 observability).
    public var didGrowBeyondInitialCapacity: Bool {
        state.withLock { $0.didGrow }
    }

    /// True if any element was ever dropped because the ring saturated at
    /// `maxCapacity` (the consumer was wedged). Observability only.
    public var didDropUnderBackpressure: Bool {
        state.withLock { $0.didDrop }
    }

    /// Current queued element count. Observability only; producers may change
    /// it immediately after this returns.
    public var pendingCount: Int {
        state.withLock { $0.count }
    }
}
