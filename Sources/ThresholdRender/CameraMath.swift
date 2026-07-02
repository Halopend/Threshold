// CameraMath.swift — look-at quaternion + ThreshFrameUniforms builder.
//
// The camera convention (docs/op-semantics.md "March defaults"): the camera
// looks down -Z in its local frame; `camQuat` rotates local into world.
// The shader-side quatRotate implements v' = q·v·q⁻¹ exactly as simd_act
// does — CameraMathTests pins that equivalence.

import Foundation
import simd
import ThresholdShaderABI

public enum CameraMath {

    /// Quaternion rotating the camera's local frame (looking down -Z, +Y up)
    /// into world space so that -Z maps onto normalize(target - position).
    /// Degenerate `up` (parallel to the view direction, or zero) falls back
    /// to a deterministic substitute axis.
    public static func lookAtQuaternion(position: SIMD3<Float>,
                                        target: SIMD3<Float>,
                                        up: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_quatf {
        let forward = simd_normalize(target - position)
        var upN = up
        let upLength = simd_length(upN)
        if upLength < 1e-6 {
            upN = SIMD3(0, 1, 0)
        } else {
            upN /= upLength
        }
        if abs(simd_dot(forward, upN)) > 0.9995 {
            upN = abs(forward.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        }
        let right = simd_normalize(simd_cross(forward, upN))
        let trueUp = simd_cross(right, forward)
        // Columns are the world-space images of camera-local X, Y, Z.
        let m = simd_float3x3(columns: (right, trueUp, -forward))
        return simd_normalize(simd_quatf(m))
    }

    /// Builds the 64-byte frame uniforms. `paramCount`/`deParamOffset` follow
    /// the ParamTableLayout convention (DE slice at the table's tail,
    /// iterations last).
    public static func makeUniforms(
        cameraPos: SIMD3<Float>,
        target: SIMD3<Float>,
        up: SIMD3<Float> = SIMD3(0, 1, 0),
        fovYRadians: Float,
        time: Float = 0,
        epsilonBase: Float = 1e-3,
        modelScale: Float = 1,
        lodScale: Float = 1,
        opCount: Int,
        deIndex: Int,
        paramCount: Int,
        deParamOffset: Int
    ) -> ThreshFrameUniforms {
        precondition(opCount >= 0 && deIndex >= 0 && paramCount >= 0 && deParamOffset >= 0)
        let q = lookAtQuaternion(position: cameraPos, target: target, up: up)
        var uniforms = ThreshFrameUniforms()
        uniforms.camPosFov = SIMD4(cameraPos, tan(fovYRadians * 0.5))
        uniforms.camQuat = q.vector // (ix, iy, iz, r) = header's (x, y, z, w)
        uniforms.scaleCtx = SIMD4(time, epsilonBase, modelScale, lodScale)
        uniforms.meta = SIMD4<UInt32>(UInt32(opCount), UInt32(deIndex),
                                      UInt32(paramCount), UInt32(deParamOffset))
        return uniforms
    }
}
