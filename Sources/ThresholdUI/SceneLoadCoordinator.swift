import ThresholdCore
import ThresholdRender

/// Shared scene-selection policy for desktop, tablet and immersive shells.
/// Compilation may finish in any order; only the most recent selection may
/// publish or report an error. The renderer still receives one atomic command.
@MainActor
public final class SceneLoadCoordinator {
    private let mirror: ParameterMirror
    private let prepare: @Sendable (EmbeddedDE) async throws -> ExternalDEProgram?
    private var generation: UInt64 = 0

    public convenience init(mirror: ParameterMirror, loader: ExternalDELoader) {
        self.init(mirror: mirror) { embedded in
            try await Task.detached(priority: .userInitiated) {
                try loader.load(embedded)
            }.value
        }
    }

    // Injection keeps ordering/backpressure tests independent of Metal hardware.
    init(mirror: ParameterMirror,
         prepare: @escaping @Sendable (EmbeddedDE) async throws -> ExternalDEProgram?) {
        self.mirror = mirror
        self.prepare = prepare
    }

    /// Built-ins submit immediately, also superseding unfinished compilation.
    /// Callbacks mean mailbox acceptance/failure, not render acknowledgement.
    /// Platform-only effects belong in onSubmitted so rejected scenes cannot
    /// change the microphone configuration or reset the user's hand gestures.
    @discardableResult
    public func load(
        _ scene: SceneEnvelope,
        transition: SceneTransition? = .default,
        onSubmitted: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) -> Task<Void, Never>? {
        generation &+= 1
        let request = generation
        guard let embedded = scene.embeddedDE else {
            submit(scene, program: nil, transition: transition,
                   onSubmitted: onSubmitted, onFailure: onFailure)
            return nil
        }
        let prepare = prepare
        let editMark = mirror.structuralEditRevision
        return Task { [weak self] in
            do {
                let program = try await prepare(embedded)
                guard let self, self.isCurrent(request, editMark) else { return }
                self.submit(scene, program: program, transition: transition,
                            onSubmitted: onSubmitted, onFailure: onFailure)
            } catch {
                guard let self, self.isCurrent(request, editMark) else { return }
                onFailure(error)
            }
        }
    }

    /// A compile is stale if a newer load started or the user changed the
    /// scene's structure (fractal, warp stack, maps) while it was running.
    private func isCurrent(_ request: UInt64, _ editMark: UInt64) -> Bool {
        generation == request && mirror.structuralEditRevision == editMark
    }

    private func submit(
        _ scene: SceneEnvelope, program: ExternalDEProgram?,
        transition: SceneTransition?,
        onSubmitted: () -> Void, onFailure: (any Error) -> Void
    ) {
        guard mirror.applyPreparedScene(scene, externalProgram: program, transition: transition)
        else {
            onFailure(SessionSubmissionError.commandMailboxFull)
            return
        }
        onSubmitted()
    }
}
