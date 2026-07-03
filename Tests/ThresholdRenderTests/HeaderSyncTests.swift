// HeaderSyncTests.swift — the bundled ABI header copy must be byte-identical
// to the canonical header, or the runtime-compiled MSL and the Swift structs
// silently drift (this is the whole point of the single-source-of-truth rule).

import Foundation
import Testing

@Suite("ABI header sync")
struct HeaderSyncTests {

    private var repoRoot: URL {
        // …/Tests/ThresholdRenderTests/HeaderSyncTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ThresholdRenderTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    @Test func bundledHeaderIsByteIdenticalToCanonical() throws {
        let canonical = repoRoot
            .appendingPathComponent("Sources/ThresholdShaderABI/include/ThresholdShaderABI.h")
        let bundledCopy = repoRoot
            .appendingPathComponent("Sources/ThresholdRender/MSL/ThresholdShaderABI.h")

        let canonicalData = try Data(contentsOf: canonical)
        let copyData = try Data(contentsOf: bundledCopy)
        #expect(!canonicalData.isEmpty)
        #expect(canonicalData == copyData,
                "MSL/ThresholdShaderABI.h has drifted from the canonical ABI header — re-copy it byte-for-byte")
    }
}
