// SceneLibraryTests.swift — the on-disk scene library behind the Scenes tab:
// save/refresh/delete round-trip in a temp directory, filename sanitizing,
// and foreign-file tolerance.

import Foundation
import Testing
import ThresholdCore
@testable import ThresholdUI

@MainActor
@Suite("Scene library")
struct SceneLibraryTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("threshold-library-tests-\(UUID().uuidString)")
        return url
    }

    private func makeEnvelope(fractal: String = "mandelbulb") -> SceneEnvelope {
        var envelope = SceneEnvelope(
            version: SceneCodec.currentVersion, fractalTypeKey: fractal)
        envelope.palette = Palette(stops: [
            GradientStop(position: 0, red: 1, green: 0, blue: 0),
            GradientStop(position: 1, red: 0, green: 0, blue: 1),
        ])
        return envelope
    }

    @Test func saveRefreshDeleteRoundTrip() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SceneLibrary(directory: dir, bundled: [])
        #expect(library.items.isEmpty)

        let url = library.save(makeEnvelope(), name: "First Light")
        #expect(url != nil)
        #expect(library.lastError == nil)
        #expect(library.items.count == 1)
        let item = try #require(library.items.first)
        #expect(item.name == "First Light", "envelope name is stamped on save")
        #expect(item.fractalKey == "mandelbulb")
        #expect(item.palette?.stops.count == 2)

        // Same name overwrites (the legacy library behavior), not duplicates.
        _ = library.save(makeEnvelope(fractal: "menger"), name: "First Light")
        #expect(library.items.count == 1)
        #expect(library.items.first?.fractalKey == "menger")

        library.delete(item)
        #expect(library.items.isEmpty)
    }

    @Test func refreshSkipsForeignFiles() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SceneLibrary(directory: dir, bundled: [])
        _ = library.save(makeEnvelope(), name: "Keeper")

        try Data("not json".utf8).write(
            to: dir.appendingPathComponent("junk.threshscene"))
        try Data("{}".utf8).write(
            to: dir.appendingPathComponent("readme.txt"))
        library.refresh()
        #expect(library.items.count == 1, "undecodable/foreign files are skipped")
    }

    @Test func groupsUserAndBundledSources() throws {
        let userDir = makeTempDirectory()
        let bundledDir = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: userDir)
            try? FileManager.default.removeItem(at: bundledDir)
        }
        try FileManager.default.createDirectory(
            at: bundledDir, withIntermediateDirectories: true)
        try SceneCodec.encode(makeEnvelope()).write(
            to: bundledDir.appendingPathComponent("Shipped.threshscene"))

        let library = SceneLibrary(
            directory: userDir,
            bundled: [(id: "bundled", name: "Starters", url: bundledDir)])
        _ = library.save(makeEnvelope(), name: "Mine")

        // Writable user source first, then the read-only bundled source.
        #expect(library.sources.count == 2)
        #expect(library.sources[0].id == "user")
        #expect(library.sources[0].isWritable)
        #expect(library.sources[1].id == "bundled")
        #expect(library.sources[1].isWritable == false)
        #expect(library.sources[1].items.count == 1)
        #expect(library.items.count == 2)  // flat accessor spans both
    }

    @Test func emptyBundledSourceIsDropped() {
        let userDir = makeTempDirectory()
        let missing = makeTempDirectory()  // never created
        defer { try? FileManager.default.removeItem(at: userDir) }
        let library = SceneLibrary(
            directory: userDir,
            bundled: [(id: "bundled", name: "Starters", url: missing)])
        // The user source stays (its save row lives there); the empty bundled
        // source is omitted.
        #expect(library.sources.map(\.id) == ["user"])
    }

    @Test func filenameSanitizing() {
        #expect(SceneLibrary.filename(for: "Spiky Bulb!") == "Spiky Bulb!.threshscene")
        #expect(SceneLibrary.filename(for: "a/b:c") == "abc.threshscene")
        #expect(SceneLibrary.filename(for: "   ") == "Scene.threshscene")
    }
}
