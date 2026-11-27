// WarpRecipeCodecTests.swift — focused `.threshfx` persistence coverage.

import Foundation
import Testing

@testable import ThresholdCore

@Suite(".threshfx codec")
struct WarpRecipeCodecTests {
    private var sample: WarpRecipeEnvelope {
        WarpRecipeEnvelope(
            name: "Fold and twist",
            warpStack: [
                WarpOpDTO(
                    kind: 1, flags: 2, strength: 0.5,
                    a: [0, 1, 0, 0], b: [0, 0, 0, 0]),
                WarpOpDTO(
                    kind: 7, strength: 1,
                    a: [1, 2, 3, 4], b: [5, 6, 7, 8]),
            ])
    }

    @Test func roundTrips() throws {
        let decoded = try WarpRecipeCodec.decode(WarpRecipeCodec.encode(sample))
        #expect(decoded == sample)
    }

    @Test func encodeIsDeterministicAndSorted() throws {
        let first = try WarpRecipeCodec.encode(sample)
        #expect(first == (try WarpRecipeCodec.encode(sample)))

        let json = String(decoding: first, as: UTF8.self)
        let nameOffset = try #require(json.range(of: "\"name\""))
        let versionOffset = try #require(json.range(of: "\"version\""))
        let stackOffset = try #require(json.range(of: "\"warpStack\""))
        #expect(nameOffset.lowerBound < versionOffset.lowerBound)
        #expect(versionOffset.lowerBound < stackOffset.lowerBound)
    }

    @Test func optionalNameMayBeAbsent() throws {
        let decoded = try WarpRecipeCodec.decode(Data(
            #"{"version": 1, "warpStack": []}"#.utf8))
        #expect(decoded.name == nil)
        #expect(decoded.warpStack.isEmpty)
        #expect(!String(decoding: try WarpRecipeCodec.encode(decoded), as: UTF8.self)
            .contains("\"name\""))
    }

    @Test func unknownTopLevelKeysSurviveAndCannotReplaceKnownFields() throws {
        let json = """
            {"version": 1, "name": "Future recipe", "warpStack": [],
             "futureThing": {"nested": [1, 2], "enabled": true}}
            """
        var decoded = try WarpRecipeCodec.decode(Data(json.utf8))
        #expect(decoded.unknown["futureThing"] != nil)
        decoded.unknown["name"] = .string("collision")

        let reencoded = try WarpRecipeCodec.decode(WarpRecipeCodec.encode(decoded))
        #expect(reencoded.name == "Future recipe")
        #expect(reencoded.unknown["futureThing"] == decoded.unknown["futureThing"])
        #expect(reencoded.unknown["name"] == nil)
    }

    @Test func newerVersionIsRejected() {
        let json = #"{"version": 99, "warpStack": []}"#
        #expect(throws: SceneCodecError.unsupportedVersion(99)) {
            try WarpRecipeCodec.decode(Data(json.utf8))
        }
    }

    @Test func missingMigrationIsReported() {
        let json = #"{"version": 0, "warpStack": []}"#
        #expect(throws: SceneCodecError.missingMigration(from: 0)) {
            try WarpRecipeCodec.decode(Data(json.utf8))
        }
    }

    @Test func malformedDocumentsUseSceneCodecError() {
        let malformed = [
            #"{"warpStack": []}"#,
            #"{"version": 1}"#,
            #"{"version": 1.5, "warpStack": []}"#,
            #"{"version": -1, "warpStack": []}"#,
            #"{"version": 1e300, "warpStack": []}"#,
            #"{"version": 1, "warpStack": [{"kind": 1, "strength": 1, "a": [0], "b": [0, 0, 0, 0]}]}"#,
            #"[1, 2, 3]"#,
            "not json",
        ]
        for json in malformed {
            #expect(throws: SceneCodecError.self) {
                try WarpRecipeCodec.decode(Data(json.utf8))
            }
        }
    }
}
