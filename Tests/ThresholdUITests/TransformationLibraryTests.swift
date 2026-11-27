// TransformationLibraryTests.swift — focused coverage for the file-first
// `.threshfx` library: writable user recipes, read-only bundled sources, and
// resilient metadata scans.

import Foundation
import Testing
import ThresholdCore
@testable import ThresholdUI

@MainActor
@Suite("Transformation library")
struct TransformationLibraryTests {
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("threshold-transform-tests-\(UUID().uuidString)")
    }

    private func recipe(
        name: String? = nil,
        kinds: [UInt32] = [1]
    ) -> WarpRecipeEnvelope {
        WarpRecipeEnvelope(
            name: name,
            warpStack: kinds.enumerated().map { index, kind in
                WarpOpDTO(
                    kind: kind,
                    flags: UInt32(index),
                    strength: Float(index + 1) / 4,
                    a: [Float(index), 1, 0, 0],
                    b: [0, 0, 0, Float(index)])
            })
    }

    @discardableResult
    private func writeRecipe(
        _ recipe: WarpRecipeEnvelope,
        filename: String,
        to directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try WarpRecipeCodec.encode(recipe).write(to: url)
        return url
    }

    @Test func saveRefreshDeleteRoundTrip() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = TransformationLibrary(directory: directory, bundled: [])
        #expect(library.items.isEmpty)

        let savedURL = try #require(library.save(
            recipe(kinds: [1, 7]), name: "Fold and Twist"))
        #expect(savedURL.pathExtension == "threshfx")
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
        #expect(library.lastError == nil)
        #expect(library.items.count == 1)

        library.refresh()
        let item = try #require(library.items.first)
        #expect(item.name == "Fold and Twist")
        #expect(item.kindRawValues == [1, 7])
        #expect(item.opCount == 2)

        library.delete(item)
        #expect(library.lastError == nil)
        #expect(library.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: savedURL.path))
    }

    @Test func saveStampsNameAndOverwritesBySanitizedFilename() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = TransformationLibrary(directory: directory, bundled: [])

        let firstURL = try #require(library.save(
            recipe(name: "Ignored", kinds: [4]), name: "Shared Stack"))
        let first = try WarpRecipeCodec.decode(Data(contentsOf: firstURL))
        #expect(first.name == "Shared Stack", "save stamps the library name into the envelope")
        #expect(first.warpStack.map(\.kind) == [4])

        let secondURL = try #require(library.save(
            recipe(name: "Also ignored", kinds: [8, 15, 66]),
            name: "Shared Stack"))
        #expect(secondURL == firstURL)
        #expect(library.items.count == 1, "saving the same name replaces instead of duplicating")

        let replaced = try WarpRecipeCodec.decode(Data(contentsOf: secondURL))
        #expect(replaced.name == "Shared Stack")
        #expect(replaced.warpStack.map(\.kind) == [8, 15, 66])
        #expect(library.items.first?.kindRawValues == [8, 15, 66])
        #expect(library.items.first?.opCount == 3)
    }

    @Test func groupsUserAndBundledSourcesAndDecodesOpMetadata() throws {
        let userDirectory = makeTempDirectory()
        let bundledDirectory = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: userDirectory)
            try? FileManager.default.removeItem(at: bundledDirectory)
        }
        try writeRecipe(
            recipe(name: "Polyhedral Bloom", kinds: [8, 7, 17, 66]),
            filename: "opaque-file-name.threshfx",
            to: bundledDirectory)

        let library = TransformationLibrary(
            directory: userDirectory,
            bundled: [(id: "bundled", name: "Recipes", url: bundledDirectory)])
        _ = library.save(recipe(kinds: [1]), name: "Mine")

        #expect(library.sources.map(\.id) == ["user", "bundled"])
        #expect(library.sources.map(\.name) == ["My Transformations", "Recipes"])
        #expect(library.sources[0].isWritable)
        #expect(!library.sources[1].isWritable)
        #expect(library.items.count == 2)

        let bundled = try #require(library.sources[1].items.first)
        #expect(bundled.name == "Polyhedral Bloom", "embedded name wins over the filename")
        #expect(bundled.kindRawValues == [8, 7, 17, 66])
        #expect(bundled.opCount == 4)
    }

    @Test func missingOrBlankNameFallsBackToFilename() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecipe(
            recipe(kinds: [12, 5]),
            filename: "Nested Spheres.threshfx",
            to: directory)
        try writeRecipe(
            recipe(name: " \n ", kinds: [4]),
            filename: "Mirror Field.threshfx",
            to: directory)

        let items = TransformationLibrary(directory: directory, bundled: []).items
        #expect(Set(items.map(\.name)) == ["Nested Spheres", "Mirror Field"])
        #expect(items.first(where: { $0.name == "Nested Spheres" })?.kindRawValues == [12, 5])
        #expect(items.first(where: { $0.name == "Nested Spheres" })?.opCount == 2)
    }

    @Test func refreshSkipsCorruptRecipesAndForeignFiles() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecipe(
            recipe(name: "Keeper", kinds: [9]),
            filename: "keeper.threshfx",
            to: directory)
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("corrupt.threshfx"))
        try Data(#"{"version": 99, "warpStack": []}"#.utf8).write(
            to: directory.appendingPathComponent("future.threshfx"))
        try WarpRecipeCodec.encode(recipe(name: "Wrong Extension", kinds: [1])).write(
            to: directory.appendingPathComponent("foreign.threshscene"))

        let library = TransformationLibrary(directory: directory, bundled: [])
        library.refresh()
        #expect(library.sources.map(\.id) == ["user"])
        #expect(library.items.count == 1)
        #expect(library.items.first?.name == "Keeper")
        #expect(library.items.first?.kindRawValues == [9])
    }

    @Test func emptyOrUndecodableBundledSourceIsDropped() throws {
        let userDirectory = makeTempDirectory()
        let bundledDirectory = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: userDirectory)
            try? FileManager.default.removeItem(at: bundledDirectory)
        }
        try FileManager.default.createDirectory(
            at: bundledDirectory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(
            to: bundledDirectory.appendingPathComponent("broken.threshfx"))

        let library = TransformationLibrary(
            directory: userDirectory,
            bundled: [(id: "bundled", name: "Recipes", url: bundledDirectory)])
        #expect(library.sources.map(\.id) == ["user"])
    }

    @Test func defaultBundleShipsThePlannedStarterRecipes() throws {
        let userDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: userDirectory) }

        let library = TransformationLibrary(directory: userDirectory)
        let bundled = try #require(
            library.sources.first(where: { $0.id == "bundled" }))
        let expectedKinds: [String: [UInt32]] = [
            "Icosahedral Bloom": [8, 11, 15],
            "Menger Blocks": [9, 17, 10, 9],
            "Kaleido Tunnel": [16, 7, 1],
            "Nested Spheres": [12, 14, 4],
            "Sierpinski Web": [6, 6, 6, 17],
        ]
        #expect(Set(bundled.items.map(\.name)) == Set(expectedKinds.keys))
        #expect(Dictionary(uniqueKeysWithValues:
            bundled.items.map { ($0.name, $0.kindRawValues) }) == expectedKinds)
        #expect(bundled.items.allSatisfy {
            (2...4).contains($0.opCount) && $0.kindRawValues.allSatisfy { $0 < 64 }
        })

        let bloomItem = try #require(
            bundled.items.first(where: { $0.name == "Icosahedral Bloom" }))
        let bloom = try WarpRecipeCodec.decode(Data(contentsOf: bloomItem.url))
        #expect(bloom.warpStack.first?.a == [5, 3, 0, 0])

        // Public model API also enforces source writability; callers cannot
        // bypass the view's hidden Delete action for bundled recipes.
        library.delete(bloomItem)
        #expect(FileManager.default.fileExists(atPath: bloomItem.url.path))
        #expect(library.lastError != nil)
    }

    @Test func filenameSanitizing() {
        #expect(TransformationLibrary.filename(for: "Fold & Twist") == "Fold & Twist.threshfx")
        #expect(TransformationLibrary.filename(for: "a/b:c") == "abc.threshfx")
        #expect(TransformationLibrary.filename(for: "   ") == "Transformation.threshfx")
    }
}
