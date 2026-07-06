// HandFrame.swift — a platform-free snapshot of one tracked hand: the joint
// positions gesture detection consumes, with per-joint confidence. This is
// the seam between ARKit and the gesture engine (adversarial plan Phase 0):
// the visionOS tracker maps HandAnchor → HandFrame, tests and replay corpora
// build HandFrames directly, and everything downstream is deterministic and
// unit-testable on any platform.
//
// Ingress hygiene lives HERE, at the single choke point: `position(_:)`
// returns nil for missing joints, sub-threshold confidence, AND non-finite
// values — a NaN joint with isTracked=true has poisoned gesture state before
// (see the HandTracker worldJoint history), so garbage is dropped where the
// data enters, not policed at every use site.
//
// Codable so recorded sessions serialize to JSONL (`HandFrameRecord`) for
// the replay/adversarial test harness.

import Foundation
import simd

// MARK: - HandFrame

public struct HandFrame: Sendable, Equatable, Codable {
    /// The joints gesture detection reads. Raw values are the JSONL corpus
    /// vocabulary — renaming a case invalidates recorded corpora.
    public enum Joint: String, Sendable, CaseIterable, Codable {
        case wrist
        case thumbTip
        case indexTip
        case middleTip
        case ringTip
        case littleTip
        /// Palm center (ARKit: middleFingerMetacarpal).
        case palmCenter
        /// Forearm point (ARKit: forearmArm) — carve capsule far end.
        case forearm
    }

    public struct Sample: Sendable, Equatable, Codable {
        /// World-space position, meters.
        public var position: SIMD3<Float>
        /// 0…1. ARKit's binary isTracked maps to 1/0; richer sources (or
        /// adversarial mutators) can supply intermediate values.
        public var confidence: Float

        public init(position: SIMD3<Float>, confidence: Float = 1) {
            self.position = position
            self.confidence = confidence
        }
    }

    /// Confidence below which a joint is treated as absent.
    public static let defaultMinConfidence: Float = 0.5

    private var samples: [Joint: Sample]

    public init() {
        samples = [:]
    }

    public init(_ samples: [Joint: Sample]) {
        self.samples = samples
    }

    /// Convenience for tests/corpora: full-confidence joints.
    public init(positions: [Joint: SIMD3<Float>]) {
        samples = positions.mapValues { Sample(position: $0) }
    }

    public mutating func set(
        _ joint: Joint, position: SIMD3<Float>, confidence: Float = 1
    ) {
        samples[joint] = Sample(position: position, confidence: confidence)
    }

    /// The raw sample, ungated (corpus tooling; detection should use
    /// `position(_:)`).
    public func sample(_ joint: Joint) -> Sample? {
        samples[joint]
    }

    /// The gated read every consumer goes through: nil when the joint is
    /// missing, below the confidence floor, or non-finite.
    public func position(
        _ joint: Joint, minConfidence: Float = HandFrame.defaultMinConfidence
    ) -> SIMD3<Float>? {
        guard let s = samples[joint],
              s.confidence >= minConfidence,
              s.confidence.isFinite,
              s.position.x.isFinite, s.position.y.isFinite, s.position.z.isFinite
        else { return nil }
        return s.position
    }
}

// MARK: - HandFrameRecord (JSONL replay corpus)

/// One line of a recorded gesture session: session-clock time plus both
/// hands (nil = hand not tracked that frame). Encode one record per line
/// (JSONL) so corpora stream and diff cleanly.
public struct HandFrameRecord: Sendable, Equatable, Codable {
    public var time: Double
    public var left: HandFrame?
    public var right: HandFrame?

    public init(time: Double, left: HandFrame? = nil, right: HandFrame? = nil) {
        self.time = time
        self.left = left
        self.right = right
    }

    /// Decode a JSONL corpus (one JSON record per non-empty line).
    public static func load(jsonl: String) throws -> [HandFrameRecord] {
        let decoder = JSONDecoder()
        return try jsonl.split(separator: "\n")
            .map { line in
                try decoder.decode(
                    HandFrameRecord.self, from: Data(line.utf8))
            }
    }

    /// Encode records as JSONL (stable key order for diffable corpora).
    public static func dump(_ records: [HandFrameRecord]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try records
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
    }
}
