// GestureBindingStore.swift — the observable, device-local home of the gesture
// binding set (the "device-global per-fractal" storage decision).
//
// Structured data, so it is JSON in a single UserDefaults key rather than a
// scatter of @AppStorage scalars (Settings.swift's pattern is for flat values).
// Writes persist immediately; the render layer reads a plain `GestureBindingSet`
// snapshot (a later slice) — this @Observable wrapper exists for the editor.

import Foundation
import Observation
import ThresholdCore

@MainActor
@Observable
public final class GestureBindingStore {
    /// Versioned key so a future format change can migrate rather than clobber.
    public static let defaultsKey = "threshold.gestures.bindings.v1"

    @ObservationIgnored private let defaults: UserDefaults

    /// Fired after any binding change persists — the shell wires this to push
    /// the active fractal's table into the visionOS `HandTracker`.
    @ObservationIgnored public var onChange: (() -> Void)?

    /// The whole per-fractal set. Reading it in a view body subscribes that
    /// view to binding changes.
    public private(set) var set: GestureBindingSet

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(GestureBindingSet.self, from: data) {
            self.set = decoded
        } else {
            self.set = GestureBindingSet()
        }
    }

    public func table(forFractal fractal: String) -> GestureBindingTable {
        set.table(forFractal: fractal)
    }

    public func binding(for source: GestureSource, fractal: String) -> GestureBinding? {
        set.binding(for: source, fractal: fractal)
    }

    /// Assign or clear a binding, then persist. Arity mismatches are rejected
    /// by the underlying table (no-op).
    public func setBinding(_ binding: GestureBinding?, for source: GestureSource, fractal: String) {
        set.setBinding(binding, for: source, fractal: fractal)
        persist()
    }

    /// Drop bindings that reference params absent from `keys` (call on DE
    /// switch so a new fractal's editor never shows dangling targets).
    public func pruneOrphans(forFractal fractal: String, keeping keys: Set<ParamKey>) {
        var table = set.table(forFractal: fractal)
        table.pruning(toKeys: keys)
        set.setTable(table, forFractal: fractal)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(set) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        onChange?()
    }
}
