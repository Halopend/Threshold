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

    @Test("settingA writes one payload component; out-of-range is a no-op")
    func settingA() {
        let edited = WarpStackEdit.settingA(stack, at: 1, component: 2, to: 0.3)
        #expect(edited[1].a[2] == 0.3)
        #expect(edited[0] == stack[0])
        #expect(edited[2] == stack[2])
        #expect(WarpStackEdit.settingA(stack, at: 9, component: 0, to: 1) == stack)
        #expect(WarpStackEdit.settingA(stack, at: 0, component: 4, to: 1) == stack)
    }

    @Test("settingFlag sets and clears a single bit without clobbering others")
    func settingFlag() {
        let set = WarpStackEdit.settingFlag(stack, at: 0, bit: 1 << 0, on: true)
        #expect(set[0].flags == 1)
        #expect(WarpStackEdit.settingFlag(set, at: 0, bit: 1 << 0, on: false)[0].flags == 0)
        let two = WarpStackEdit.settingFlag(set, at: 0, bit: 1 << 3, on: true)
        #expect(two[0].flags == (1 | 8))
    }

    @Test("settingBoundFixed sets OPTION_B and moves the op to the end")
    func settingBoundFixed() {
        let boundStack = [dto(kind: 66, strength: 1), stack[1], stack[2]]
        let fixed = WarpStackEdit.settingBoundFixed(boundStack, at: 0, fixed: true)
        #expect(fixed.count == 3)
        #expect(fixed.last?.kind == 66)            // relocated to the end
        #expect(fixed.last?.flags == (1 << 3))     // OPTION_B set
        #expect(fixed[0].kind == boundStack[1].kind)  // others shifted up
        // Disabling Fixed clears the bit and leaves the position as-is.
        let unfixed = WarpStackEdit.settingBoundFixed(fixed, at: 2, fixed: false)
        #expect(unfixed[2].kind == 66)
        #expect(unfixed[2].flags == 0)
    }
}

@Suite("WarpMenu add-menu catalog")
struct WarpMenuTests {
    @Test("Every constructible kind appears exactly once (only none excluded)")
    func coverage() {
        let items = WarpMenu.families.flatMap(\.items)
        let kinds = items.map(\.kindRawValue)
        #expect(items.count == 21)  // kinds 1…18 + handAttract(64) + forearmCarve(65) + bounding(66)
        #expect(Set(kinds).count == kinds.count)
        #expect(!kinds.contains(0))   // .none is the only excluded kind
        #expect(kinds.contains(66))   // .bounding is now user-addable
        let expected = Set<UInt32>((1...18).map(UInt32.init) + [64, 65, 66])
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
