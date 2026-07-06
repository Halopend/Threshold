// AnimationLibrary.swift — the on-disk clip library behind the Motion ▸
// Animation sub-tab. Same shape as SceneLibrary: a writable user folder plus
// read-only bundled folders (the legacy .threshanim corpus), each listed as
// its own source. Loading a clip goes through the shell's open flow (the same
// path a dropped file takes), so the library takes a load closure rather than
// touching the session.

import Foundation
import os
import SwiftUI
import ThresholdCore

// MARK: - AnimationLibrary

/// One saved clip on disk, with the metadata the list rows show (decoded once
/// per refresh — .threshanim files are small JSON documents).
public struct AnimationLibraryItem: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let duration: Double
    public let trackCount: Int
    public let loop: LoopMode

    public var id: URL { url }
}

/// One named group of clips on disk (writable user folder or a read-only
/// bundled folder).
public struct AnimationSource: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let directory: URL
    public let isWritable: Bool
    public var items: [AnimationLibraryItem]

    public init(
        id: String, name: String, directory: URL,
        isWritable: Bool, items: [AnimationLibraryItem] = []
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.isWritable = isWritable
        self.items = items
    }
}

/// The clip library: a writable user folder plus any read-only bundled
/// folders, each listed as its own source. MainActor + synchronous (same
/// rationale as SceneLibrary — tens of small JSON files).
@MainActor
@Observable
public final class AnimationLibrary {
    public private(set) var sources: [AnimationSource] = []

    public let directory: URL
    private let bundledSpecs: [(id: String, name: String, url: URL)]

    /// `directory` defaults to Application Support/Threshold/Animations;
    /// bundled sources default to the ones shipped in the resource bundle.
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
                .appendingPathComponent("Animations", isDirectory: true)
        }
        self.bundledSpecs = bundled ?? Self.defaultBundledSpecs()
        refresh()
    }

    public var items: [AnimationLibraryItem] { sources.flatMap(\.items) }

    /// The bundled clip folder shipped in `BundledContent/anims/`.
    nonisolated static func defaultBundledSpecs()
        -> [(id: String, name: String, url: URL)] {
        guard let root = Bundle.module.url(
            forResource: "BundledContent", withExtension: nil)
        else { return [] }
        return [
            (id: "bundled", name: "Bundled",
             url: root.appendingPathComponent("anims", isDirectory: true)),
        ]
    }

    /// Re-list every source (undecodable files skipped, empty bundled sources
    /// dropped — the user source is kept so its drop hint can show).
    public func refresh() {
        var built: [AnimationSource] = [
            AnimationSource(
                id: "user", name: "My Clips", directory: directory,
                isWritable: true, items: Self.list(directory))
        ]
        for spec in bundledSpecs {
            let items = Self.list(spec.url)
            if items.isEmpty { continue }
            built.append(AnimationSource(
                id: spec.id, name: spec.name, directory: spec.url,
                isWritable: false, items: items))
        }
        sources = built
    }

    /// Decode every `.threshanim` in `directory` into items, sorted by name.
    nonisolated static func list(_ directory: URL) -> [AnimationLibraryItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }
        return urls
            .filter { $0.pathExtension == "threshanim" }
            .compactMap { url -> AnimationLibraryItem? in
                guard let data = try? Data(contentsOf: url),
                      let envelope = try? AnimationCodec.decode(data) else {
                    ThresholdLog.io.error(
                        "unreadable animation skipped: \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                let clip = envelope.clip
                return AnimationLibraryItem(
                    url: url,
                    name: clip.name ?? url.deletingPathExtension().lastPathComponent,
                    duration: clip.effectiveDuration,
                    trackCount: clip.tracks.count,
                    loop: clip.loop)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - AnimationActions

/// The shell-provided verbs behind the Animation library. `load` runs the
/// clip through the shell's open flow (decode + play), the same path a dropped
/// .threshanim file takes.
public struct AnimationActions {
    public let library: AnimationLibrary
    public let load: (URL) -> Void

    public init(library: AnimationLibrary, load: @escaping (URL) -> Void) {
        self.library = library
        self.load = load
    }
}

// MARK: - AnimationLibrarySection

/// The clip library list: grouped sources of clips, tap to load into the
/// transport. Sits above `AnimationSection` (the transport) on the Motion ▸
/// Animation sub-tab.
public struct AnimationLibrarySection: View {
    let actions: AnimationActions

    public init(actions: AnimationActions) {
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionHeader("Clips", icon: "list.bullet.rectangle")
            ForEach(actions.library.sources) { source in
                if source.items.isEmpty {
                    if source.isWritable {
                        Text("Drop .threshanim files into the Animations folder, or load one from Bundled below.")
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
                        AnimationClipRow(item: item) { actions.load(item.url) }
                    }
                }
            }
        }
        .moduleCard(.blue)
        .onAppear { actions.library.refresh() }
    }
}

/// One clip row: name + duration/track summary, tap to load.
struct AnimationClipRow: View {
    let item: AnimationLibraryItem
    let onLoad: () -> Void

    var body: some View {
        Button(action: onLoad) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
                    .frame(width: RowMetrics.iconWidth)
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Text("\(AnimationSection.timecode(item.duration)) · \(item.trackCount)tr")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: RowMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name), \(item.trackCount) tracks")
    }
}
