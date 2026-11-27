// PostProcessStackEdit.swift — pure list edits for the sequential
// post-processing stack. Views publish the returned array through
// ParameterMirror.setPostProcessStack; stable UUIDs keep an edit attached to
// the intended filter when rows are reordered.

import Foundation
import ThresholdCore

public enum PostProcessStackEdit {
    /// The renderer's bounded sequential stack size. The authored persistence
    /// layer may retain larger future stacks, but this UI never creates more.
    public static let maximumCount = 32

    /// Append a default filter unless the stack is full or the supplied ID is
    /// already present. The explicit ID seam keeps tests and restored UI edits
    /// deterministic; production callers normally accept the generated UUID.
    public static func adding(
        _ kind: PostProcessKind,
        to stack: [PostProcessFilterDTO],
        id: UUID = UUID()
    ) -> [PostProcessFilterDTO] {
        adding(.makeDefault(kind, id: id), to: stack)
    }

    /// Append a fully-authored filter under the same count/identity rules.
    public static func adding(
        _ filter: PostProcessFilterDTO,
        to stack: [PostProcessFilterDTO]
    ) -> [PostProcessFilterDTO] {
        guard stack.count < maximumCount,
              !stack.contains(where: { $0.id == filter.id })
        else { return stack }
        return stack + [filter]
    }

    public static func deleting(
        _ stack: [PostProcessFilterDTO], id: UUID
    ) -> [PostProcessFilterDTO] {
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return stack }
        var edited = stack
        edited.remove(at: index)
        return edited
    }

    /// Move the identified filter by `offset` positions (-1 = up, +1 = down).
    /// A missing ID or an out-of-range destination is a no-op.
    public static func moving(
        _ stack: [PostProcessFilterDTO], id: UUID, by offset: Int
    ) -> [PostProcessFilterDTO] {
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return stack }
        let destination = index + offset
        guard stack.indices.contains(destination) else { return stack }
        var edited = stack
        let filter = edited.remove(at: index)
        edited.insert(filter, at: destination)
        return edited
    }

    public static func settingEnabled(
        _ stack: [PostProcessFilterDTO], id: UUID, to enabled: Bool
    ) -> [PostProcessFilterDTO] {
        editing(stack, id: id) { $0.enabled = enabled }
    }

    public static func settingStrength(
        _ stack: [PostProcessFilterDTO], id: UUID, to strength: Float
    ) -> [PostProcessFilterDTO] {
        editing(stack, id: id) { $0.strength = strength }
    }

    public static func settingA(
        _ stack: [PostProcessFilterDTO], id: UUID,
        component: Int, to value: Float
    ) -> [PostProcessFilterDTO] {
        editing(stack, id: id) { filter in
            guard filter.a.indices.contains(component) else { return }
            filter.a[component] = value
        }
    }

    public static func settingB(
        _ stack: [PostProcessFilterDTO], id: UUID,
        component: Int, to value: Float
    ) -> [PostProcessFilterDTO] {
        editing(stack, id: id) { filter in
            guard filter.b.indices.contains(component) else { return }
            filter.b[component] = value
        }
    }

    private static func editing(
        _ stack: [PostProcessFilterDTO], id: UUID,
        _ edit: (inout PostProcessFilterDTO) -> Void
    ) -> [PostProcessFilterDTO] {
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return stack }
        var edited = stack
        edit(&edited[index])
        return edited
    }
}
