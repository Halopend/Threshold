// WarpStackEditTests.swift — the pure warp-stack list edits behind
// WarpStackSection, plus the add-menu default-op catalog. No GPU, no views.

import Testing
import ThresholdCore
@testable import ThresholdUI

@Suite("WarpStackEdit")
struct WarpStackEditTests {
    private let stack = [
        dto(kind: 1, strength: 1.0),   // twist
        dto(kind: 5, strength: 0.5),   // boxFold
        dto(kind: 11, strength: 2.0),  // sphereFold
    ]

    @Test("settingStrength replaces exactly one op's strength")
    func settingStrength() {
        let edited = WarpStackEdit.settingStrength(stack, at: 1, to: 0.75)
        #expect(edited.count == 3)
        #expect(edited[0] == stack[0])
        #expect(edited[2] == stack[2])
        #expect(edited[1].strength == 0.75)
        #expect(edited[1].kind == stack[1].kind)
        #expect(edited[1].a == stack[1].a)
        #expect(edited[1].b == stack[1].b)
        // Pure: the input is untouched.
        #expect(stack[1].strength == 0.5)
    }

    @Test("deleting removes exactly the indexed op")
    func deleting() {
        let edited = WarpStackEdit.deleting(stack, at: 0)
        #expect(edited == [stack[1], stack[2]])
    }

    @Test("moving by -1 / +1 swaps with the neighbor")
    func movingByOne() {
        #expect(WarpStackEdit.moving(stack, from: 1, by: -1) == [stack[1], stack[0], stack[2]])
        #expect(WarpStackEdit.moving(stack, from: 1, by: 1) == [stack[0], stack[2], stack[1]])
    }

    @Test("moving across multiple positions reinserts at the destination")
    func movingFar() {
        #expect(WarpStackEdit.moving(stack, from: 0, by: 2) == [stack[1], stack[2], stack[0]])
    }

    @Test("Out-of-range edits return the stack unchanged")
    func outOfRange() {
        #expect(WarpStackEdit.settingStrength(stack, at: -1, to: 9) == stack)
        #expect(WarpStackEdit.settingStrength(stack, at: 3, to: 9) == stack)
        #expect(WarpStackEdit.deleting(stack, at: 7) == stack)
        #expect(WarpStackEdit.moving(stack, from: 0, by: -1) == stack)  // off the top
        #expect(WarpStackEdit.moving(stack, from: 2, by: 1) == stack)   // off the bottom
        #expect(WarpStackEdit.moving([], from: 0, by: 0) == [])
        #expect(WarpStackEdit.deleting([], at: 0) == [])
    }

    @Test("Random move/strength sequences preserve the op-kind multiset (seeded)")
    func randomSequencePreservesMembership() {
        var rng = SplitMix64(seed: 42)
        var current = stack
        let originalKinds = stack.map(\.kind).sorted()
        for _ in 0..<200 {
            // Indices/offsets deliberately include out-of-range values.
            let index = rng.int(in: -1...current.count)
            if rng.int(in: 0...1) == 0 {
                current = WarpStackEdit.moving(current, from: index, by: rng.int(in: -2...2))
            } else {
                current = WarpStackEdit.settingStrength(
                    current, at: index, to: rng.float(in: -2...2))
            }
            // Moves and strength edits never add, drop, or retype ops.
            #expect(current.map(\.kind).sorted() == originalKinds)
        }
    }
}

@Suite("WarpMenu add-menu catalog")
struct WarpMenuTests {
    @Test("Every constructible kind appears exactly once (none/bounding excluded)")
    func coverage() {
        let items = WarpMenu.families.flatMap(\.items)
        let kinds = items.map(\.kindRawValue)
        #expect(items.count == 20)  // kinds 1…18 + handAttract(64) + forearmCarve(65)
        #expect(Set(kinds).count == kinds.count)
        #expect(!kinds.contains(0))   // .none
        #expect(!kinds.contains(66))  // .bounding (reserved, no constructor)
        let expected = Set<UInt32>((1...18).map(UInt32.init) + [64, 65])
        #expect(Set(kinds) == expected)
    }

    @Test("makeDefault builds an op of the advertised kind with 4-wide payloads")
    func defaultsMatchKind() {
        for family in WarpMenu.families {
            for item in family.items {
                let op = item.makeDefault()
                #expect(op.kind == item.kindRawValue, "\(item.name)")
                #expect(op.a.count == 4 && op.b.count == 4, "\(item.name)")
                #expect(op.strength.isFinite)
            }
        }
    }

    @Test("Families are non-empty and uniquely named")
    func familyShape() {
        #expect(!WarpMenu.families.isEmpty)
        let names = WarpMenu.families.map(\.name)
        #expect(Set(names).count == names.count)
        for family in WarpMenu.families {
            #expect(!family.items.isEmpty, Comment(rawValue: family.name))
        }
    }
}
