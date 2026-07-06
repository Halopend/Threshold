// WorldGrab.swift — grab the fractal and move / turn / scale it in room
// space, adapted from BorgVR's ImmersiveInteraction (two-hand pinch grab).
//
// Threshold has NO model matrix: the room→fractal map is
// `fractalPoint(room) = basePos + baseRot.act(roomScale · (room − anchor))`
// (CompositorViewMath). A grab therefore does not move content — it
// re-expresses the OBSERVER. The grab is a room-space content transform
// G = T(t)·R·S(s) (uniform s); eyes and hand geometry are pushed through
// G⁻¹ before the existing map, folded into its existing arguments:
//
//     room′   = R⁻¹.act(room − t)        (rigid observer point)
//     anchor′ = s · anchor
//     scale′  = roomScale / s
//
// so `CompositorViewMath.viewUniforms` / `HandOpStamper.stamp` need NO
// signature changes, both backends (fragment + compute) inherit the grab
// through `views`, and the shader's depth mapping (`m.t / roomScale`) stays
// projection-consistent. Identity grab ⇒ bit-identical uniforms — the
// desktop shells and the golden gate never see this code path.
//
// Gesture semantics (BorgVR's, kept deliberately):
// - ONE active pinch: translate by the hand's displacement, rotate by the
//   hand's orientation delta ABOUT THE GRAB POINT (BorgVR rotates about its
//   volume origin; for room-filling fractal content the hand pivot is the
//   stable choice).
// - TWO active pinches: uniform scale about the two-hand midpoint from the
//   hand-separation RATIO (BorgVR uses an additive Δmeters form; the ratio
//   form is separation-independent — deviation noted).
// - After a two-hand phase, the surviving single hand does NOT translate
//   until fully released (BorgVR's `doubleEventIsRunning` latch).
// - Release commits; the next pinch composes on top.
//
// Threading: events arrive on whatever queue delivers
// `LayerRenderer.onSpatialEvent`; the render loop reads `current()` once per
// frame — all state sits behind a Mutex (same Synchronization toolbox as the
// rest of this target).

import Foundation
import simd
import Synchronization

// MARK: - WorldGrabTransform

/// A room-space content transform: scale `s` about the origin, then rotate
/// `rotation`, then translate `translation` (M = T·R·S, uniform scale).
public struct WorldGrabTransform: Sendable, Equatable {
    public var scale: Float
    public var rotation: simd_quatf
    public var translation: SIMD3<Float>

    public init(
        scale: Float = 1,
        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        translation: SIMD3<Float> = .zero
    ) {
        self.scale = scale
        self.rotation = rotation
        self.translation = translation
    }

    public static let identity = WorldGrabTransform()

    public var isIdentity: Bool {
        scale == 1 && translation == .zero
            && rotation.vector == SIMD4(0, 0, 0, 1)
    }

    /// Where a room point lands after the content transform (content-side,
    /// for tests and future room-collision features).
    public func contentPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        rotation.act(scale * p) + translation
    }

    /// The RIGID part of G⁻¹ applied to a room point — the observer map.
    /// The scale part is folded into the map's `roomScale`/`anchor` instead
    /// (header algebra), so directions and eye bases stay unit-length.
    public func observerPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        rotation.inverse.act(p - translation)
    }

    /// The rigid observer map as a matrix: `[R⁻¹ | −R⁻¹·t]` — left-multiply
    /// onto `eyeToRoom` so the eye pose (position AND orientation) is
    /// re-expressed in grab-adjusted room space.
    public var observerMatrix: simd_float4x4 {
        var m = simd_float4x4(rotation.inverse)
        let p = rotation.inverse.act(-translation)
        m.columns.3 = SIMD4(p, 1)
        return m
    }

    // MARK: Composition (all pivots in room space)

    public func translated(by delta: SIMD3<Float>) -> WorldGrabTransform {
        var g = self
        g.translation += delta
        return g
    }

    /// Rotate the content by `delta` about the room point `pivot`.
    public func rotated(
        by delta: simd_quatf, about pivot: SIMD3<Float>
    ) -> WorldGrabTransform {
        WorldGrabTransform(
            scale: scale,
            rotation: simd_normalize(delta * rotation),
            translation: pivot + delta.act(translation - pivot))
    }

    /// Scale the content by `factor` about the room point `pivot`.
    public func scaled(
        by factor: Float, about pivot: SIMD3<Float>
    ) -> WorldGrabTransform {
        WorldGrabTransform(
            scale: scale * factor,
            rotation: rotation,
            translation: pivot + factor * (translation - pivot))
    }
}

// MARK: - WorldGrabSession

/// The grab state machine. Feed it this frame's active pinch events
/// (`handle`); read the composed transform once per frame (`current`).
public final class WorldGrabSession: Sendable {

    /// One pinch, platform-neutral (the visionOS adapter below maps
    /// SpatialEventCollection onto these — tests drive them directly).
    public struct GrabEvent: Sendable {
        public enum Phase: Sendable { case active, ended }
        public var phase: Phase
        public var position: SIMD3<Float>
        public var rotation: simd_quatf?

        public init(
            phase: Phase, position: SIMD3<Float>,
            rotation: simd_quatf? = nil
        ) {
            self.phase = phase
            self.position = position
            self.rotation = rotation
        }

        /// Ingress guard: a NaN/∞ pose must never reach the anchors — one
        /// poisoned engage position corrupts every subsequent live transform.
        var isFinite: Bool {
            position.x.isFinite && position.y.isFinite && position.z.isFinite
                && (rotation.map {
                    $0.vector.x.isFinite && $0.vector.y.isFinite
                        && $0.vector.z.isFinite && $0.vector.w.isFinite
                } ?? true)
        }
    }

    /// UserDefaults key for the Settings ▸ Input toggle. Read per event
    /// batch, so flipping it applies live; turning it OFF also resets the
    /// transform — the escape hatch when a grab leaves you somewhere odd.
    public static let enabledKey = "threshold.input.worldGrab"

    public static var enabledInDefaults: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    private struct State {
        /// Committed transform (BorgVR's `lastModelTransform`).
        var committed = WorldGrabTransform.identity
        /// Live transform (committed ∘ in-flight gesture).
        var live = WorldGrabTransform.identity
        /// One-hand anchor: (hand position, hand orientation) at engage.
        var singleStart: (SIMD3<Float>, simd_quatf)?
        /// Two-hand anchor: (separation, midpoint) at engage.
        var doubleStart: (distance: Float, midpoint: SIMD3<Float>)?
        /// BorgVR's `doubleEventIsRunning`: after a two-hand phase the
        /// surviving hand must fully release before one-hand drag resumes.
        var doubleLatch = false
    }

    private let state = Mutex<State>(State())

    /// Scale clamps: the committed scale stays within this range (matches
    /// the spirit of the dolly clamp — you can always find your way back).
    static let minScale: Float = 0.05
    static let maxScale: Float = 20
    /// Two hands closer than this at engage give no stable ratio.
    static let minEngageSeparation: Float = 0.05

    public init() {}

    /// The transform the render loop folds into this frame's view math.
    public func current() -> WorldGrabTransform {
        state.withLock { $0.live }
    }

    /// True while at least one pinch is actively grabbing (HUD/debug).
    public func isGrabbing() -> Bool {
        state.withLock { $0.singleStart != nil || $0.doubleStart != nil }
    }

    public func reset() {
        state.withLock { $0 = State() }
    }

    /// Feed one delivery of pinch events (BorgVR handleSpatialEvents shape:
    /// 1 active event = move/turn, 2 = scale).
    public func handle(_ events: [GrabEvent]) {
        guard Self.enabledInDefaults else {
            // Toggle off mid-flight: drop any gesture AND the transform —
            // the documented escape hatch.
            state.withLock { s in
                if !(s.live.isIdentity && s.committed.isIdentity)
                    || s.singleStart != nil || s.doubleStart != nil {
                    s = State()
                }
            }
            return
        }
        // Non-finite active events are dropped (an event carrying garbage is
        // tracking failure, not intent) — the arms below then see the same
        // shape as a release, which commits: the safe decay.
        let active = events.filter { $0.phase == .active && $0.isFinite }
        state.withLock { s in
            switch active.count {
            case 2:
                handleScale(active[0], active[1], &s)
            case 1:
                handleMoveTurn(active[0], &s)
            default:
                commit(&s)
            }
            // Any delivery whose events are all ended clears the two-hand
            // latch (full release — BorgVR resets it in the .ended arms).
            if active.isEmpty { s.doubleLatch = false }
        }
    }

    // MARK: Gesture arms (BorgVR ImmersiveInteraction, re-expressed)

    private func handleMoveTurn(_ e: GrabEvent, _ s: inout State) {
        // Two-hand phase decayed to one hand: hold until full release.
        if s.doubleLatch {
            commit(&s)
            return
        }
        let rot = e.rotation ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        guard let (p0, q0) = s.singleStart else {
            // Engage: a one-hand grab starts here; a live two-hand grab
            // (if any) commits first.
            if s.doubleStart != nil { commit(&s) }
            s.singleStart = (e.position, rot)
            return
        }
        let deltaR = simd_normalize(rot * q0.inverse)
        s.live = s.committed
            .rotated(by: deltaR, about: p0)
            .translated(by: e.position - p0)
    }

    private func handleScale(_ a: GrabEvent, _ b: GrabEvent, _ s: inout State) {
        // Entering two-hand: any one-hand gesture commits first, and the
        // latch arms (BorgVR sets doubleEventIsRunning on entry).
        if s.singleStart != nil { commit(&s) }
        s.doubleLatch = true

        let midpoint = (a.position + b.position) * 0.5
        let distance = simd_distance(a.position, b.position)
        guard let start = s.doubleStart else {
            if distance >= Self.minEngageSeparation {
                s.doubleStart = (distance, midpoint)
            }
            return
        }
        let ratio = distance / max(start.distance, Self.minEngageSeparation)
        let target = s.committed.scale * ratio
        let clamped = min(max(target, Self.minScale), Self.maxScale)
        s.live = s.committed.scaled(
            by: clamped / s.committed.scale, about: start.midpoint)
    }

    /// Fold the live gesture into the committed transform and drop anchors
    /// (BorgVR's `.ended` bookkeeping).
    private func commit(_ s: inout State) {
        s.committed = s.live
        s.singleStart = nil
        s.doubleStart = nil
    }
}

// MARK: - visionOS adapter

#if os(visionOS)

import SwiftUI
import Spatial

extension WorldGrabSession {
    /// Map a Compositor spatial-event delivery onto the grab machine.
    /// `LayerRenderer.onSpatialEvent` poses are already in the layer's
    /// origin space — the SAME room space `originFromDevice` lives in — so
    /// unlike BorgVR (which re-expresses poses under its world anchor) no
    /// extra transform applies here.
    public func handle(_ events: SpatialEventCollection) {
        handle(events.compactMap { event -> GrabEvent? in
            let phase: GrabEvent.Phase =
                switch event.phase {
                case .active: .active
                default: .ended
                }
            guard let pose = event.inputDevicePose?.pose3D else {
                // No pose on an ACTIVE event: dropping it (rather than
                // fabricating a grab at the room origin, which teleported
                // content by the full hand-to-origin distance) reads as a
                // one-frame release — the machine commits and re-engages.
                // Ended events don't need a pose to count as a release.
                return phase == .ended
                    ? GrabEvent(phase: .ended, position: .zero) : nil
            }
            return GrabEvent(
                phase: phase,
                position: SIMD3<Float>(pose.position.vector),
                rotation: simd_quatf(
                    vector: SIMD4<Float>(pose.rotation.quaternion.vector)))
        })
    }
}

#endif  // os(visionOS)

/*
 Portions adapted from BorgVR (ImmersiveInteraction.swift),
 https://github.com/JensDerKrueger/BorgVR

 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
