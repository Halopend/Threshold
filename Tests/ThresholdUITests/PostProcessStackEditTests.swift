// PostProcessStackEditTests.swift — stable-ID edits for the authored,
// sequential post-processing stack. Pure CPU tests: no views and no GPU.

import Foundation
import Testing
@testable import ThresholdCore
@testable import ThresholdUI

@Suite("PostProcessStackEdit")
struct PostProcessStackEditTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private var stack: [PostProcessFilterDTO] {
        [
            filter(.bloom, id: firstID, strength: 0.2),
            filter(.gaussianBlur, id: secondID, strength: 0.4),
            filter(.vignette, id: thirdID, strength: 0.6),
        ]
    }

    @Test("Enable, strength, and payload edits target stable IDs")
    func scalarAndPayloadEdits() {
        let original = stack
        var edited = PostProcessStackEdit.settingEnabled(original, id: secondID, to: false)
        edited = PostProcessStackEdit.settingStrength(edited, id: secondID, to: 0.75)
        edited = PostProcessStackEdit.settingA(edited, id: secondID, component: 2, to: 4)
        edited = PostProcessStackEdit.settingB(edited, id: secondID, component: 1, to: -2)

        #expect(edited[0] == original[0])
        #expect(edited[2] == original[2])
        #expect(edited[1].id == secondID)
        #expect(!edited[1].enabled)
        #expect(edited[1].strength == 0.75)
        #expect(edited[1].a[2] == 4)
        #expect(edited[1].b[1] == -2)
        #expect(original[1].enabled && original[1].strength == 0.4,
                "edits must not mutate the input value")
    }

    @Test("Delete and move use identity rather than a stale row index")
    func deleteAndMove() {
        let moved = PostProcessStackEdit.moving(stack, id: thirdID, by: -2)
        #expect(moved.map(\.id) == [thirdID, firstID, secondID])

        // The second filter moved to row 2, but its stable ID still targets it.
        let edited = PostProcessStackEdit.settingStrength(moved, id: secondID, to: 1.25)
        #expect(edited[2].id == secondID && edited[2].strength == 1.25)

        let deleted = PostProcessStackEdit.deleting(edited, id: firstID)
        #expect(deleted.map(\.id) == [thirdID, secondID])
    }

    @Test("Missing IDs, invalid components, and off-edge moves are no-ops")
    func invalidEdits() {
        let missing = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        #expect(PostProcessStackEdit.deleting(stack, id: missing) == stack)
        #expect(PostProcessStackEdit.moving(stack, id: missing, by: 1) == stack)
        #expect(PostProcessStackEdit.moving(stack, id: firstID, by: -1) == stack)
        #expect(PostProcessStackEdit.moving(stack, id: thirdID, by: 1) == stack)
        #expect(PostProcessStackEdit.settingEnabled(stack, id: missing, to: false) == stack)
        #expect(PostProcessStackEdit.settingStrength(stack, id: missing, to: 9) == stack)
        #expect(PostProcessStackEdit.settingA(stack, id: firstID, component: -1, to: 9) == stack)
        #expect(PostProcessStackEdit.settingB(stack, id: firstID, component: 4, to: 9) == stack)
    }

    @Test("Add appends in execution order, rejects duplicate IDs, and caps at 32")
    func addAndMaximum() {
        let appended = PostProcessStackEdit.adding(.invert, to: stack,
                                                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        #expect(appended.count == 4)
        #expect(appended.dropLast() == stack[...])
        #expect(appended.last?.knownKind == .invert)

        let duplicate = PostProcessStackEdit.adding(stack[0], to: stack)
        #expect(duplicate == stack)

        let full = (0..<PostProcessStackEdit.maximumCount).map { i in
            filter(.filmGrain, id: deterministicID(i), strength: Float(i))
        }
        let overflow = PostProcessStackEdit.adding(
            .posterize, to: full,
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        #expect(overflow == full)
        #expect(overflow.count == 32)
    }

    private func filter(
        _ kind: PostProcessKind, id: UUID, strength: Float
    ) -> PostProcessFilterDTO {
        PostProcessFilterDTO(
            id: id, kind: kind, enabled: true, strength: strength,
            a: [1, 2, 3, 4], b: [5, 6, 7, 8])
    }

    private func deterministicID(_ value: Int) -> UUID {
        let suffix = String(format: "%012X", value)
        return UUID(uuidString: "10000000-0000-0000-0000-\(suffix)")!
    }
}
