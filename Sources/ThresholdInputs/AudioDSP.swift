// AudioDSP.swift — the PURE audio feature extractor (plan §8.2,
// ARCHITECTURE.md §5 `audio.*`). Deterministic: same sample frames in, same
// features out — no wall time, no randomness, no I/O. The AVAudioEngine shell
// (`AudioAnalyzer`) feeds it; tests feed it synthesized buffers.
//
// Concurrency: NOT Sendable. One instance is owned by whoever calls
// `process` (the audio tap path in production, the test in tests); all FFT
// scratch and the onset state live in the instance.

import Accelerate
import Foundation

// MARK: - AudioFeatures

/// One frame of extracted features. All values are nominally 0…1:
/// - `rms`: root-mean-square of the raw frame (full-scale ±1 sine ≈ 0.707).
/// - `bandLow`/`bandMid`/`bandHigh`: energy-normalized band levels
///   (low < 250 Hz, mid 250–2000 Hz, high > 2000 Hz); a full-scale sine
///   lands near 1 in its band.
/// - `centroid`: spectral centroid, normalized 0…1 over Nyquist.
/// - `onset`: half-wave-rectified spectral flux vs the previous frame,
///   adaptively normalized (sudden broadband jump → near 1, steady → 0).
public struct AudioFeatures: Sendable, Equatable {
    public let rms: Float
    public let bandLow: Float
    public let bandMid: Float
    public let bandHigh: Float
    public let centroid: Float
    public let onset: Float

    public init(
        rms: Float, bandLow: Float, bandMid: Float, bandHigh: Float,
        centroid: Float, onset: Float
    ) {
        self.rms = rms
        self.bandLow = bandLow
        self.bandMid = bandMid
        self.bandHigh = bandHigh
        self.centroid = centroid
        self.onset = onset
    }

    public static let zero = AudioFeatures(
        rms: 0, bandLow: 0, bandMid: 0, bandHigh: 0, centroid: 0, onset: 0)
}

// MARK: - AudioDSP

/// vDSP-backed FFT feature extractor. The FFT setup, Hann window, and all
/// scratch buffers are allocated once at init and reused every frame — the
/// `process` hot path never allocates (beyond Swift's amortized noise).
public final class AudioDSP {
    public let sampleRate: Double
    public let fftSize: Int

    // Fixed resources.
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let halfSize: Int  // fftSize / 2 — bins 0..<halfSize (Nyquist dropped)

    // Band partitions over bin index k (bin frequency = k · sampleRate/fftSize).
    // Bin 0 (DC) is excluded from every spectral feature.
    private let lowBins: Range<Int>
    private let midBins: Range<Int>
    private let highBins: Range<Int>

    // Normalizations (see the derivations in `process`).
    private let bandNorm: Float       // Σ|mag|² → band level, sine-calibrated
    private let amplitudeNorm: Float  // vDSP magnitude → sine amplitude

    // Reused scratch (never read across frames).
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudeSquared: [Float]
    private var magnitude: [Float]

    // Cross-frame state — everything `reset()` clears.
    private var previousMagnitude: [Float]
    private var fluxAverage: Float = 0

    /// Onset EMA coefficient per frame (~10 frame time constant; at a
    /// 1024-sample hop / 44.1 kHz that is ≈ 0.23 s — "slow").
    private static let fluxAverageAlpha: Float = 0.1
    /// Flux must exceed this multiple of its running average to register.
    private static let onsetThresholdRatio: Float = 1.5
    /// Absolute flux floor (amplitude units) below which onset is 0, so
    /// numeric dust in near-silence can never spike the detector.
    private static let fluxFloor: Float = 1e-4

    /// - Parameters:
    ///   - sampleRate: Hz; must be > 0. Determines the band-edge bins.
    ///   - fftSize: samples per frame; power of two, >= 32.
    public init(sampleRate: Double, fftSize: Int = 1024) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        precondition(
            fftSize >= 32 && fftSize & (fftSize - 1) == 0,
            "fftSize must be a power of two >= 32, got \(fftSize)")

        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.halfSize = fftSize / 2
        self.log2n = vDSP_Length(fftSize.trailingZeroBitCount)

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP_create_fftsetup failed for fftSize \(fftSize)")
        }
        self.fftSetup = setup

        var hann = [Float](repeating: 0, count: fftSize)
        // Denormalized Hann: w[n] = 0.5(1 − cos(2πn/N)) — coherent gain 0.5,
        // Σw² = 3N/8. The band normalization below assumes exactly this.
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        self.window = hann

        // Band edges in bins. Bin k covers frequency k·binHz; DC (k = 0) is
        // excluded, Nyquist is dropped in packing. Ranges are clamped so
        // degenerate rates (tiny fftSize / low sampleRate) stay valid.
        let binHz = sampleRate / Double(fftSize)
        let lowEnd = max(1, min(halfSize, Int((250.0 / binHz).rounded(.up))))
        let midEnd = max(lowEnd, min(halfSize, Int((2000.0 / binHz).rounded(.down)) + 1))
        self.lowBins = 1..<lowEnd
        self.midBins = lowEnd..<midEnd
        self.highBins = midEnd..<halfSize

        // Calibration. vDSP_fft_zrip outputs are 2× the mathematical DFT, so
        // for a windowed unit sine at bin k: |mag[k]| = 2·|Y[k]| = N/2 (Hann
        // coherent gain 0.5). Parseval over the half spectrum gives the
        // total sine energy Σ|Y|² = N²·3/32, i.e. Σ mag² = N²·3/8. Band
        // level = sqrt(Σ_band mag² · 8/(3N²)) → a full-scale sine reads 1.0
        // in its band regardless of where in the bin it falls (energy sums
        // are leakage-insensitive).
        let n = Float(fftSize)
        self.bandNorm = 8.0 / (3.0 * n * n)
        // |mag[k]| = A·N/2 for an on-bin sine → A = mag·2/N. Used to put the
        // flux in amplitude units so the absolute floor is scale-meaningful.
        self.amplitudeNorm = 2.0 / n

        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realPart = [Float](repeating: 0, count: halfSize)
        self.imagPart = [Float](repeating: 0, count: halfSize)
        self.magnitudeSquared = [Float](repeating: 0, count: halfSize)
        self.magnitude = [Float](repeating: 0, count: halfSize)
        self.previousMagnitude = [Float](repeating: 0, count: halfSize)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Clear all cross-frame state: the previous-frame spectrum and the
    /// onset flux running average. After `reset()` the instance behaves
    /// exactly like a freshly constructed one — the next frame is treated
    /// as following silence, so a loud next frame reads as an onset.
    public func reset() {
        for i in previousMagnitude.indices { previousMagnitude[i] = 0 }
        fluxAverage = 0
    }

    /// Extract features from exactly `fftSize` samples (one hop).
    /// Deterministic: depends only on the samples and prior `process` calls
    /// on this instance.
    public func process(_ samples: [Float]) -> AudioFeatures {
        precondition(
            samples.count == fftSize,
            "process expects exactly \(fftSize) samples, got \(samples.count)")

        let n = vDSP_Length(fftSize)

        // RMS of the RAW frame (window applies to spectral features only).
        // Full-scale (±1) sine → 1/√2 ≈ 0.707.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, n)

        // Hann window → packed real FFT → magnitudes.
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, n)
        windowed.withUnsafeBufferPointer { input in
            realPart.withUnsafeMutableBufferPointer { real in
                imagPart.withUnsafeMutableBufferPointer { imag in
                    var split = DSPSplitComplex(
                        realp: real.baseAddress!, imagp: imag.baseAddress!)
                    input.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: halfSize
                    ) { packed in
                        vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(halfSize))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // zrip packs Nyquist into imag[0]; zero it so bin 0 is
                    // pure DC (excluded from features anyway).
                    imag.baseAddress![0] = 0
                    vDSP_zvmags(&split, 1, &magnitudeSquared, 1, vDSP_Length(halfSize))
                }
            }
        }
        var binCount = Int32(halfSize)
        vvsqrtf(&magnitude, magnitudeSquared, &binCount)

        // Band levels (see bandNorm derivation in init).
        func bandLevel(_ bins: Range<Int>) -> Float {
            var sum: Float = 0
            for k in bins { sum += magnitudeSquared[k] }
            return (sum * bandNorm).squareRoot()
        }
        let bandLow = bandLevel(lowBins)
        let bandMid = bandLevel(midBins)
        let bandHigh = bandLevel(highBins)

        // Spectral centroid: magnitude-weighted mean bin, normalized so
        // Nyquist = 1. Silence (zero spectrum) reads 0.
        var weighted: Float = 0
        var total: Float = 0
        for k in 1..<halfSize {
            weighted += Float(k) * magnitude[k]
            total += magnitude[k]
        }
        let centroid = total > 1e-9 ? (weighted / total) / Float(halfSize) : 0

        // Onset: half-wave-rectified spectral flux vs the previous frame,
        // in amplitude units, normalized by a slow running average so the
        // detector adapts to the program level. A jump from (near) silence
        // → fluxAverage ≈ 0 → onset ≈ flux/flux ≈ 1; an unchanged spectrum
        // → flux 0 → onset 0; sustained busy material → flux ≈ average →
        // suppressed by the threshold ratio.
        var flux: Float = 0
        for k in 1..<halfSize {
            let rise = magnitude[k] - previousMagnitude[k]
            if rise > 0 { flux += rise }
        }
        flux *= amplitudeNorm
        var onset: Float = 0
        if flux > Self.fluxFloor {
            let baseline = Self.onsetThresholdRatio * fluxAverage
            onset = max(0, flux - baseline) / (flux + 1e-6)
        }
        // Update the running average AFTER scoring, so the transition frame
        // is judged against the pre-jump level.
        fluxAverage += Self.fluxAverageAlpha * (flux - fluxAverage)
        swap(&previousMagnitude, &magnitude)

        return AudioFeatures(
            rms: rms, bandLow: bandLow, bandMid: bandMid, bandHigh: bandHigh,
            centroid: centroid, onset: onset)
    }
}
