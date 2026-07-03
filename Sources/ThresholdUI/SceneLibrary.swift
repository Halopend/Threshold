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

/// The user's scene folder: list / save / delete. MainActor + synchronous:
/// scene files are a few KB of JSON and the folder holds tens of items, not
/// thousands — a background pipeline here would be complexity without a win.
@MainActor
@Observable
public final class SceneLibrary {
    public private(set) var items: [SceneLibraryItem] = []
    /// The last library error (save/delete/list) for the shell to surface.
    public var lastError: String?

    public let directory: URL

    /// `directory` defaults to Application Support/Threshold/Scenes.
    public init(directory: URL? = nil) {
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
        refresh()
    }

    /// Re-list the folder. Undecodable files are skipped (never crash the
    /// panel on a foreign file dropped into the folder).
    public func refresh() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            items = []
            return
        }
        items = urls
            .filter { $0.pathExtension == "threshscene" }
            .compactMap { url -> SceneLibraryItem? in
                guard let data = try? Data(contentsOf: url),
                      let envelope = try? SceneCodec.decode(data) else { return nil }
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
            refresh()
            return url
        } catch {
            lastError = "save failed: \(error.localizedDescription)"
            return nil
        }
    }

    public func delete(_ item: SceneLibraryItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
        } catch {
            lastError = "delete failed: \(error.localizedDescription)"
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

/// The scene library panel: save-current row + a card grid of saved scenes
/// (tap to load, context menu to delete). The legacy browse grid, minus
/// thumbnails (a render-to-thumbnail pass is a follow-up — cards show the
/// scene's palette gradient as their face).
public struct ScenesSection: View {
    let actions: SceneActions

    @State private var newName = ""
    @State private var saving = false
    @State private var confirmingDelete: SceneLibraryItem?

    public init(actions: SceneActions) {
        self.actions = actions
    }

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: DS.Spacing.sm)]

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader("Scenes", icon: "photo.on.rectangle.angled")

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

            if actions.library.items.isEmpty {
                Text("No saved scenes yet — name the current view and Save it, or drop .threshscene files into the library folder.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
                    ForEach(actions.library.items) { item in
                        SceneCard(item: item) {
                            actions.load(item.url)
                        } onDelete: {
                            confirmingDelete = item
                        }
                    }
                }
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

/// One saved-scene card: palette-gradient face + name + fractal + date.
struct SceneCard: View {
    let item: SceneLibraryItem
    let onLoad: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onLoad) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                GradientPreviewBar(
                    palette: item.palette ?? Palette(stops: [
                        GradientStop(position: 0, red: 0.2, green: 0.2, blue: 0.25),
                        GradientStop(position: 1, red: 0.45, green: 0.45, blue: 0.55),
                    ]),
                    height: 30)
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
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(item.name), \(item.fractalDisplayName)")
    }
}
