// GestureBindingStore.swift — the observable, device-local home of the gesture
// binding set + named presets.
//
// The working `set` holds both global and per-fractal bindings (scope lives in
// GestureBindingSet). Presets are named snapshots of a whole set — each captures
// the global bindings AND every per-fractal table, so applying a preset restores
// the entire control surface. Both persist immediately to UserDefaults (JSON).
// The render layer consumes `resolvedTable(forFractal:)` via `HandTracker`.

import Foundation
import Observation
import os
import ThresholdCore

/// A named snapshot of a whole binding set (global + all per-fractal tables).
public struct GestureBindingPreset: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var set: GestureBindingSet
    public var id: String { name }

    public init(name: String, set: GestureBindingSet) {
        self.name = name
        self.set = set
    }
}

@MainActor
@Observable
public final class GestureBindingStore {
    /// Versioned keys so a future format change can migrate rather than clobber.
    public static let defaultsKey = "threshold.gestures.bindings.v1"
    public static let presetsKey = "threshold.gestures.presets.v1"

    @ObservationIgnored private let defaults: UserDefaults

    /// Fired after any binding change persists — the shell wires this to push
    /// the active fractal's resolved table into the visionOS `HandTracker`.
    @ObservationIgnored public var onChange: (() -> Void)?

    /// The working set (global + per-fractal). Reading it in a view body
    /// subscribes that view to binding changes.
    public private(set) var set: GestureBindingSet
    /// Saved presets, newest edits kept in insertion order.
    public private(set) var presets: [GestureBindingPreset]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // No data = first launch (fine, quiet). Data that won't decode =
        // the user's bindings are being reset — that must be in the log.
        if let data = defaults.data(forKey: Self.defaultsKey) {
            if let decoded = try? JSONDecoder().decode(GestureBindingSet.self, from: data) {
                self.set = decoded
            } else {
                ThresholdLog.io.error(
                    "gesture binding store undecodable — resetting to defaults")
                self.set = GestureBindingSet()
            }
        } else {
            self.set = GestureBindingSet()
        }
        if let data = defaults.data(forKey: Self.presetsKey) {
            if let decoded = try? JSONDecoder().decode([GestureBindingPreset].self, from: data) {
                self.presets = decoded
            } else {
                ThresholdLog.io.error(
                    "gesture binding presets undecodable — resetting to empty")
                self.presets = []
            }
        } else {
            self.presets = []
        }
    }

    // MARK: Reads

    /// The table the runtime consumes: global merged with the fractal's.
    public func resolvedTable(forFractal fractal: String) -> GestureBindingTable {
        set.resolvedTable(forFractal: fractal)
    }

    /// Effective binding (fractal overrides global).
    public func binding(for source: GestureSource, fractal: String) -> GestureBinding? {
        set.resolvedBinding(for: source, fractal: fractal)
    }

    /// Where the effective binding lives (nil if unbound).
    public func scope(of source: GestureSource, fractal: String) -> GestureScope? {
        set.scope(of: source, fractal: fractal)
    }

    // MARK: Writes

    /// Assign or clear a binding in a specific scope, then persist.
    public func setBinding(
        _ binding: GestureBinding?, for source: GestureSource, scope: GestureScope
    ) {
        set.setBinding(binding, for: source, scope: scope)
        persist()
    }

    /// Convenience: write to the fractal scope (the editor's common case).
    public func setBinding(_ binding: GestureBinding?, for source: GestureSource, fractal: String) {
        setBinding(binding, for: source, scope: .fractal(fractal))
    }

    /// Retarget a source's binding between global and this-fractal scope.
    public func setScope(_ target: GestureScope, for source: GestureSource, fractal: String) {
        set.setScope(target, for: source, fractal: fractal)
        persist()
    }

    /// Drop bindings (in BOTH scopes) that reference params absent from `keys`.
    public func pruneOrphans(forFractal fractal: String, keeping keys: Set<ParamKey>) {
        for scope in [GestureScope.global, .fractal(fractal)] {
            var table = set.table(for: scope)
            table.pruning(toKeys: keys)
            set.setTable(table, for: scope)
        }
        persist()
    }

    // MARK: Presets

    /// Capture the current set as a named preset (replacing one of the same name).
    public func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = GestureBindingPreset(name: trimmed, set: set)
        if let i = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[i] = preset
        } else {
            presets.append(preset)
        }
        persistPresets()
    }

    /// Replace the working set with a preset's (and push to the tracker).
    public func applyPreset(named name: String) {
        guard let preset = presets.first(where: { $0.name == name }) else { return }
        set = preset.set
        persist()
    }

    public func deletePreset(named name: String) {
        presets.removeAll { $0.name == name }
        persistPresets()
    }

    // MARK: Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(set) {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            ThresholdLog.io.error(
                "gesture bindings encode failed — edits will not survive relaunch")
        }
        onChange?()
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: Self.presetsKey)
        } else {
            ThresholdLog.io.error(
                "gesture presets encode failed — edits will not survive relaunch")
        }
    }
}
