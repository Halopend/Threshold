// UpscaleFloorTests.swift — guards the Render-Quality-below-~33% footgun.
//
// MetalFX temporal scaling caps at `maxScaleFactor`× (3×) upscale with a 32px
// min input edge. A requested render scale below that floor used to fail
// `TemporalUpscaler.prepare`'s ratio guard and fall through to a FULL-RESOLUTION
// direct render — GPU cost spiking exactly when the user asked for LESS, which
// can saturate the GPU and stall the UI. `minimumInputSize(forOutput:)` is the
// clamp that keeps the march input inside MetalFX's supported range. These
// tests assert the clamped size ALWAYS satisfies the same guards `prepare`
// enforces, across a spread of resolutions — so low quality never disengages
// the upscaler. Pure arithmetic; no GPU.

#if os(macOS) || os(iOS)

import Testing
@testable import ThresholdRender

@Suite("MetalFX input-scale floor")
struct UpscaleFloorTests {
    /// Every accept condition `TemporalUpscaler.prepare` checks for an input,
    /// as a pure predicate so the test proves the floor would be admitted.
    private func prepareWouldAccept(
        inW: Int, inH: Int, outW: Int, outH: Int
    ) -> Bool {
        min(inW, inH) >= TemporalUpscaler.minimumInputEdge
            && inW <= outW && inH <= outH
            && Float(outW) <= Float(inW) * TemporalUpscaler.maxScaleFactor
            && Float(outH) <= Float(inH) * TemporalUpscaler.maxScaleFactor
    }

    @Test("The floor size is accepted by prepare's guards for every resolution")
    func floorIsAlwaysAccepted() {
        // A spread: tiny, odd, non-square, and large retina sizes — plus the
        // exact awkward multiples-of-three-minus-one that expose off-by-one in
        // the ceil (e.g. 100/3 rounds to 34, and 34×3 = 102 ≥ 100).
        let sizes = [
            (64, 64), (100, 100), (101, 99), (128, 72), (1280, 720),
            (1512, 982), (2342, 1730), (3024, 1964), (33, 33), (32, 32),
        ]
        for (w, h) in sizes {
            let floor = TemporalUpscaler.minimumInputSize(forOutputWidth: w, height: h)
            #expect(
                prepareWouldAccept(inW: floor.width, inH: floor.height, outW: w, outH: h),
                "floor \(floor) must satisfy MetalFX guards for output \(w)x\(h)")
        }
    }

    @Test("A below-floor request clamps UP to the floor, never full-res")
    func belowFloorClampsUpNotToFullRes() {
        // Emulate the InteractiveSession clamp for a 2342x1730 drawable at a
        // 12% request (well under the ~33% cliff).
        let outW = 2342, outH = 1730
        let scale: Float = 0.12
        let floor = TemporalUpscaler.minimumInputSize(forOutputWidth: outW, height: outH)
        let inputW = max(Int((Float(outW) * scale).rounded()), floor.width)
        let inputH = max(Int((Float(outH) * scale).rounded()), floor.height)

        // The raw 12% request would be below the floor…
        #expect(Int((Float(outW) * scale).rounded()) < floor.width)
        // …so the clamp pins it to the floor (cheap), and MetalFX still accepts.
        #expect(inputW == floor.width && inputH == floor.height)
        #expect(prepareWouldAccept(inW: inputW, inH: inputH, outW: outW, outH: outH))
        // Effective scale is the MetalFX minimum (~1/3), NOT 1.0 (full-res).
        let effective = Float(inputW) / Float(outW)
        #expect(effective < 0.4 && effective > 0.3,
                "low quality should march at the ~1/3 MetalFX floor, got \(effective)")
    }

    @Test("An in-range request passes through unclamped")
    func inRangeRequestUnchanged() {
        let outW = 1280, outH = 720
        let scale: Float = 0.6  // above the ~33% floor
        let floor = TemporalUpscaler.minimumInputSize(forOutputWidth: outW, height: outH)
        let inputW = max(Int((Float(outW) * scale).rounded()), floor.width)
        #expect(inputW == Int((Float(outW) * scale).rounded()))  // not clamped
        #expect(inputW > floor.width)
    }
}

#endif
