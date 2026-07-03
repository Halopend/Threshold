// HandOpStamper.swift — the spatial hand path (plan §4.3): hand-flagged warp
// ops get their geometry fields stamped from live hand joints each frame,
// CPU-side, right before encode. Because a hand effect is JUST an op in the
// stack, it composes with folds/kaleido, reorders, persists in scenes (as an
// authored op whose fields happen to be driven), and animates.
//
// Platform-neutral and pure so the stamping math is unit-tested on the Mac;
// only the caller (CompositorSession) is visionOS-specific.

import Foundation
import simd
import ThresholdShaderABI
import ThresholdShaderIR

public enum HandOpStamper {

    /// One hand's stamped geometry, in ROOM space (meters). nil components =
    /// that joint is not currently tracked.
    public struct Hand: Sendable {
        /// Attract-sphere center (palm).
        public var palm: SIMD3<Float>?
        /// Carve-capsule near end (wrist).
        public var wrist: SIMD3<Float>?
        /// Carve-capsule far end (elbow-ward forearm joint).
        public var forearm: SIMD3<Float>?

        public init(
            palm: SIMD3<Float>? = nil,
            wrist: SIMD3<Float>? = nil,
            forearm: SIMD3<Float>? = nil
        ) {
            self.palm = palm
            self.wrist = wrist
            self.forearm = forearm
        }

        public static let untracked = Hand()
    }

    /// Stamp every drive-flagged op from `right`/`left`, mapping room points
    /// through the SAME room→fractal transform the eyes use
    /// (CompositorViewMath.fractalPoint), so the effect sits exactly where
    /// the user sees their hand. Ops without a drive flag pass through
    /// untouched (they are ordinary slider-driven ops — plan §4.3's mandated
    /// fallback path). A drive-flagged op whose hand is NOT tracked has its
    /// strength zeroed for the frame: the effect vanishes rather than
    /// freezing at a stale pose.
    public static func stamp(
        _ ops: [ThreshWarpOp],
        right: Hand,
        left: Hand,
        base: ThreshFrameUniforms,
        anchorPosition: SIMD3<Float>,
        roomScale: Float = 1
    ) -> [ThreshWarpOp] {
        ops.map { op in
            let flags = WarpFlags(rawValue: op.flags)
            let drivenRight = flags.contains(.driveRightHand)
            let drivenLeft = flags.contains(.driveLeftHand)
            guard drivenRight || drivenLeft else { return op }
            let hand = drivenRight ? right : left

            func fractal(_ room: SIMD3<Float>) -> SIMD3<Float> {
                CompositorViewMath.fractalPoint(
                    room: room, base: base, anchorPosition: anchorPosition,
                    roomScale: roomScale)
            }

            var stamped = op
            switch op.kind {
            case UInt32(ThreshWarpKindHandAttract.rawValue):
                guard let palm = hand.palm else {
                    stamped.strength = 0
                    return stamped
                }
                let c = fractal(palm)
                stamped.a = SIMD4(c, op.a.w)  // a.w radius stays authored
            case UInt32(ThreshWarpKindForearmCarve.rawValue):
                guard let wrist = hand.wrist, let forearm = hand.forearm else {
                    stamped.strength = 0
                    return stamped
                }
                let a = fractal(wrist)
                let b = fractal(forearm)
                stamped.a = SIMD4(a, op.a.w)  // a.w radius stays authored
                stamped.b = SIMD4(b, op.b.w)  // b.w blend stays authored
            default:
                // A drive flag on a kind with no hand geometry is inert.
                break
            }
            return stamped
        }
    }
}
