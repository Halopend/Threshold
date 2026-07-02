// InputsTests.swift — AudioDSP feature extraction on synthesized buffers:
// band placement, RMS/centroid calibration, onset detection, determinism,
// and the audio.* signal fan-out. Everything is deterministic — sine
// generators plus seeded SplitMix64 noise (never SystemRandomNumberGenerator).

import Foundation
import Testing
import ThresholdCore

@testable import ThresholdInputs

// MARK: - Deterministic helpers

/// Tiny deterministic PRNG (same struct as the ThresholdCore test support).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        Float.random(in: range, using: &self)
    }
}

private let sampleRate = 44_100.0
private let fftSize = 1024

private func sine(
    _ frequency: Double, amplitude: Float = 1, count: Int = fftSize
) -> [Float] {
    (0..<count).map { i in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
    }
}

private let silence = [Float](repeating: 0, count: fftSize)

private func seededNoise(seed: UInt64, amplitude: Float = 1) -> [Float] {
    var rng = SplitMix64(seed: seed)
    return (0..<fftSize).map { _ in rng.float(in: -amplitude...amplitude) }
}

// MARK: - Feature extraction

@Suite("AudioDSP features")
struct AudioDSPFeatureTests {
    @Test("440 Hz full-scale sine: mid band dominant near 1, rms ≈ 0.707, low centroid")
    func midBandSine() {
        let dsp = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        let f = dsp.process(sine(440))

        // Band levels are energy-normalized so a full-scale sine reads ≈ 1
        // in its band (Parseval calibration in AudioDSP — exact for on-bin
        // sines, leakage-insensitive off-bin).
        #expect(f.bandMid > 0.8 && f.bandMid < 1.1)
        #expect(f.bandMid > f.bandLow * 5)
        #expect(f.bandMid > f.bandHigh * 5)
        // RMS of a full-scale (±1) sine is 1/√2 ≈ 0.707.
        #expect(abs(f.rms - 0.707) < 0.05)
        // 440 Hz over a 22 050 Hz Nyquist → centroid ≈ 0.02.
        #expect(f.centroid < 0.1)
    }

    @Test("100 Hz sine: low band dominant")
    func lowBandSine() {
        let dsp = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        let f = dsp.process(sine(100))

        #expect(f.bandLow > 0.7)
        #expect(f.bandLow > f.bandMid * 2)
        #expect(f.bandLow > f.bandHigh * 5)
    }

    @Test("8 kHz sine: high band dominant, centroid high")
    func highBandSine() {
        let dsp = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        let f = dsp.process(sine(8000))

        #expect(f.bandHigh > 0.8 && f.bandHigh < 1.1)
        #expect(f.bandHigh > f.bandLow * 5)
        #expect(f.bandHigh > f.bandMid * 5)
        // 8000 / 22050 ≈ 0.36 — high relative to any audible tonal content.
        #expect(f.centroid > 0.3 && f.centroid < 0.45)
        #expect(f.centroid > dspCentroid(of: 440))
    }

    private func dspCentroid(of frequency: Double) -> Float {
        AudioDSP(sampleRate: sampleRate, fftSize: fftSize).process(sine(frequency)).centroid
    }

    @Test("Silence: every feature is zero")
    func silenceIsZero() {
        let dsp = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        for _ in 0..<3 {
            let f = dsp.process(silence)
            #expect(f.rms < 1e-6)
            #expect(f.bandLow < 1e-6)
            #expect(f.bandMid < 1e-6)
            #expect(f.bandHigh < 1e-6)
            #expect(f.centroid < 1e-6)
            #expect(f.onset < 1e-6)
        }
    }
}

// MARK: - Onset

@Suite("AudioDSP onset")
struct AudioDSPOnsetTests {
    @Test("Silence → broadband noise: onset near max on the transition frame, near zero after")
    func onsetOnTransition() {
        let dsp = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        _ = dsp.process(silence)
        _ = dsp.process(silence)

        let noise = seededNoise(seed: 0xDEAD_BEEF)
        let transition = dsp.process(noise)
        #expect(transition.onset > 0.9)

        // Same buffer again → spectrum unchanged → zero flux → onset 0.
        #expect(dsp.process(noise).onset < 0.05)
        #expect(dsp.process(noise).onset < 0.05)
    }

    @Test("Sustained (varying) noise scores below the transition and adapts downward")
    func onsetAdaptsToSustainedNoise() {
        let dsp = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        _ = dsp.process(silence)

        let transition = dsp.process(seededNoise(seed: 1)).onset
        #expect(transition > 0.9)
        // Fresh noise every frame: spectra differ, but the adaptive baseline
        // rises — every later frame scores below the transition.
        for seed in 2...20 {
            let f = dsp.process(seededNoise(seed: UInt64(seed)))
            #expect(f.onset < transition)
        }
    }

    @Test("Steady sine has no onset after its attack frame")
    func steadyToneNoOnset() {
        let dsp = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        let attack = dsp.process(sine(440)).onset
        #expect(attack > 0.9)  // jump from implicit silence
        // Identical periodic frames → near-zero flux.
        for _ in 0..<5 {
            #expect(dsp.process(sine(440)).onset < 0.05)
        }
    }
}

// MARK: - Determinism & state

@Suite("AudioDSP determinism")
struct AudioDSPDeterminismTests {
    private var frames: [[Float]] {
        [silence, sine(440), seededNoise(seed: 42), sine(100, amplitude: 0.3), silence]
    }

    @Test("Two instances produce identical feature sequences (no shared state)")
    func twoInstancesIdentical() {
        let a = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        let b = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        for frame in frames {
            #expect(a.process(frame) == b.process(frame))
        }
    }

    @Test("The same input sequence twice yields identical features (reset restores init state)")
    func resetRestoresDeterminism() {
        let dsp = AudioDSP(sampleRate: sampleRate, fftSize: fftSize)
        let first = frames.map { dsp.process($0) }
        dsp.reset()
        let second = frames.map { dsp.process($0) }
        #expect(first == second)
    }
}

// MARK: - Signal fan-out

@Suite("Audio signal publishing")
struct AudioSignalPublisherTests {
    @Test("Features fan out to the six audio.* signals with confidence 1")
    func publishesAllSixSignals() {
        let table = SignalTable(ids: SignalID.standardAudio)
        let features = AudioFeatures(
            rms: 0.1, bandLow: 0.2, bandMid: 0.3, bandHigh: 0.4,
            centroid: 0.5, onset: 0.6)

        AudioSignalPublisher.publish(features, into: table, timestamp: 1.5)

        let expected: [(SignalID, Float)] = [
            (.audioRMS, 0.1), (.audioBandLow, 0.2), (.audioBandMid, 0.3),
            (.audioBandHigh, 0.4), (.audioCentroid, 0.5), (.audioOnset, 0.6),
        ]
        for (id, value) in expected {
            let signal = table.read(id: id)
            #expect(signal?.value.x == value)
            #expect(signal?.confidence == 1)
            #expect(signal?.timestamp == 1.5)
        }
    }
}
