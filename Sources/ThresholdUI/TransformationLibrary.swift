// TransformationLibrary.swift — the on-disk warp-recipe library behind the
// Warps tab. Like scenes and animation clips, transformation stacks are plain
// shareable files: a writable Application Support folder plus read-only
// recipes bundled with the app.

import Foundation
import os
import SwiftUI
import ThresholdCore
import ThresholdShaderIR

// MARK: - TransformationLibrary

/// One decoded `.threshfx` recipe with the metadata needed by the library row.
public struct TransformationLibraryItem: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let kindRawValues: [UInt32]
    public let modified: Date

    public var id: URL { url }
    public var opCount: Int { kindRawValues.count }
}

/// A named recipe source: the writable user folder or a read-only bundled
/// folder.
public struct TransformationSource: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let directory: URL
    public let isWritable: Bool
    public var items: [TransformationLibraryItem]

    public init(
        id: String, name: String, directory: URL,
        isWritable: Bool, items: [TransformationLibraryItem] = []
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.isWritable = isWritable
        self.items = items
    }
}

/// File-first library for reusable warp stacks. User recipes live in
/// Application Support/Threshold/Transformations; bundled starters are
/// discovered from `BundledContent/transforms`.
@MainActor
@Observable
public final class TransformationLibrary {
    public private(set) var sources: [TransformationSource] = []
    public var lastError: String?

    public let directory: URL
    private let bundledSpecs: [(id: String, name: String, url: URL)]
    /// Invalidates older background scans when a newer refresh/save/delete
    /// has already published state.
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    public init(
        directory: URL? = nil,
        bundled: [(id: String, name: String, url: URL)]? = nil
    ) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base
                .appendingPathComponent("Threshold", isDirectory: true)
                .appendingPathComponent("Transformations", isDirectory: true)
        }
        self.bundledSpecs = bundled ?? Self.defaultBundledSpecs()
        refresh()
    }

    public var items: [TransformationLibraryItem] { sources.flatMap(\.items) }

    nonisolated static func defaultBundledSpecs()
        -> [(id: String, name: String, url: URL)] {
        guard let root = Bundle.module.url(
            forResource: "BundledContent", withExtension: nil)
        else { return [] }
        return [
            (id: "bundled", name: "Recipes",
             url: root.appendingPathComponent("transforms", isDirectory: true)),
        ]
    }

    public func refresh() {
        refreshGeneration &+= 1
        var built = [
            TransformationSource(
                id: "user", name: "My Transformations", directory: directory,
                isWritable: true, items: Self.list(directory)),
        ]
        for spec in bundledSpecs {
            let items = Self.list(spec.url)
            guard !items.isEmpty else { continue }
            built.append(TransformationSource(
                id: spec.id, name: spec.name, directory: spec.url,
                isWritable: false, items: items))
        }
        sources = built
    }

    private static let scanQueue = DispatchQueue(
        label: "com.polinate.threshold.transformation-library-scan", qos: .utility)

    /// Scan and decode away from the main actor so opening the Warps tab never
    /// waits on filesystem I/O.
    public func refreshAsync() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let directory = directory
        let bundledSpecs = bundledSpecs
        Self.scanQueue.async {
            var built = [
                TransformationSource(
                    id: "user", name: "My Transformations", directory: directory,
                    isWritable: true, items: Self.list(directory)),
            ]
            for spec in bundledSpecs {
                let items = Self.list(spec.url)
                guard !items.isEmpty else { continue }
                built.append(TransformationSource(
                    id: spec.id, name: spec.name, directory: spec.url,
                    isWritable: false, items: items))
            }
            let result = built
            Task { @MainActor in
                guard self.refreshGeneration == generation else { return }
                self.sources = result
            }
        }
    }

    /// Decode every `.threshfx` recipe in a folder, newest first. Bad and
    /// foreign files are logged and skipped without breaking the whole list.
    nonisolated static func list(_ directory: URL) -> [TransformationLibraryItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        return urls
            .filter { $0.pathExtension.lowercased() == "threshfx" }
            .compactMap { url -> TransformationLibraryItem? in
                guard let data = try? Data(contentsOf: url),
                      let recipe = try? WarpRecipeCodec.decode(data)
                else {
                    ThresholdLog.io.error(
                        "unreadable transformation skipped: \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                let modified = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                let authoredName = recipe.name?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return TransformationLibraryItem(
                    url: url,
                    name: authoredName.flatMap { $0.isEmpty ? nil : $0 }
                        ?? url.deletingPathExtension().lastPathComponent,
                    kindRawValues: recipe.warpStack.map(\.kind),
                    modified: modified)
            }
            .sorted { lhs, rhs in
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Write a recipe under `name`, replacing an existing recipe of the same
    /// name. The name is stamped into the file so it survives renaming.
    @discardableResult
    public func save(_ recipe: WarpRecipeEnvelope, name: String) -> URL? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedName = trimmedName.isEmpty ? "Transformation" : trimmedName
        var named = recipe
        named.name = storedName
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(
                Self.filename(for: storedName), isDirectory: false)
            try WarpRecipeCodec.encode(named).write(to: url, options: .atomic)
            lastError = nil
            ThresholdLog.io.info(
                "transformation saved: \(url.lastPathComponent, privacy: .public)")
            refresh()
            return url
        } catch {
            lastError = "save failed: \(error.localizedDescription)"
            ThresholdLog.io.error(
                "transformation save failed ('\(name, privacy: .public)'): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func delete(_ item: TransformationLibraryItem) {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = item.url.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent() == root,
              candidate.pathExtension.lowercased() == "threshfx"
        else {
            lastError = "delete refused: recipe is outside My Transformations"
            ThresholdLog.io.error(
                "transformation delete refused: \(item.url.lastPathComponent, privacy: .public)")
            return
        }
        do {
            try FileManager.default.removeItem(at: candidate)
            lastError = nil
            ThresholdLog.io.info(
                "transformation deleted: \(item.url.lastPathComponent, privacy: .public)")
        } catch {
            lastError = "delete failed: \(error.localizedDescription)"
            ThresholdLog.io.error(
                "transformation delete failed (\(item.url.lastPathComponent, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    nonisolated static func filename(for name: String) -> String {
        let cleaned = String(name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // A leading dot would hide the file from list() (skipsHiddenFiles).
            .drop(while: { $0 == "." }))
        return (cleaned.isEmpty ? "Transformation" : cleaned) + ".threshfx"
    }
}

// MARK: - Actions and panel

/// Shell-owned verbs for loading a recipe through the unified file-open path
/// and saving the mirror's current authored warp stack.
public struct TransformationActions {
    public let library: TransformationLibrary
    public let load: (URL) -> Void
    public let saveCurrent: (String) -> Bool

    public init(
        library: TransformationLibrary,
        load: @escaping (URL) -> Void,
        saveCurrent: @escaping (String) -> Bool
    ) {
        self.library = library
        self.load = load
        self.saveCurrent = saveCurrent
    }
}

/// Saved and bundled transformation recipes. Applying a recipe replaces the
/// authored warp stack; individual ops remain available from Warp Stack ▸ Add.
public struct TransformationLibrarySection: View {
    let actions: TransformationActions

    @State private var newName = ""
    @State private var confirmingDelete: TransformationLibraryItem?

    public init(actions: TransformationActions) {
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Transformations", icon: "shippingbox")

            HStack(spacing: DS.Spacing.sm) {
                TextField("Stack name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveCurrent)
                Button(action: saveCurrent) {
                    Label("Save", systemImage: "plus.circle.fill")
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ForEach(actions.library.sources) { source in
                if source.items.isEmpty {
                    if source.isWritable {
                        Text("Save the current warp stack here, or drop .threshfx recipes into the Transformations folder.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("\(source.name.uppercased()) · \(source.items.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, DS.Spacing.xxs)
                    ForEach(source.items) { item in
                        TransformationRecipeRow(
                            item: item,
                            canDelete: source.isWritable,
                            onApply: { actions.load(item.url) },
                            onDelete: { confirmingDelete = item })
                    }
                }
            }

            Text("Applying a recipe replaces the current warp stack.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .moduleCard(.indigo)
        .confirmationDialog(
            "Delete \"\(confirmingDelete?.name ?? "")\"?",
            isPresented: SwiftUI.Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Transformation", role: .destructive) {
                if let item = confirmingDelete { actions.library.delete(item) }
                confirmingDelete = nil
            }
        }
        .onAppear { actions.library.refreshAsync() }
    }

    private func saveCurrent() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if actions.saveCurrent(name) { newName = "" }
    }
}

struct TransformationRecipeRow: View {
    let item: TransformationLibraryItem
    let canDelete: Bool
    let onApply: () -> Void
    let onDelete: () -> Void

    private var summary: String {
        let names = item.kindRawValues.prefix(3).map { raw in
            WarpKind(rawValue: raw)?.uiName ?? "Unknown"
        }
        let suffix = item.opCount > 3 ? " +\(item.opCount - 3)" : ""
        return names.isEmpty ? "Empty stack" : names.joined(separator: " · ") + suffix
    }

    var body: some View {
        Button(action: onApply) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                    .frame(width: RowMetrics.iconWidth)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(item.opCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: RowMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ShareLink(item: item.url) {
                Label("Share Recipe", systemImage: "square.and.arrow.up")
            }
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("\(item.name), \(item.opCount) transformations")
        .accessibilityHint("Replaces the current warp stack")
    }
}
