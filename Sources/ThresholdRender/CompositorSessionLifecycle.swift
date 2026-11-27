// Shared off-device test seam for the compositor's layer lifetime.
struct CompositorSessionLifecycle {
    private enum Phase { case idle, running, stopped }
    private var phase: Phase = .idle

    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .running
        return true
    }

    mutating func end() {
        if phase == .running { phase = .idle }
    }

    /// True only for the first stop that needs to join an active loop.
    mutating func requestStop() -> Bool {
        let shouldJoin = phase == .running
        phase = .stopped
        return shouldJoin
    }
}
