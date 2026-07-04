// GestureBindingSet.swift — the device-local, per-fractal collection of
// gesture binding tables (the "device-global per-fractal" storage decision).
//
// Bindings do NOT travel with a scene file; they are the user's control-surface
// preferences for a given fractal, keyed by the fractal's `deKey`
// (ParameterMirror.deKey / SceneEnvelope.fractalTypeKey). One table per fractal
// so switching fractals swaps the whole gesture layout. Foreign fractal keys a
// future build wrote are preserved on round-trip (forward compatibility), same
// as GestureBindingTable's per-source contract.

// MARK: - GestureBindingSet

public struct GestureBindingSet: Sendable, Hashable, Codable {
    /// Binding tables keyed by fractal identity (`deKey`). A key with an empty
    /// table is pruned so the set stays compact.
    public private(set) var tables: [String: GestureBindingTable]

    public init(tables: [String: GestureBindingTable] = [:]) {
        self.tables = tables.filter { !$0.value.isEmpty }
    }

    public var isEmpty: Bool { tables.isEmpty }

    /// The table for a fractal (empty when none stored — never nil, so callers
    /// read a stable value type).
    public func table(forFractal deKey: String) -> GestureBindingTable {
        tables[deKey] ?? GestureBindingTable()
    }

    /// Replace a fractal's table. An empty table removes the entry.
    public mutating func setTable(_ table: GestureBindingTable, forFractal deKey: String) {
        if table.isEmpty {
            tables[deKey] = nil
        } else {
            tables[deKey] = table
        }
    }

    /// Convenience: read one binding for a `(fractal, source)` pair.
    public func binding(for source: GestureSource, fractal deKey: String) -> GestureBinding? {
        tables[deKey]?.binding(for: source)
    }

    /// Convenience: write one binding, creating/pruning the fractal's table as
    /// needed. Arity mismatches are rejected by `GestureBindingTable`.
    public mutating func setBinding(
        _ binding: GestureBinding?, for source: GestureSource, fractal deKey: String
    ) {
        var table = table(forFractal: deKey)
        table.setBinding(binding, for: source)
        setTable(table, forFractal: deKey)
    }
}
