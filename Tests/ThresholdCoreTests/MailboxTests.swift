// MailboxTests.swift — CommandMailbox (generic MPSC) and LaneMailbox.

import Dispatch
import Testing
@testable import ThresholdCore

@Suite("CommandMailbox")
struct CommandMailboxTests {
    @Test("FIFO ordering is preserved")
    func ordering() {
        let mailbox = CommandMailbox<Int>(capacity: 16)
        for i in 0..<10 { mailbox.publish(i) }
        #expect(mailbox.drain() == Array(0..<10))
    }

    @Test("drain empties the mailbox")
    func drainEmpties() {
        let mailbox = CommandMailbox<Int>(capacity: 16)
        mailbox.publish(1)
        mailbox.publish(2)
        #expect(mailbox.drain() == [1, 2])
        #expect(mailbox.drain() == [])
    }

    @Test("publish after drain works, including across ring wrap-around")
    func publishAfterDrain() {
        let mailbox = CommandMailbox<Int>(capacity: 4)
        for round in 0..<10 {
            mailbox.publish(round * 2)
            mailbox.publish(round * 2 + 1)
            #expect(mailbox.drain() == [round * 2, round * 2 + 1])
        }
        #expect(!mailbox.didGrowBeyondInitialCapacity)  // 2 ≤ 4 per round
    }

    @Test("Ring grows under the lock when full; nothing is lost")
    func growth() {
        let mailbox = CommandMailbox<Int>(capacity: 4)
        for i in 0..<100 { mailbox.publish(i) }
        #expect(mailbox.drain() == Array(0..<100))
        #expect(mailbox.didGrowBeyondInitialCapacity)  // provisional per ADR-004 item 2
    }

    @Test("Growth is bounded: at maxCapacity the newest is dropped, not grown")
    func boundedGrowth() {
        // Simulate a wedged consumer: never drain, cap growth at 8.
        let mailbox = CommandMailbox<Int>(capacity: 2, maxCapacity: 8)
        for i in 0..<100 { _ = mailbox.publish(i) }
        #expect(mailbox.didGrowBeyondInitialCapacity)
        #expect(mailbox.didDropUnderBackpressure)
        // Exactly `maxCapacity` earliest elements are retained, in order; the
        // rest were rejected at publish (never enqueued past the cap).
        let drained = mailbox.drain()
        #expect(drained == Array(0..<8))
        #expect(mailbox.pendingCount == 0)
    }

    @Test("publish reports drop with its Bool return")
    func publishReturnsDropStatus() {
        let mailbox = CommandMailbox<Int>(capacity: 2, maxCapacity: 4)
        for i in 0..<4 { #expect(mailbox.publish(i)) }  // fills to the cap
        #expect(!mailbox.publish(99))                    // rejected
    }

    @Test("Concurrent publishes all arrive, per-producer order preserved")
    func concurrentPublish() {
        let producers = 4
        let perProducer = 1_000
        let mailbox = CommandMailbox<(producer: Int, sequence: Int)>(capacity: 8)

        DispatchQueue.concurrentPerform(iterations: producers) { p in
            for i in 0..<perProducer {
                mailbox.publish((producer: p, sequence: i))
            }
        }

        let drained = mailbox.drain()
        #expect(drained.count == producers * perProducer)

        // Every element arrived exactly once, and each producer's stream is
        // in program order within the global FIFO.
        var nextExpected = [Int](repeating: 0, count: producers)
        for element in drained {
            #expect(element.sequence == nextExpected[element.producer])
            nextExpected[element.producer] += 1
        }
        #expect(nextExpected == [Int](repeating: perProducer, count: producers))
    }
}

@Suite("LaneMailbox")
struct LaneMailboxTests {
    @Test("drainInto applies writes to the engine in publish order")
    func drainIntoAppliesInOrder() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", default: 0)], clock: clock)
        let slot = firstContentSlot

        // Latest-value-wins is a consequence of in-order application.
        engine.mailbox.publish(LaneWrite(lane: .user, slot: slot, value: 1))
        engine.mailbox.publish(LaneWrite(lane: .user, slot: slot, value: 2))
        engine.mailbox.publish(LaneWrite(lane: .user, slot: slot, value: 3))
        clock.advance()
        #expect(engine.resolve().values[slot] == 3)
    }

    @Test("drainInto coalesces to the latest write for each lane slot")
    func drainIntoCoalescesToLatestWrite() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", default: 0)], clock: clock)
        let slot = firstContentSlot

        engine.mailbox.publish(LaneWrite(lane: .user, slot: slot, value: 1))
        engine.mailbox.publish(LaneWrite(lane: .user, slot: slot, value: .nan))
        clock.advance()

        // The latest value wins before engine ingress validation. A stale
        // finite drag sample must not survive behind a newer invalid sample.
        #expect(engine.resolve().values[slot] == 0)
    }

    @Test("drainInto drops stale slot writes without killing the render path")
    func drainIntoDropsStaleSlots() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", default: 0)], clock: clock)
        let slot = firstContentSlot

        engine.mailbox.publish(LaneWrite(lane: .user, slot: slot + 10_000, value: 100))
        engine.mailbox.publish(LaneWrite(lane: .user, slot: slot, value: 7))
        clock.advance()

        #expect(engine.resolve().values[slot] == 7)
    }

    @Test("resolve drains the mailbox: a second resolve sees no stale writes")
    func resolveDrains() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", default: 0)], clock: clock)
        let slot = firstContentSlot

        engine.mailbox.publish(LaneWrite(lane: .music, slot: slot, value: 1))
        clock.advance()
        #expect(engine.resolve().values[slot] == 1)  // instant music, written this frame
        clock.advance()
        // Mailbox now empty → music was NOT re-written → instant decay clears it.
        #expect(engine.resolve().values[slot] == 0)
    }

    @Test("Concurrent cross-thread publishes all land")
    func concurrentPublishes() throws {
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine(
            [spec("t.v", range: -1e9...1e9, default: 0, kind: .float4)],
            clock: clock)
        let mailbox = engine.mailbox

        // 4 producers each write a distinct slot a distinct number of times;
        // the LAST write per slot carries the producer's final value.
        DispatchQueue.concurrentPerform(iterations: 4) { p in
            for i in 0...1_000 {
                mailbox.publish(LaneWrite(lane: .user, slot: firstContentSlot + p, value: Float(i * (p + 1))))
            }
        }
        clock.advance()
        let values = engine.resolve().values
        #expect(values[firstContentSlot] == 1_000)
        #expect(values[firstContentSlot + 1] == 2_000)
        #expect(values[firstContentSlot + 2] == 3_000)
        #expect(values[firstContentSlot + 3] == 4_000)
    }

    @Test("Growth beyond capacity keeps every write")
    func growth() throws {
        let mailbox = LaneMailbox(capacity: 8)
        let clock = FixedStepClock(step: 0.05)
        let engine = try makeEngine([spec("t.a", range: -1e9...1e9, default: 0)], clock: clock)

        for i in 0...100 {
            mailbox.publish(LaneWrite(lane: .user, slot: firstContentSlot, value: Float(i)))
        }
        #expect(mailbox.didGrowBeyondInitialCapacity)
        mailbox.drainInto(engine)
        clock.advance()
        #expect(engine.resolve().values[firstContentSlot] == 100)  // last write won, none lost
    }
}
