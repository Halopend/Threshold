// ThresholdFile.swift — the one open-a-file entry point (plan §7.4:
// "each is a sub-envelope of the scene format, so loaders share one code
// path"). Pure classification + decode; what happens next (scene apply,
// embedded-DE compile, clip load) is the caller's platform wiring.
//
// `.threshmp` (binding maps) and `.threshfx` (warp recipes) join here as
// their rebuild codecs land.

import Foundation

public enum ThresholdFile: Sendable {
    case scene(SceneEnvelope)
    case animation(AnimationEnvelope)

    public enum OpenError: Error, Equatable, CustomStringConvertible {
        /// Extension is not one this build can open. Payload = the extension.
        case unsupportedType(String)

        public var description: String {
            switch self {
            case .unsupportedType(let ext):
                return "cannot open .\(ext) files (supported: \(ThresholdFile.supportedExtensions.map { ".\($0)" }.joined(separator: ", ")))"
            }
        }
    }

    /// Extensions this build opens, lowercase, in UI-listing order.
    public static let supportedExtensions = ["threshscene", "threshanim"]

    /// Decode a file by its name's extension. Codec errors (bad JSON, version
    /// gaps) propagate as-is — they carry the diagnostics the UI shows.
    public static func decode(_ data: Data, filename: String) throws -> ThresholdFile {
        let parts = filename.split(separator: ".")
        let ext = parts.count > 1 ? parts.last!.lowercased() : ""
        switch ext {
        case "threshscene":
            return .scene(try SceneCodec.decode(data))
        case "threshanim":
            return .animation(try AnimationCodec.decode(data))
        default:
            throw OpenError.unsupportedType(ext)
        }
    }
}
