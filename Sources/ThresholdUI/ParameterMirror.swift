// ParameterMirror.swift — the @MainActor observable readback mirror
// (ARCHITECTURE.md §2: "UI readback cadence is decoupled from render cadence").
//
// The mirror polls `SnapshotSlot.latest` and mutates its observable state ONLY
// when something actually changed beyond epsilon — SwiftUI invalidation is
// driven by the mirror, never by the 60–120 fps render loop. Writes go the
// other way through the command mailbox (Invariant 13: signal table or command
// mailbox, no third channel).
//
// The mirror NEVER computes lane math. Slider edits forward RESOLVED-value
// targets (`SessionCommand.userEdit`); the grab-what-you-see inversion happens
// render-side, where live engine state lives (SessionContracts.swift).

import Foundation
import Observation
import ThresholdCore
import ThresholdRender

// MARK: - SessionStats

/// The render-loop health readout shown by `StatsSection`.
public struct SessionStats: Equatable, Sendable {
    /// Frames per second, estimated from frameIndex/time deltas between
    /// polls of the snapshot slot (session clock time — never wall time).
    public var fps: Double
    /// Previous frame's GPU duration in milliseconds.
    public var gpuMilliseconds: Double
    /// Previous frame's march-step total.
    public var totalSteps: UInt64

    public init(fps: Double = 0, gpuMilliseconds: Double = 0, totalSteps: UInt64 = 0) {
        self.fps = fps
        self.gpuMilliseconds = gpuMilliseconds
        self.totalSteps = totalSteps
    }
}

// MARK: - ParameterMirror

@MainActor
@Observable
public final class ParameterMirror {
    /// Values that move less than this between snapshots are treated as
    /// unchanged — no observable mutation, no SwiftUI diff.
    public static let epsilon: Float = 1e-5

    /// The frozen catalog layout every panel walks. Immutable.
    public let layout: CatalogLayout

    // MARK: Observable readback state (mutated only in refresh()/setters)

    /// Dense resolved param table from the latest snapshot; index == slot.
    /// Seeded from catalog defaults so controls have sane positions before
    /// the first snapshot lands.
    public private(set) var resolvedValues: [Float]
    public private(set) var stats = SessionStats()
    public private(set) var deKey: String = ""
    /// The AUTHORED warp stack (pre-simplification) — what editors display.
    public private(set) var warpStack: [WarpOpDTO] = []
    public private(set) var paused: Bool = false
    /// The active gradient palette — what the gradient editor displays.
    public private(set) var palette: Palette = Palette(stops: [])
    /// Dynamic-arena entries (external DE params) from the latest snapshot —
    /// rendered by CustomDESection exactly like static layout entries.
    public private(set) var dynamicEntries: [CatalogEntry] = []
    /// Animation transport state — what the play/scrub UI displays.
    public private(set) var animation: AnimationPlaybackState = .idle
    /// The active signal→param bindings (music reactivity + LFO routing) — the
    /// Routes editor's source of truth. Mirror-OWNED (not snapshot-echoed): the
    /// editor mutates these directly and republishes the whole set, so a
    /// fine-grained edit never flickers against a stale snapshot. Seeded from a
    /// scene on `applyScene`; captured back into the scene on Save (render side).
    public private(set) var bindings: [ThresholdCore.Binding] = []
    /// The active procedural LFO bank — the LFO editor's source of truth.
    /// Mirror-owned, same contract as `bindings`.
    public private(set) var lfos: [LFOSpec] = []
    /// Zoom-rebase counter from the latest snapshot (plan §6.3).
    public private(set) var scaleOctave: Int32 = 0
    /// Live encoder pipeline diagnostics (which pipeline, compile status,
    /// render scale) — drives the Shader Pipeline readout.
    public private(set) var diagnostics = RenderDiagnostics()
    /// Live render-pipeline tuning the UI toggles publish. Optimistic echo;
    /// the render thread is authoritative but does not currently report it back
    /// (the diagnostics reflect what actually happened).
    public private(set) var renderTuning = RenderTuning.envDefault
    /// Local echo of in-flight slider drags (slot → target resolved value),
    /// so a drag reads back its own target instead of a stale snapshot.
    public private(set) var pendingEdits: [Int: Float] = [:]

    // MARK: Non-observable plumbing

    @ObservationIgnored private let snapshots: SnapshotSlot
    @ObservationIgnored private let commands: CommandMailbox<SessionCommand>
    /// Bumped once per refresh() that applied ANY observable mutation.
    /// Internal test hook for the diffing contract ("same snapshot twice →
    /// no observable change events").
    @ObservationIgnored internal private(set) var refreshGeneration: UInt64 = 0
    /// Last distinct (frameIndex, time) pair seen — the fps-estimate baseline.
    @ObservationIgnored private var lastSample: (frameIndex: UInt64, time: Double)?
    /// Slots with an active beginEdit…endEdit interaction.
    @ObservationIgnored private var editingSlots: Set<Int> = []
    /// Consecutive `refresh()` polls since a slot's last `beginEdit`/`updateEdit`
    /// activity, keyed by slot. Ticks, not wall time (Invariant 9) — the poll
    /// cadence is the only clock this uses.
    ///
    /// Watchdog for a real AppKit/SwiftUI failure mode: `Slider.onEditingChanged`
    /// can fire `true` and never deliver the matching `false` (a click that
    /// resolves to no drag, or a mouseUp the OS delays), which without this
    /// would strand the slot in `editingSlots` forever — every future drag on
    /// that control keeps landing on the momentary user lane and never commits,
    /// i.e. "this slider stopped working." `staleEditTickLimit` consecutive
    /// idle polls force-commits it, same as a real `endEdit`.
    @ObservationIgnored private var editIdleTicks: [Int: Int] = [:]
    private static let staleEditTickLimit = 45  // ~1.5s at the default 30Hz poll
    @ObservationIgnored private var timer: Timer?

    public init(
        layout: CatalogLayout,
        snapshots: SnapshotSlot,
        commands: CommandMailbox<SessionCommand>
    ) {
        self.layout = layout
        self.snapshots = snapshots
        self.commands = commands
        var seed = [Float](repeating: 0, count: layout.slotCount)
        for entry in layout.entries {
            for (i, component) in entry.spec.defaultValue.enumerated() where entry.slot + i < seed.count {
                seed[entry.slot + i] = component
            }
        }
        self.resolvedValues = seed
    }

    // MARK: Polling

    /// Start the readback poll. This Timer is the ONE permitted UI timer
    /// (ARCHITECTURE.md §2): it sets the readback CADENCE only — all time
    /// values shown or computed come from snapshot session-clock time, never
    /// from the timer. Scheduled on the main run loop from the main actor,
    /// so the callback always runs on the main thread.
    public func startPolling(interval: TimeInterval = 1.0 / 30.0) {
        stopPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            // Safe: the timer was added to RunLoop.main, so this block only
            // ever executes on the main thread.
            MainActor.assumeIsolated {
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Pull the latest snapshot and apply it, mutating observable state only
    /// where values changed beyond `epsilon`. Public so tests (and the poll
    /// timer) drive it explicitly — no ambient time anywhere in here.
    public func refresh() {
        guard let snapshot = snapshots.latest else { return }
        var changed = false

        if Self.differ(snapshot.resolved.values, resolvedValues) {
            resolvedValues = snapshot.resolved.values
            changed = true
        }

        var newStats = stats
        newStats.gpuMilliseconds = snapshot.gpuMilliseconds
        newStats.totalSteps = snapshot.totalSteps
        if let last = lastSample {
            if snapshot.frameIndex > last.frameIndex, snapshot.time > last.time {
                newStats.fps =
                    Double(snapshot.frameIndex - last.frameIndex) / (snapshot.time - last.time)
            } else if snapshot.frameIndex == last.frameIndex, snapshot.time > last.time {
                // Session time advanced with no new frame: not rendering.
                newStats.fps = 0
            }
        }
        if lastSample?.frameIndex != snapshot.frameIndex || lastSample?.time != snapshot.time {
            lastSample = (snapshot.frameIndex, snapshot.time)
        }
        if Self.differ(newStats, stats) {
            stats = newStats
            changed = true
        }

        if snapshot.deKey != deKey {
            deKey = snapshot.deKey
            changed = true
        }
        if snapshot.warpStack != warpStack {
            warpStack = snapshot.warpStack
            changed = true
        }
        if snapshot.paused != paused {
            paused = snapshot.paused
            changed = true
        }
        if snapshot.palette != palette {
            palette = snapshot.palette
            changed = true
        }
        if snapshot.dynamicEntries != dynamicEntries {
            dynamicEntries = snapshot.dynamicEntries
            changed = true
        }
        if snapshot.animation != animation {
            animation = snapshot.animation
            changed = true
        }
        if snapshot.scaleOctave != scaleOctave {
            scaleOctave = snapshot.scaleOctave
            changed = true
        }
        if snapshot.diagnostics != diagnostics {
            diagnostics = snapshot.diagnostics
            changed = true
        }

        if reapStaleEdits() { changed = true }

        if changed { refreshGeneration &+= 1 }
    }

    /// Force-commit any slot that's been sitting in `editingSlots` with no
    /// drag activity for `staleEditTickLimit` polls — see `editIdleTicks`.
    /// Returns whether it did anything (folds into `refresh()`'s change flag
    /// since it can mutate `pendingEdits`, an observable property).
    private func reapStaleEdits() -> Bool {
        guard !editingSlots.isEmpty else { return false }
        var reaped = false
        for slot in editingSlots {
            let ticks = (editIdleTicks[slot] ?? 0) + 1
            if ticks >= Self.staleEditTickLimit {
                endEdit(slot: slot)
                reaped = true
            } else {
                editIdleTicks[slot] = ticks
            }
        }
        return reaped
    }

    /// Total zoom depth in octaves across every rebase (plan §6.3) — the
    /// stats readout's "how deep am I", immune to the phase folding.
    public var zoomDepthOctaves: Float {
        let phase = layout.slot(for: .scaleZoom).map { displayValue(slot: $0) } ?? 0
        return Float(scaleOctave) + phase
    }

    /// The value a control should display for `slot`: the in-flight edit echo
    /// if one exists, else the latest resolved value (0 for out-of-range).
    public func displayValue(slot: Int) -> Float {
        if let pending = pendingEdits[slot] { return pending }
        guard resolvedValues.indices.contains(slot) else { return 0 }
        return resolvedValues[slot]
    }

    // MARK: Edits (continuous, slot-addressed)

    /// Start a slider interaction on `slot`. Publishes nothing; arms the
    /// local echo so mid-drag refreshes don't fight the thumb.
    public func beginEdit(slot: Int) {
        editingSlots.insert(slot)
        pendingEdits[slot] = displayValue(slot: slot)
        editIdleTicks[slot] = 0
    }

    /// Forward a resolved-value target for `slot`. DURING a drag (between
    /// begin/endEdit) this is a live grab-what-you-see write to the momentary
    /// user lane; for an INSTANTANEOUS control (toggle, picker — no begin/end)
    /// it commits straight to the authored scene lane so the change sticks.
    public func updateEdit(slot: Int, target: Float) {
        if editingSlots.contains(slot) {
            pendingEdits[slot] = target
            editIdleTicks[slot] = 0
            commands.publish(.userEdit(slot: slot, targetResolved: target))
        } else {
            commands.publish(.commitUserEdit(slot: slot, targetResolved: target))
        }
    }

    /// End the interaction (slider release): COMMIT the dragged value to the
    /// scene lane so it persists and Save captures it (was `clearUserEdit`,
    /// which reverted the edit on release), and drop the local echo.
    public func endEdit(slot: Int) {
        let target = pendingEdits[slot] ?? displayValue(slot: slot)
        editingSlots.remove(slot)
        pendingEdits[slot] = nil
        editIdleTicks[slot] = nil
        commands.publish(.commitUserEdit(slot: slot, targetResolved: target))
    }

    // MARK: Structural commands
    //
    // Each setter publishes its command AND optimistically updates the local
    // observable copy so controls echo immediately; the authoritative value
    // arrives back through the snapshot within a frame. (A poll that lands
    // between publish and the render thread's drain may briefly show the
    // previous value — accepted for phase 4.)

    public func setWarpStack(_ stack: [WarpOpDTO]) {
        warpStack = stack
        commands.publish(.setWarpStack(stack))
    }

    public func setDE(key: String) {
        deKey = key
        commands.publish(.setDE(key: key))
    }

    /// Apply a scene. UI-triggered loads TWEEN by default (ADR-005, the
    /// legacy "Same Scene Transition Time" feel); pass `transition: nil` to
    /// snap (e.g. restoring state at launch).
    public func applyScene(
        _ scene: SceneEnvelope, transition: SceneTransition? = .default
    ) {
        // Seed the editors from the loaded scene: the render side installs the
        // same bindings/LFOs on apply, so the UI source of truth stays in sync
        // with the engine (see the `bindings`/`lfos` docs).
        bindings = scene.bindings
        lfos = scene.lfos
        commands.publish(.applyScene(scene, transition: transition))
    }

    /// Seed the reactive editors without applying a scene (startup, when the
    /// initial scene was handed to the session directly rather than through
    /// `applyScene`). Does not publish — the render side already has these.
    public func seedReactive(bindings: [ThresholdCore.Binding], lfos: [LFOSpec]) {
        self.bindings = bindings
        self.lfos = lfos
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
        commands.publish(.setPaused(paused))
    }

    public func setBindings(_ bindings: [ThresholdCore.Binding]) {
        self.bindings = bindings
        commands.publish(.setBindings(bindings))
    }

    /// Replace the procedural LFO bank. The LFOEngine publishes these as
    /// `lfo.*` signals; Routes bind them like any audio band.
    public func setLFOs(_ lfos: [LFOSpec]) {
        self.lfos = lfos
        commands.publish(.setLFOs(lfos))
    }

    // MARK: Routes / LFO editor mutators
    //
    // Each mutates the mirror-owned array and republishes the WHOLE set (the
    // commands replace, not patch). Convenience over `setBindings`/`setLFOs`
    // so editor rows don't each rebuild the array.

    public func addBinding(_ binding: ThresholdCore.Binding) {
        setBindings(bindings + [binding])
    }

    public func updateBinding(_ binding: ThresholdCore.Binding) {
        guard let i = bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        var next = bindings
        next[i] = binding
        setBindings(next)
    }

    public func removeBinding(id: UUID) {
        setBindings(bindings.filter { $0.id != id })
    }

    public func addLFO(_ lfo: LFOSpec) {
        setLFOs(lfos + [lfo])
    }

    public func updateLFO(_ lfo: LFOSpec) {
        guard let i = lfos.firstIndex(where: { $0.id == lfo.id }) else { return }
        var next = lfos
        next[i] = lfo
        setLFOs(next)
    }

    public func removeLFO(id: UUID) {
        setLFOs(lfos.filter { $0.id != id })
    }

    /// The `lfo.*` slots not yet claimed by a spec — what "add LFO" assigns
    /// next (nil when the bank is full).
    public var nextFreeLFOSlot: SignalID? {
        let used = Set(lfos.map { $0.slot })
        return SignalID.standardLFOs.first { !used.contains($0) }
    }

    /// Replace the gradient palette (scene content — plan §5.5). Optimistic
    /// local echo, authoritative value returns via the next snapshot.
    public func setPalette(_ palette: Palette) {
        self.palette = palette
        commands.publish(.setPalette(palette))
    }

    /// Load (nil unloads) an animation clip. Transport starts stopped —
    /// follow with `animationTransport(.play)` (SessionCommand contract).
    public func setAnimationClip(_ clip: AnimationClip?) {
        commands.publish(.setAnimationClip(clip))
    }

    /// Animation transport verb. No optimistic echo — the authoritative
    /// playback state returns via the next snapshot (transport is cheap and
    /// the play/scrub UI reads clip-local time the render thread computes).
    public func animationTransport(_ verb: AnimationTransportCommand) {
        commands.publish(.animationTransport(verb))
    }

    /// Enable/disable the fps-holding quality governor (ADR-003).
    public func setQualityGovernor(_ config: QualityGovernorConfig?) {
        commands.publish(.setQualityGovernor(config))
    }

    /// Replace the live render-pipeline tuning (specialization on/off,
    /// iteration bake). Optimistic local echo; the effect shows up in the
    /// diagnostics + gpuMs within a frame or two (a specialized variant may
    /// need a background compile before it engages).
    public func setRenderTuning(_ tuning: RenderTuning) {
        renderTuning = tuning
        commands.publish(.setRenderTuning(tuning))
    }

    // MARK: Diffing

    private static func differ(_ a: [Float], _ b: [Float]) -> Bool {
        guard a.count == b.count else { return true }
        for i in a.indices where abs(a[i] - b[i]) > epsilon { return true }
        return false
    }

    private static func differ(_ a: SessionStats, _ b: SessionStats) -> Bool {
        a.totalSteps != b.totalSteps
            || abs(a.fps - b.fps) > Double(epsilon)
            || abs(a.gpuMilliseconds - b.gpuMilliseconds) > Double(epsilon)
    }
}
