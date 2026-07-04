// ABILayoutTests.swift — the CPU-side half of the ABI contract checks
// (ADR-002, plan §9). The header's _Static_asserts fire at compile time on
// both compilers; these tests pin the Swift-imported layout and cross-check
// the constants that ThresholdCore mirrors without importing the header.

import Testing
import ThresholdCore
import ThresholdShaderABI
@testable import ThresholdShaderIR

@Suite("ABI layout")
struct ABILayoutTests {
    @Test("ThreshWarpOp is exactly 48 bytes, 16-aligned, stride == size")
    func warpOpLayout() {
        #expect(MemoryLayout<ThreshWarpOp>.size == 48)
        #expect(MemoryLayout<ThreshWarpOp>.stride == 48)
        #expect(MemoryLayout<ThreshWarpOp>.alignment == 16)
    }

    @Test("ThreshWarpOp field offsets: kind 0, flags 4, strength 8, a 16, b 32")
    func warpOpOffsets() {
        #expect(MemoryLayout<ThreshWarpOp>.offset(of: \.kind) == 0)
        #expect(MemoryLayout<ThreshWarpOp>.offset(of: \.flags) == 4)
        #expect(MemoryLayout<ThreshWarpOp>.offset(of: \.strength) == 8)
        #expect(MemoryLayout<ThreshWarpOp>.offset(of: \.a) == 16)
        #expect(MemoryLayout<ThreshWarpOp>.offset(of: \.b) == 32)
    }

    @Test("ThreshFrameUniforms is exactly 64 bytes (Invariant 4 hard cap)")
    func frameUniformsLayout() {
        #expect(MemoryLayout<ThreshFrameUniforms>.size == 64)
        #expect(MemoryLayout<ThreshFrameUniforms>.stride == 64)
        #expect(MemoryLayout<ThreshFrameUniforms>.offset(of: \.camPosFov) == 0)
        #expect(MemoryLayout<ThreshFrameUniforms>.offset(of: \.camQuat) == 16)
        #expect(MemoryLayout<ThreshFrameUniforms>.offset(of: \.scaleCtx) == 32)
        #expect(MemoryLayout<ThreshFrameUniforms>.offset(of: \.meta) == 48)
    }

    @Test("EngineSlot raw values match the THRESH_SLOT_* header constants")
    func engineSlotCrossCheck() {
        // ThresholdCore cannot import the ABI header (Foundation + simd
        // only); this is the cross-target test Catalog.swift promises.
        #expect(EngineSlot.maxSteps.rawValue == Int(THRESH_SLOT_MAX_STEPS))
        #expect(EngineSlot.maxDist.rawValue == Int(THRESH_SLOT_MAX_DIST))
        #expect(EngineSlot.stepSafety.rawValue == Int(THRESH_SLOT_STEP_SAFETY))
        #expect(EngineSlot.iterations.rawValue == Int(THRESH_SLOT_ITERATIONS))
        #expect(EngineSlot.aoStrength.rawValue == Int(THRESH_SLOT_AO_STRENGTH))
        #expect(EngineSlot.shadowSoft.rawValue == Int(THRESH_SLOT_SHADOW_SOFT))
        // Color pipeline slots (plan §5.5).
        #expect(EngineSlot.gradRepeat.rawValue == Int(THRESH_SLOT_GRAD_REPEAT))
        #expect(EngineSlot.gradOffset.rawValue == Int(THRESH_SLOT_GRAD_OFFSET))
        #expect(EngineSlot.gradSmoothing.rawValue == Int(THRESH_SLOT_GRAD_SMOOTH))
        #expect(EngineSlot.colorMapMode.rawValue == Int(THRESH_SLOT_MAP_MODE))
        #expect(EngineSlot.saturation.rawValue == Int(THRESH_SLOT_SATURATION))
        #expect(EngineSlot.contrast.rawValue == Int(THRESH_SLOT_CONTRAST))
        #expect(EngineSlot.vibrance.rawValue == Int(THRESH_SLOT_VIBRANCE))
        #expect(EngineSlot.brightness.rawValue == Int(THRESH_SLOT_BRIGHTNESS))
        #expect(EngineSlot.gamma.rawValue == Int(THRESH_SLOT_GAMMA))
        #expect(EngineSlot.tonemap.rawValue == Int(THRESH_SLOT_TONEMAP))
        #expect(EngineSlot.reservedCount == Int(THRESH_SLOT_ENGINE_COUNT))
        // All color slots live inside the reserved region (no ABI count bump).
        #expect(EngineSlot.tonemap.rawValue < EngineSlot.reservedCount)
    }

    @Test("ColorMapMode raw values match the ThreshColorMapMode header enum")
    func colorMapModeCrossCheck() {
        #expect(ColorMapMode.orbitTrap.rawValue == Int(ThreshColorMapOrbitTrap.rawValue))
        #expect(ColorMapMode.depth.rawValue == Int(ThreshColorMapDepth.rawValue))
        #expect(ColorMapMode.normal.rawValue == Int(ThreshColorMapNormal.rawValue))
        #expect(ColorMapMode.blend.rawValue == Int(ThreshColorMapBlend.rawValue))
    }

    @Test("ThreshPalette is 16B header + 16B per stop; Core cap matches header")
    func paletteLayout() {
        #expect(MemoryLayout<ThreshPalette>.size == 16 + 16 * Int(THRESH_MAX_GRADIENT_STOPS))
        #expect(MemoryLayout<ThreshPalette>.alignment == 16)
        #expect(Palette.maxStops == Int(THRESH_MAX_GRADIENT_STOPS))
    }

    @Test("WarpKind raw values match ThreshWarpKind exactly (never renumber)")
    func warpKindValues() {
        // Pinned table: these values persist in scene files.
        let expected: [(WarpKind, UInt32)] = [
            (.none, 0), (.twist, 1), (.bend, 2), (.ripple, 3), (.mirror, 4),
            (.boxFold, 5), (.planeFold, 6), (.kaleidoscope, 7), (.coxeter, 8),
            (.mengerFold, 9), (.offsetFold, 10), (.sphereFold, 11),
            (.sphereInvert, 12), (.tubeFold, 13), (.shells, 14),
            (.scaleRepeat, 15), (.tiling, 16), (.scale, 17),
            (.sphereProject, 18), (.handAttract, 64), (.forearmCarve, 65),
            (.bounding, 66),
        ]
        #expect(WarpKind.allCases.count == expected.count)
        for (kind, raw) in expected {
            #expect(kind.rawValue == raw, "\(kind) must be \(raw)")
        }
        // Bridge round-trips through the imported C enum.
        for kind in WarpKind.allCases {
            #expect(WarpKind(abi: kind.abiValue) == kind)
            #expect(UInt32(kind.abiValue.rawValue) == kind.rawValue)
        }
        // Spot-check against the imported C constants themselves.
        #expect(WarpKind.twist.abiValue == ThreshWarpKindTwist)
        #expect(WarpKind.coxeter.abiValue == ThreshWarpKindCoxeter)
        #expect(WarpKind.sphereProject.abiValue == ThreshWarpKindSphereProject)
        #expect(WarpKind.handAttract.abiValue == ThreshWarpKindHandAttract)
        #expect(WarpKind.forearmCarve.abiValue == ThreshWarpKindForearmCarve)
        #expect(WarpKind.bounding.abiValue == ThreshWarpKindBounding)
        // Unknown values do not bridge.
        #expect(WarpKind(abi: ThreshWarpKind(rawValue: 999)) == nil)
    }

    @Test("Distance-op base and flag bit match the header")
    func distanceOpBaseAndFlags() {
        #expect(WarpKind.distanceOpBase == THRESH_WARP_KIND_DISTANCE_OP_BASE)
        #expect(WarpFlags.optionA.rawValue == THRESH_WARP_FLAG_OPTION_A)
        #expect(WarpFlags.optionB.rawValue == THRESH_WARP_FLAG_OPTION_B)
    }
}
