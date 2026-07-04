// GestureBindingSet.swift — the device-local collection of gesture binding
// tables, scoped GLOBAL (every fractal) or PER-FRACTAL (one `deKey`).
//
// Bindings do NOT travel with a scene file; they are the user's control-surface
// preferences. A source may be bound globally (applies to all fractals) or for
// a specific fractal; a fractal-specific binding OVERRIDES a global one for the
// same source (the "per-binding scope" decision). Resolution merges the two:
// `resolvedTable(forFractal:)` is what the tracker consumes. Foreign scope keys
// a future build wrote are preserved on round-trip (forward compatibility).

// MARK: - GestureScope

/// Where a binding applies. Persisted as the table's dictionary key: `"*"` for
/// global, the `deKey` otherwise (real DE keys are never `"*"`).
public enum GestureScope: Sendable, Hashable {
    case global
    case fractal(String)

    /// Reserved storage key for the global table.
    public static let globalKey = "*"

    public var storageKey: String {
        switch self {
        case .global: return Self.globalKey
        case let .fractal(deKey): return deKey
        }
    }

    public init(storageKey: String) {
        self = storageKey == Self.globalKey ? .global : .fractal(storageKey)
    }
}

// MARK: - GestureBindingSet

public struct GestureBindingSet: Sendable, Hashable, Codable {
    /// Binding tables keyed by scope storage key (`"*"` = global, else `deKey`).
    /// A key with an empty table is pruned so the set stays compact.
    public private(set) var tables: [String: GestureBindingTable]

    public init(tables: [String: GestureBindingTable] = [:]) {
        self.tables = tables.filter { !$0.value.isEmpty }
    }

    public var isEmpty: Bool { tables.isEmpty }

    // MARK: Scope-addressed access

    /// The table for a scope (empty when none stored — never nil).
    public func table(for scope: GestureScope) -> GestureBindingTable {
        tables[scope.storageKey] ?? GestureBindingTable()
    }

    /// Replace a scope's table. An empty table removes the entry.
    public mutating func setTable(_ table: GestureBindingTable, for scope: GestureScope) {
        if table.isEmpty {
            tables[scope.storageKey] = nil
        } else {
            tables[scope.storageKey] = table
        }
    }

    /// Read one binding from a specific scope (no merge).
    public func binding(for source: GestureSource, scope: GestureScope) -> GestureBinding? {
        tables[scope.storageKey]?.binding(for: source)
    }

    /// Write/clear one binding in a specific scope.
    public mutating func setBinding(
        _ binding: GestureBinding?, for source: GestureSource, scope: GestureScope
    ) {
        var table = table(for: scope)
        table.setBinding(binding, for: source)
        setTable(table, for: scope)
    }

    /// Move a source's binding to a different scope, clearing it from every
    /// other scope so exactly one definition survives. A no-op if unbound.
    public mutating func setScope(
        _ target: GestureScope, for source: GestureSource, fractal deKey: String
    ) {
        guard let binding = resolvedBinding(for: source, fractal: deKey) else { return }
        setBinding(nil, for: source, scope: .global)
        setBinding(nil, for: source, scope: .fractal(deKey))
        setBinding(binding, for: source, scope: target)
    }

    // MARK: Resolution (global ▷ fractal)

    /// The effective binding for a source under `deKey`: the fractal-specific
    /// binding if present, else the global one.
    public func resolvedBinding(for source: GestureSource, fractal deKey: String) -> GestureBinding? {
        binding(for: source, scope: .fractal(deKey)) ?? binding(for: source, scope: .global)
    }

    /// The scope a source's effective binding lives in, or nil if unbound.
    public func scope(of source: GestureSource, fractal deKey: String) -> GestureScope? {
        if binding(for: source, scope: .fractal(deKey)) != nil { return .fractal(deKey) }
        if binding(for: source, scope: .global) != nil { return .global }
        return nil
    }

    /// Global bindings merged with a fractal's (fractal wins per source) — the
    /// table the runtime tracker consumes for the active fractal.
    public func resolvedTable(forFractal deKey: String) -> GestureBindingTable {
        var merged = table(for: .global)
        for (source, binding) in table(for: .fractal(deKey)).bindings {
            merged.setBinding(binding, for: source)
        }
        return merged
    }

    // MARK: Back-compat convenience (fractal scope)

    public func table(forFractal deKey: String) -> GestureBindingTable {
        table(for: .fractal(deKey))
    }
}
