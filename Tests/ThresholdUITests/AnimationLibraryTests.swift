// AnimationLibraryTests.swift — the on-disk clip library behind the Motion ▸
// Animate sub-tab: source grouping, metadata decode, and foreign-file
// tolerance in a temp directory.

import Foundation
import Testing
import ThresholdCore
@testable import ThresholdUI

@MainActor
@Suite("Animation library")
struct AnimationLibraryTests {
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("threshold-anim-tests-\(UUID().uuidString)")
    }

    private func writeClip(
        _ name: String, to dir: URL, duration: Double = 4, tracks: Int = 2
    ) throws {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let clip = AnimationClip(
            name: name, loop: .loop, duration: duration,
            tracks: (0..<tracks).map { _ in
                AnimationTrack(param: .engineAOStrength, keyframes: [
                    Keyframe(time: 0, values: [0]),
                    Keyframe(time: duration, values: [1]),
                ])
            })
        let data = try AnimationCodec.encode(AnimationEnvelope(clip: clip))
        try data.write(to: dir.appendingPathComponent("\(name).threshanim"))
    }

    @Test func groupsAndDecodesMetadata() throws {
        let userDir = makeTempDirectory()
        let bundledDir = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: userDir)
            try? FileManager.default.removeItem(at: bundledDir)
        }
        try writeClip("Pulse", to: bundledDir, duration: 6, tracks: 3)

        let library = AnimationLibrary(
            directory: userDir,
            bundled: [(id: "bundled", name: "Bundled", url: bundledDir)])

        #expect(library.sources.map(\.id) == ["user", "bundled"])
        let item = try #require(library.sources.last?.items.first)
        #expect(item.name == "Pulse")
        #expect(item.duration == 6)
        #expect(item.trackCount == 3)
        #expect(item.loop == .loop)
    }

    @Test func skipsForeignFilesAndDropsEmptyBundled() throws {
        let userDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }
        try FileManager.default.createDirectory(
            at: userDir, withIntermediateDirectories: true)
        try writeClip("Real", to: userDir)
        try Data("garbage".utf8).write(
            to: userDir.appendingPathComponent("bad.threshanim"))

        let library = AnimationLibrary(directory: userDir, bundled: [])
        #expect(library.sources.map(\.id) == ["user"])
        #expect(library.items.count == 1)  // foreign/undecodable skipped
    }
}
