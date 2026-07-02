// SignalTableTests.swift — seqlock correctness, including the multi-writer
// contention torture test ADR-004 action item 1 calls for. Uses real threads
// (DispatchQueue.concurrentPerform + a dedicated reader Thread), not Swift
// concurrency tasks — the point is preemptive parallelism on Apple silicon.

import Dispatch
import Foundation
import Synchronization
import Testing
@testable import ThresholdCore

@Suite("SignalTable")
struct SignalTableTests {
    @Test("Publish/read round-trip")
    func roundTrip() {
        let id = SignalID("hand.left.pinchStrength")
        let table = SignalTable(ids: [id, SignalID("audio.onset")])

        table.publish(id: id, value: SIMD4(1, 2, 3, 4), confidence: 0.75, timestamp: 12.5)
        let signal = table.read(id: id)
        #expect(signal?.value == SIMD4(1, 2, 3, 4))
        #expect(signal?.confidence == 0.75)
        #expect(signal?.timestamp == 12.5)

        // Latest-value-wins.
        table.publish(id: id, value: SIMD4(9, 9, 9, 9), confidence: 1, timestamp: 13)
        #expect(table.read(id: id)?.value == SIMD4(9, 9, 9, 9))
    }

    @Test("Unregistered IDs: read nil, publish dropped")
    func unregistered() {
        let table = SignalTable(ids: [SignalID("a")])
        #expect(table.read(id: SignalID("nope")) == nil)
        table.publish(id: SignalID("nope"), value: .zero, confidence: 1, timestamp: 1)  // no trap
    }

    @Test("Never-published slots read as confidence 0")
    func neverPublished() {
        let table = SignalTable(ids: [SignalID("a")])
        let signal = table.read(id: SignalID("a"))
        #expect(signal?.confidence == 0)
        #expect(signal?.value == .zero)
    }

    @Test("snapshot returns every registered signal in slot order")
    func snapshot() {
        let ids = [SignalID("a"), SignalID("b"), SignalID("c")]
        let table = SignalTable(ids: ids)
        table.publish(id: SignalID("b"), value: SIMD4(5, 0, 0, 5), confidence: 1, timestamp: 2)

        let snap = table.snapshot()
        #expect(snap.map(\.id) == ids)
        #expect(snap[1].value.x == 5)
        #expect(snap[0].confidence == 0 && snap[2].confidence == 0)
    }

    @Test("Torture: 4 writers × 10k publishes, spinning reader, zero torn reads",
          .timeLimit(.minutes(2)))
    func torture() {
        // Payload encoding: w == x + y + z. Any torn read (mixing floats from
        // two different publishes) breaks the checksum with overwhelming
        // probability across 4 distinct value streams.
        let writerCount = 4
        let publishesPerWriter = 10_000
        let ownIDs = (0..<writerCount).map { SignalID("torture.own.\($0)") }
        let sharedID = SignalID("torture.shared")  // all writers contend here
        let table = SignalTable(ids: ownIDs + [sharedID])

        final class Shared: Sendable {
            let writersRemaining: Atomic<Int>
            let tornReads = Atomic<Int>(0)
            let totalReads = Atomic<Int>(0)
            init(writers: Int) { writersRemaining = Atomic(writers) }
        }
        let shared = Shared(writers: writerCount)
        let allIDs = ownIDs + [sharedID]

        // Reader: a real preemptive thread spinning across all slots until
        // every writer has finished, then one final validation sweep.
        let readerDone = DispatchSemaphore(value: 0)
        let reader = Thread {
            func validate(_ signal: Signal?) {
                guard let s = signal else { return }
                shared.totalReads.wrappingAdd(1, ordering: .relaxed)
                let v = s.value
                if v.w != v.x + v.y + v.z {
                    shared.tornReads.wrappingAdd(1, ordering: .relaxed)
                }
            }
            while shared.writersRemaining.load(ordering: .acquiring) > 0 {
                for id in allIDs { validate(table.read(id: id)) }
            }
            for id in allIDs { validate(table.read(id: id)) }
            readerDone.signal()
        }
        reader.start()

        // Writers: 4 preemptive threads, each hammering its own slot AND the
        // shared slot (multi-writer contention on one seqlock cell).
        DispatchQueue.concurrentPerform(iterations: writerCount) { w in
            var rng = SplitMix64(seed: 0xDEAD_0000 &+ UInt64(w))
            let own = ownIDs[w]
            for i in 0..<publishesPerWriter {
                let x = rng.float(in: -100...100)
                let y = rng.float(in: -100...100)
                let z = rng.float(in: -100...100)
                let value = SIMD4(x, y, z, x + y + z)
                table.publish(
                    id: i % 2 == 0 ? own : sharedID,
                    value: value, confidence: 1, timestamp: Double(i))
            }
            shared.writersRemaining.wrappingSubtract(1, ordering: .releasing)
        }

        readerDone.wait()
        #expect(shared.tornReads.load(ordering: .sequentiallyConsistent) == 0)
        // The reader must have actually observed a meaningful number of reads.
        #expect(shared.totalReads.load(ordering: .sequentiallyConsistent) > 1000)

        // Post-quiescence: all slots hold checksum-consistent final values.
        for signal in table.snapshot() where signal.confidence > 0 {
            let v = signal.value
            #expect(v.w == v.x + v.y + v.z)
        }
    }
}
