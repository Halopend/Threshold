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
public final class CommandMailbox<Element: Sendable>: Sendable {
    private struct State: Sendable {
        var buffer: [Element?]
        var head: Int = 0
        var count: Int = 0
        var didGrow: Bool = false
    }

    private let state: Mutex<State>

    public init(capacity: Int = 4096) {
        precondition(capacity > 0)
        state = Mutex(State(buffer: [Element?](repeating: nil, count: capacity)))
    }

    /// Enqueue from any thread. FIFO overall; per-producer program order is
    /// preserved (each publish is atomic under the lock).
    public func publish(_ element: Element) {
        state.withLock { s in
            if s.count == s.buffer.count {
                // Grow: double capacity, un-wrap into a fresh buffer.
                var grown = [Element?]()
                grown.reserveCapacity(s.buffer.count * 2)
                for i in 0..<s.count {
                    grown.append(s.buffer[(s.head + i) % s.buffer.count])
                }
                grown.append(contentsOf: [Element?](
                    repeating: nil, count: s.buffer.count * 2 - s.count))
                s.buffer = grown
                s.head = 0
                s.didGrow = true
            }
            s.buffer[(s.head + s.count) % s.buffer.count] = element
            s.count += 1
        }
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
}
