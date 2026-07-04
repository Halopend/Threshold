// HandGeometry.swift — pure joint→strength math for gesture detection, kept
// platform-free so the thresholds are unit-tested without a device. The
// visionOS tracker extracts ARKit joint world-positions and calls these; all
// distances are meters. Thresholds default to the legacy app's tuned values
// (HandTrackingTypes.swift) but are overridable per finger.

import simd

public enum HandGeometry {
    /// Linear proximity ramp: `1` at/under `on`, `0` at/over `off`, lerp between
    /// (hysteresis lives in the stateful tracker, not here).
    public static func proximity(_ distance: Float, on: Float, off: Float) -> Float {
        guard off > on else { return distance <= on ? 1 : 0 }
        return max(0, min(1, (off - distance) / (off - on)))
    }

    /// Pinch strength between thumb tip and a finger tip. Legacy: full at 2 cm,
    /// released by 5 cm.
    public static func pinchStrength(
        thumb: SIMD3<Float>, finger: SIMD3<Float>,
        on: Float = 0.02, off: Float = 0.05
    ) -> Float {
        proximity(simd_distance(thumb, finger), on: on, off: off)
    }

    /// Finger-to-palm touch strength (the palm drop-points). Defaults are the
    /// index/middle legacy pair; ring/pinky/thumb pass their own.
    public static func palmTouchStrength(
        fingerTip: SIMD3<Float>, palm: SIMD3<Float>,
        touch: Float = 0.038, away: Float = 0.115
    ) -> Float {
        proximity(simd_distance(fingerTip, palm), on: touch, off: away)
    }

    /// Fist closure 0…1: driven by the LEAST-curled non-thumb finger, so all
    /// four must curl for a full fist. Legacy uses palm-center distance.
    public static func fistClosure(
        fingerTips: [SIMD3<Float>], palm: SIMD3<Float>,
        closed: Float = 0.045, open: Float = 0.11
    ) -> Float {
        guard let farthest = fingerTips.map({ simd_distance($0, palm) }).max() else { return 0 }
        return proximity(farthest, on: closed, off: open)
    }

    /// Legacy per-finger palm-touch thresholds `(touch, away)` in meters.
    public static func palmThresholds(for finger: GestureFinger) -> (touch: Float, away: Float) {
        switch finger {
        case .index:  return (0.038, 0.115)
        case .middle: return (0.038, 0.115)
        case .ring:   return (0.045, 0.11)
        case .pinky:  return (0.032, 0.10)
        }
    }
}
