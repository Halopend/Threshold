// PlacementViewMathTests.swift — the gesture RoomPlacement (G) composed into
// the room→fractal view math. The defining equivalence: moving the hologram
// by G ≡ mapping every room-space viewer through G⁻¹, so content that
// appeared at room point x must appear at G(x). No GPU required.

import Foundation
import simd
import Testing
import ThresholdCore
import ThresholdShaderABI
import ThresholdShaderIR
@testable import ThresholdRender

@Suite("Placement view math")
struct PlacementViewMathTests {

    /// A representative non-identity base pose (position + orientation).
    private func baseUniforms() -> ThreshFrameUniforms {
        var uniforms = ThreshFrameUniforms()
        let q = simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3(0.2, 1, 0.1)))
        uniforms.camPosFov = SIMD4(0.4, 1.2, 3.0, tan(Float.pi / 6))
        uniforms.camQuat = q.vector
        return uniforms
    }

    private func somePlacement() -> RoomPlacement {
        RoomPlacement(
            position: SIMD3(0.25, -0.1, 0.6),
            rotation: simd_quatf(angle: 0.8, axis: simd_normalize(SIMD3(0, 1, 0.3))),
            scale: 1.7)
    }

    @Test func identityPlacementIsBitIdentical() {
        let base = baseUniforms()
        let anchor = SIMD3<Float>(0.1, 1.5, 0.2)
        let proj = CompositorViewMath.pinholeProjection(fovTan: 0.5, aspect: 1.2)
        var eye = matrix_identity_float4x4
        eye.columns.3 = SIMD4(0.3, 1.6, 0.1, 1)

        let without = CompositorViewMath.viewUniforms(
            projection: proj, eyeToRoom: eye, anchorPosition: anchor, base: base)
        let with = CompositorViewMath.viewUniforms(
            projection: proj, eyeToRoom: eye, anchorPosition: anchor, base: base,
            placement: .identity)
        #expect(without.originScale == with.originScale)
        #expect(without.orient == with.orient)
    }

    @Test func contentAtXAppearsAtGofX() {
        // The room point G(x) must see the world content the identity map
        // showed at x: fractalPoint(G.map(x), placement: G) ==
        // fractalPoint(x, identity).
        let base = baseUniforms()
        let anchor = SIMD3<Float>(0, 1.5, 0)
        let g = somePlacement()
        var rng = SplitMix64(seed: 0x91AC_9E37)
        for _ in 0..<20 {
            let x = rng.point(in: -2...2)
            let atIdentity = CompositorViewMath.fractalPoint(
                room: x, base: base, anchorPosition: anchor)
            let atMoved = CompositorViewMath.fractalPoint(
                room: g.map(x), base: base, anchorPosition: anchor, placement: g)
            #expect(simd_length(atMoved - atIdentity) < 1e-4)
        }
    }

    @Test func orientComposesThePlacementRotation() {
        let base = baseUniforms()
        let g = somePlacement()
        let proj = CompositorViewMath.pinholeProjection(fovTan: 0.5, aspect: 1)
        let eyeQ = simd_quatf(angle: 0.4, axis: simd_normalize(SIMD3(1, 0.2, 0)))
        var eye = matrix_float4x4(eyeQ)
        eye.columns.3 = SIMD4(0.1, 1.4, 0.3, 1)

        let view = CompositorViewMath.viewUniforms(
            projection: proj, eyeToRoom: eye, anchorPosition: .zero, base: base,
            placement: g)
        let baseRot = simd_quatf(vector: base.camQuat)
        let expected = simd_normalize(baseRot * g.rotation.inverse * eyeQ)
        // Same rotation up to quaternion sign.
        let d = min(
            simd_length(view.orient - expected.vector),
            simd_length(view.orient + expected.vector))
        #expect(d < 1e-4)
    }

    @Test func originScaleWTracksPlacementScale() {
        let base = baseUniforms()
        let proj = CompositorViewMath.pinholeProjection(fovTan: 0.5, aspect: 1)
        let eye = matrix_identity_float4x4
        let g = RoomPlacement(scale: 4)
        let view = CompositorViewMath.viewUniforms(
            projection: proj, eyeToRoom: eye, anchorPosition: .zero, base: base,
            roomScale: 1, placement: g)
        #expect(abs(view.originScale.w - 0.25) < 1e-6)
    }

    @Test func bubbleRadiusCompensatesForPlacementScale() {
        var params = [Float](repeating: 0, count: Int(THRESH_SLOT_ENGINE_COUNT) + 4)
        params[Int(THRESH_SLOT_BUBBLE_RADIUS)] = 0.8
        params[Int(THRESH_SLOT_BUBBLE_ENABLED)] = 1

        // Identity: untouched.
        let same = CompositorViewMath.bubbleCompensatedParams(params, placement: .identity)
        #expect(same == params)

        // Hologram scaled ×2: world radius halves so the physical clearance
        // stays 0.8 m.
        let g = RoomPlacement(scale: 2)
        let scaled = CompositorViewMath.bubbleCompensatedParams(params, placement: g)
        #expect(abs(scaled[Int(THRESH_SLOT_BUBBLE_RADIUS)] - 0.4) < 1e-6)
        // Every other slot untouched.
        for i in scaled.indices where i != Int(THRESH_SLOT_BUBBLE_RADIUS) {
            #expect(scaled[i] == params[i])
        }

        // Short array: safe no-op.
        let short: [Float] = [1, 2]
        #expect(CompositorViewMath.bubbleCompensatedParams(short, placement: g) == short)
    }

    @Test func handOpsStampThroughThePlacement() {
        let base = baseUniforms()
        let anchor = SIMD3<Float>(0, 1.5, 0)
        let g = somePlacement()
        let palm = SIMD3<Float>(0.2, 1.1, -0.4)

        var op = ThreshWarpOp()
        op.kind = UInt32(ThreshWarpKindHandAttract.rawValue)
        op.flags = WarpFlags.driveRightHand.rawValue
        op.strength = 1
        op.a = SIMD4(0, 0, 0, 0.3)

        let stamped = HandOpStamper.stamp(
            [op], right: .init(palm: palm), left: .untracked,
            base: base, anchorPosition: anchor, placement: g)
        let expected = CompositorViewMath.fractalPoint(
            room: palm, base: base, anchorPosition: anchor, placement: g)
        #expect(simd_length(SIMD3(stamped[0].a.x, stamped[0].a.y, stamped[0].a.z) - expected) < 1e-5)
        #expect(stamped[0].a.w == 0.3)  // authored radius untouched
    }
}
