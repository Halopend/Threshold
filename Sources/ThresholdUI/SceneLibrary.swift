// SceneLibrary.swift — the on-disk scene library behind the Scenes tab
// (ports the legacy preset/scene browser flows). The library is a plain
// folder of .threshscene documents (Application Support/Threshold/Scenes):
// every item is a normal shareable scene file, so the library IS the export
// format — no separate store to migrate (plan §7's file-first persistence).
//
// Loading a scene may require compiling an embedded DE, which the SHELLS own
// (ExternalDELoader lives off the render thread) — so the panel takes load
// and save-current closures from the shell instead of touching the session.

import Foundation
import os
import SwiftUI
import ThresholdCore
import ThresholdShaderIR

// MARK: - SceneLibrary

/// One saved scene on disk, with the display metadata the card grid shows
/// (decoded once per refresh — scene files are small JSON documents).
public struct SceneLibraryItem: Identifiable, Sendable {
    public let url: URL
    public let name: String
    /// Built-in DE key, or nil when the scene ships an embedded DE.
    public let fractalKey: String?
    /// True when the scene carries its own embedded (custom) DE.
    public let hasEmbeddedDE: Bool
    public let palette: Palette?
    public let modified: Date

    public var id: URL { url }

    /// Display name for the scene's fractal.
    public var fractalDisplayName: String {
        if hasEmbeddedDE { return "Custom DE" }
        guard let fractalKey else { return "—" }
        return DERegistry.descriptor(forKey: fractalKey)?.displayName ?? fractalKey
    }
}

/// One named group of scenes on disk — the writable user folder, or a
/// read-only bundled folder (starters, legacy corpus). The library lists
/// several of these and the Scenes tab renders one section per source.
public struct SceneSource: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let directory: URL
    /// False for bundled sources: they load but do not accept save/delete.
    public let isWritable: Bool
    public var items: [SceneLibraryItem]

    public init(
        id: String, name: String, directory: URL,
        isWritable: Bool, items: [SceneLibraryItem] = []
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.isWritable = isWritable
        self.items = items
    }
}

/// The scene library: a writable user folder plus any read-only bundled
/// folders, each listed as its own source. MainActor + synchronous: scene
/// files are a few KB of JSON and each folder holds tens of items, not
/// thousands — a background pipeline here would be complexity without a win.
@MainActor
@Observable
public final class SceneLibrary {
    /// All sources in display order: writable user folder first, then bundled.
    public private(set) var sources: [SceneSource] = []
    /// The last library error (save/delete/list) for the shell to surface.
    public var lastError: String?

    /// The writable user folder (save/delete target).
    public let directory: URL
    /// Read-only bundled folders shown after the user's, as `(id, name, url)`.
    private let bundledSpecs: [(id: String, name: String, url: URL)]

    /// `directory` defaults to Application Support/Threshold/Scenes; bundled
    /// sources default to the ones shipped in the ThresholdUI resource bundle.
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
                .appendingPathComponent("Scenes", isDirectory: true)
        }
        self.bundledSpecs = bundled ?? Self.defaultBundledSpecs()
        refresh()
    }

    /// Flat list across every source — the shell's convenience accessor.
    public var items: [SceneLibraryItem] { sources.flatMap(\.items) }

    /// The bundled scene folders shipped in `BundledContent/` (starters +
    /// legacy corpus). Missing folders are simply omitted.
    nonisolated static func defaultBundledSpecs()
        -> [(id: String, name: String, url: URL)] {
        guard let root = Bundle.module.url(
            forResource: "BundledContent", withExtension: nil)
        else { return [] }
        return [
            (id: "bundled", name: "Starters",
             url: root.appendingPathComponent("scenes", isDirectory: true)),
            (id: "legacy", name: "Legacy",
             url: root.appendingPathComponent("legacy-scenes", isDirectory: true)),
        ]
    }

    /// Re-list every source. Undecodable files are skipped (never crash the
    /// panel on a foreign file dropped into a folder). Empty sources are
    /// dropped so the UI shows only groups that have scenes.
    public func refresh() {
        var built: [SceneSource] = [
            SceneSource(
                id: "user", name: "My Scenes", directory: directory,
                isWritable: true, items: Self.list(directory))
        ]
        for spec in bundledSpecs {
            let items = Self.list(spec.url)
            if items.isEmpty { continue }
            built.append(SceneSource(
                id: spec.id, name: spec.name, directory: spec.url,
                isWritable: false, items: items))
        }
        // Keep the user source even when empty (its save row lives there).
        sources = built
    }

    /// Decode every `.threshscene` in `directory` into library items, sorted
    /// newest-first. A missing/foreign folder yields an empty list.
    nonisolated static func list(_ directory: URL) -> [SceneLibraryItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return urls
            .filter { $0.pathExtension == "threshscene" }
            .compactMap { url -> SceneLibraryItem? in
                guard let data = try? Data(contentsOf: url),
                      let envelope = try? SceneCodec.decode(data) else {
                    // The file exists but won't decode — say so, or the scene
                    // just silently vanishes from the library.
                    ThresholdLog.io.error(
                        "unreadable scene skipped: \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                let modified = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                return SceneLibraryItem(
                    url: url,
                    name: envelope.name ?? url.deletingPathExtension().lastPathComponent,
                    fractalKey: envelope.embeddedDE == nil ? envelope.fractalTypeKey : nil,
                    hasEmbeddedDE: envelope.embeddedDE != nil,
                    palette: envelope.palette,
                    modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// Save an envelope under `name` (stamped into the envelope). An existing
    /// file with the same name is overwritten — "save as X" replaces X, the
    /// legacy library behavior.
    @discardableResult
    public func save(_ envelope: SceneEnvelope, name: String) -> URL? {
        var named = envelope
        named.name = name
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(
                Self.filename(for: name), isDirectory: false)
            try SceneCodec.encode(named).write(to: url)
            ThresholdLog.io.info(
                "scene saved: \(url.lastPathComponent, privacy: .public)")
            refresh()
            return url
        } catch {
            lastError = "save failed: \(error.localizedDescription)"
            ThresholdLog.io.error(
                """
                scene save failed ('\(name, privacy: .public)'): \
                \(String(describing: error), privacy: .public)
                """)
            return nil
        }
    }

    public func delete(_ item: SceneLibraryItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
            ThresholdLog.io.info(
                "scene deleted: \(item.url.lastPathComponent, privacy: .public)")
        } catch {
            lastError = "delete failed: \(error.localizedDescription)"
            ThresholdLog.io.error(
                """
                scene delete failed (\(item.url.lastPathComponent, privacy: .public)): \
                \(String(describing: error), privacy: .public)
                """)
        }
        refresh()
    }

    /// "Spiky Bulb!" → "Spiky Bulb.threshscene" (filesystem-safe, non-empty).
    nonisolated static func filename(for name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Scene" : cleaned) + ".threshscene"
    }
}

// MARK: - SceneActions

/// The shell-provided verbs behind the Scenes tab. `load` goes through the
/// shell's open flow (embedded-DE compile off the render thread); `save`
/// captures the live scene from the render thread and writes it into the
/// library under the given name.
public struct SceneActions {
    public let library: SceneLibrary
    public let load: (URL) -> Void
    public let saveCurrent: (String) async -> Bool

    public init(
        library: SceneLibrary,
        load: @escaping (URL) -> Void,
        saveCurrent: @escaping (String) async -> Bool
    ) {
        self.library = library
        self.load = load
        self.saveCurrent = saveCurrent
    }
}

// MARK: - ScenesSection

/// Top-level browser categories, mirroring the legacy app's section switcher
/// (Jump Off · Scenes · Animations · Mixed Reality). Only `.scenes` is wired
/// to content today; the others are placeholders for the ports still to land.
enum SceneCategory: String, CaseIterable, Identifiable {
    case jumpOff
    case scenes
    case animations
    case mixedReality

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jumpOff: return "Jump Off"
        case .scenes: return "Scenes"
        case .animations: return "Animations"
        case .mixedReality: return "Mixed Reality"
        }
    }

    var icon: String {
        switch self {
        case .jumpOff: return "sparkles"
        case .scenes: return "photo.on.rectangle.angled"
        case .animations: return "film.stack"
        case .mixedReality: return "cube.transparent"
        }
    }

    /// Whether this category is wired to content. Only available categories
    /// appear in the switcher — the placeholders were "coming soon" dead-ends.
    /// Flip a case true when its content lands (keep in sync with the body
    /// switch in `ScenesSection`).
    var isAvailable: Bool {
        switch self {
        case .scenes: return true
        case .jumpOff, .animations, .mixedReality: return false
        }
    }
}

/// The scene library panel: a category switcher over the save-current row and
/// a card grid of saved scenes (tap to load, context menu to delete). The
/// legacy browse grid, minus thumbnails and palette faces — cards show the
/// label only for now (a render-to-thumbnail pass is a follow-up).
public struct ScenesSection: View {
    let actions: SceneActions

    @State private var newName = ""
    @State private var saving = false
    @State private var confirmingDelete: SceneLibraryItem?
    @State private var category: SceneCategory = .scenes

    public init(actions: SceneActions) {
        self.actions = actions
    }

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: DS.Spacing.sm)]

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader("Scenes", icon: "photo.on.rectangle.angled")

            // Only categories with content show a chip — a lone category needs
            // no switcher (the section header already names it).
            let available = SceneCategory.allCases.filter(\.isAvailable)
            if available.count > 1 {
                TabStrip(
                    items: available.map {
                        TabStrip.Item($0, label: $0.label, icon: $0.icon)
                    },
                    selection: $category,
                    compact: true)
            }

            switch category {
            case .scenes:
                library
            default:
                placeholder(for: category)
            }
        }
        .moduleCard(.purple)
        .confirmationDialog(
            "Delete \"\(confirmingDelete?.name ?? "")\"?",
            isPresented: SwiftUI.Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Scene", role: .destructive) {
                if let item = confirmingDelete {
                    actions.library.delete(item)
                }
                confirmingDelete = nil
            }
        }
        .onAppear { actions.library.refresh() }
    }

    /// The saved-scene browser: save-current row over the per-source card grid.
    @ViewBuilder
    private var library: some View {
        HStack(spacing: DS.Spacing.sm) {
            TextField("Scene name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveCurrent)
            Button {
                saveCurrent()
            } label: {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Save", systemImage: "plus.circle.fill")
                }
            }
            .disabled(saving
                || newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        ForEach(actions.library.sources) { source in
            if source.items.isEmpty {
                if source.isWritable {
                    Text("No saved scenes yet — name the current view and Save it, or drop .threshscene files into the library folder.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("\(source.name.uppercased()) · \(source.items.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, DS.Spacing.xxs)
                LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
                    ForEach(source.items) { item in
                        SceneCard(
                            item: item,
                            canDelete: source.isWritable
                        ) {
                            actions.load(item.url)
                        } onDelete: {
                            confirmingDelete = item
                        }
                    }
                }
            }
        }
    }

    /// Empty-state for the categories not yet ported (Jump Off, Animations,
    /// Mixed Reality) — the switcher is live; the content lands later.
    @ViewBuilder
    private func placeholder(for category: SceneCategory) -> some View {
        VStack(spacing: DS.Spacing.xs) {
            Image(systemName: category.icon)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("\(category.label) — coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.lg)
    }

    private func saveCurrent() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !saving else { return }
        saving = true
        Task {
            if await actions.saveCurrent(name) {
                newName = ""
            }
            saving = false
        }
    }
}

/// One saved-scene card: the scene's palette gradient as the face, over
/// name + fractal + date. (A rendered thumbnail is a further follow-up; the
/// palette gradient is the cheap face every item already carries.)
struct SceneCard: View {
    let item: SceneLibraryItem
    var canDelete: Bool = true
    let onLoad: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onLoad) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                if let palette = item.palette {
                    GradientPreviewBar(palette: palette, height: 20)
                }
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack {
                    Text(item.fractalDisplayName)
                    Spacer()
                    Text(item.modified, format: .dateTime.day().month())
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.inset)
                    .fill(.quaternary.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.inset))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("\(item.name), \(item.fractalDisplayName)")
    }
}
