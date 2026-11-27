import Foundation
import Testing

@testable import ThresholdCore

@Suite("Post-process persistence")
struct PostProcessPersistenceTests {
    @Test("Known kinds have stable, distinct raw values and valid defaults")
    func knownKindDefaults() {
        let expected: [PostProcessKind: UInt32] = [
            .bloom: 1,
            .gaussianBlur: 2,
            .sharpen: 3,
            .vignette: 4,
            .chromaticAberration: 5,
            .filmGrain: 6,
            .colorGrade: 7,
            .posterize: 8,
            .invert: 9,
        ]
        #expect(PostProcessKind.allCases.count == expected.count)
        #expect(Set(PostProcessKind.allCases.map(\.rawValue)).count == expected.count)

        for kind in PostProcessKind.allCases {
            #expect(kind.rawValue == expected[kind])
            let id = UUID()
            let filter = PostProcessFilterDTO.makeDefault(kind, id: id)
            #expect(filter.id == id)
            #expect(filter.kind == kind.rawValue)
            #expect(filter.knownKind == kind)
            #expect(filter.enabled)
            #expect(filter.strength.isFinite)
            #expect(filter.a.count == 4)
            #expect(filter.b.count == 4)
            #expect(filter.a.allSatisfy { $0.isFinite })
            #expect(filter.b.allSatisfy { $0.isFinite })
        }
    }

    @Test("Unknown raw kinds decode and round-trip without loss")
    func unknownKindRoundTrip() throws {
        let original = PostProcessFilterDTO(
            id: UUID(), kind: 4_000_000_000, enabled: false, strength: 0.625,
            a: [1, 2, 3, 4], b: [5, 6, 7, 8])
        let decoded = try JSONDecoder().decode(
            PostProcessFilterDTO.self,
            from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.knownKind == nil)
    }

    @Test("Malformed filter payload widths are rejected")
    func rejectsMalformedPayloadWidths() {
        let bad = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","kind":1,"enabled":true,"strength":1,"a":[1,2,3],"b":[0,0,0,0]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PostProcessFilterDTO.self, from: bad)
        }
    }

    @Test("Scene round-trip preserves filter identity and exact order")
    func sceneRoundTripPreservesOrder() throws {
        var bloom = PostProcessFilterDTO.makeDefault(
            .bloom, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        bloom.strength = 0.75
        let unknown = PostProcessFilterDTO(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            kind: 999, enabled: false, strength: 0.25,
            a: [9, 8, 7, 6], b: [5, 4, 3, 2])
        let invert = PostProcessFilterDTO.makeDefault(
            .invert, id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let stack = [bloom, unknown, invert]
        let scene = SceneEnvelope(
            version: SceneCodec.currentVersion,
            fractalTypeKey: "mandelbulb",
            postProcessStack: stack)

        let decoded = try SceneCodec.decode(SceneCodec.encode(scene))
        #expect(decoded.postProcessStack == stack)
        #expect(decoded == scene)
    }

    @Test("Scenes predating the stack decode with an empty stack")
    func oldSceneDefaultsToEmptyStack() throws {
        let old = Data(
            #"{"version":1,"fractalTypeKey":"mandelbulb","params":{},"warpStack":[],"camera":{"position":[0,0,3],"orientation":[0,0,0,1],"fovYRadians":1.0471976}}"#.utf8)
        let decoded = try SceneCodec.decode(old)
        #expect(decoded.postProcessStack.isEmpty)

        let reencoded = String(decoding: try SceneCodec.encode(decoded), as: UTF8.self)
        #expect(reencoded.contains("\"postProcessStack\""))
    }
}
