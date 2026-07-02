// CameraMathTests.swift — the look-at quaternion and the uniforms builder.
// No GPU required.

import Foundation
import simd
import Testing
import ThresholdShaderABI
@testable import ThresholdRender

/// Mirror of the MSL quatRotate (v' = v + 2·cross(q.xyz, cross(q.xyz, v) + q.w·v))
/// so the shader's rotation convention is pinned against simd_act.
private func shaderQuatRotate(_ q: SIMD4<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
    let im = SIMD3(q.x, q.y, q.z)
    return v + 2 * simd_cross(im, simd_cross(im, v) + q.w * v)
}

@Suite("Camera math")
struct CameraMathTests {

    @Test func canonicalCameraIsIdentity() {
        let q = CameraMath.lookAtQuaternion(position: SIMD3(0, 0, 3), target: .zero)
        let forward = simd_act(q, SIMD3<Float>(0, 0, -1))
        #expect(simd_length(forward - SIMD3(0, 0, -1)) < 1e-5)
        let up = simd_act(q, SIMD3<Float>(0, 1, 0))
        #expect(simd_length(up - SIMD3(0, 1, 0)) < 1e-5)
    }

    @Test func lookAtRotatesMinusZOntoViewDirection() {
        var rng = SplitMix64(seed: 0xCA13_57)
        for _ in 0..<60 {
            let pos = rng.point(in: -5...5)
            var target = rng.point(in: -5...5)
            if simd_length(target - pos) < 1e-2 { target.x += 1 }
            let q = CameraMath.lookAtQuaternion(position: pos, target: target)
            let expected = simd_normalize(target - pos)

            #expect(abs(simd_length(q.vector) - 1) < 1e-5, "unit quaternion")
            let forward = simd_act(q, SIMD3<Float>(0, 0, -1))
            #expect(simd_length(forward - expected) < 1e-4,
                    "act(q, -Z) must equal normalize(target - pos); pos \(pos) target \(target)")

            // Camera +Y must stay in the up half-space when not degenerate.
            if abs(simd_dot(expected, SIMD3(0, 1, 0))) < 0.99 {
                let camUp = simd_act(q, SIMD3<Float>(0, 1, 0))
                #expect(simd_dot(camUp, SIMD3(0, 1, 0)) > 0)
            }
        }
    }

    @Test func degenerateUpFallsBackDeterministically() {
        // Looking straight up with up = +Y: parallel — needs the fallback.
        let q = CameraMath.lookAtQuaternion(position: .zero, target: SIMD3(0, 5, 0))
        let forward = simd_act(q, SIMD3<Float>(0, 0, -1))
        #expect(simd_length(forward - SIMD3(0, 1, 0)) < 1e-4)
        #expect(abs(simd_length(q.vector) - 1) < 1e-5)
    }

    @Test func shaderRotationFormulaMatchesSimdAct() {
        var rng = SplitMix64(seed: 0xBEEF)
        for _ in 0..<60 {
            let pos = rng.point(in: -4...4)
            var target = rng.point(in: -4...4)
            if simd_length(target - pos) < 1e-2 { target.z -= 1 }
            let q = CameraMath.lookAtQuaternion(position: pos, target: target)
            let v = rng.unitVector()
            let viaSimd = simd_act(q, v)
            let viaShaderFormula = shaderQuatRotate(q.vector, v)
            #expect(simd_length(viaSimd - viaShaderFormula) < 1e-5)
        }
    }

    @Test func uniformsBuilderPacksTheContract() {
        let uniforms = CameraMath.makeUniforms(
            cameraPos: SIMD3(1, 2, 3), target: .zero, fovYRadians: .pi / 3,
            time: 4.5, epsilonBase: 2e-3, modelScale: 0.5, lodScale: 2,
            opCount: 3, deIndex: 1, paramCount: 21, deParamOffset: 16)
        #expect(uniforms.camPosFov.x == 1 && uniforms.camPosFov.y == 2 && uniforms.camPosFov.z == 3)
        #expect(abs(uniforms.camPosFov.w - tan(Float.pi / 6)) < 1e-6)
        #expect(uniforms.scaleCtx == SIMD4(4.5, 2e-3, 0.5, 2))
        #expect(uniforms.meta == SIMD4<UInt32>(3, 1, 21, 16))
    }
}
