// LFOTests.swift — the procedural LFO subsystem: waveform math, combo summing,
// determinism (Invariant 9), the LFOEngine's publish path into the SignalTable,
// and Codable round-trip / forward compatibility.

import Foundation
import Testing

@testable import ThresholdCore

private func isClose(_ a: Float, _ b: Float, tol: Float = 1e-4) -> Bool {
    abs(a - b) <= tol
}

// MARK: - Waveform shapes

@Suite("LFOWave shapes")
struct LFOWaveTests {
    @Test("sine is the reference: 0 at phase 0, +1 at quarter, 0 at half")
    func sine() {
        #expect(isClose(LFOWave.sine.sample(phase: 0, seed: 0), 0))
        #expect(isClose(LFOWave.sine.sample(phase: 0.25, seed: 0), 1))
        #expect(isClose(LFOWave.sine.sample(phase: 0.5, seed: 0), 0))
        #expect(isClose(LFOWave.sine.sample(phase: 0.75, seed: 0), -1))
    }

    @Test("triangle is phase-aligned with sine (0 → 1 → 0 → −1)")
    func triangle() {
        #expect(isClose(LFOWave.triangle.sample(phase: 0, seed: 0), 0))
        #expect(isClose(LFOWave.triangle.sample(phase: 0.25, seed: 0), 1))
        #expect(isClose(LFOWave.triangle.sample(phase: 0.5, seed: 0), 0))
        #expect(isClose(LFOWave.triangle.sample(phase: 0.75, seed: 0), -1))
    }

    @Test("saw ramps −1→1 across the cycle and wraps")
    func saw() {
        #expect(isClose(LFOWave.saw.sample(phase: 0, seed: 0), -1))
        #expect(isClose(LFOWave.saw.sample(phase: 0.5, seed: 0), 0))
        #expect(isClose(LFOWave.saw.sample(phase: 0.999, seed: 0), 0.998, tol: 2e-3))
        // Wraps: phase 1.25 behaves like 0.25.
        #expect(isClose(LFOWave.saw.sample(phase: 1.25, seed: 0),
                        LFOWave.saw.sample(phase: 0.25, seed: 0)))
    }

    @Test("square gates ±1, positive on the first half-cycle")
    func square() {
        #expect(LFOWave.square.sample(phase: 0.0, seed: 0) == 1)
        #expect(LFOWave.square.sample(phase: 0.25, seed: 0) == 1)
        #expect(LFOWave.square.sample(phase: 0.5, seed: 0) == -1)
        #expect(LFOWave.square.sample(phase: 0.75, seed: 0) == -1)
    }

    @Test("all periodic shapes stay within ±1")
    func bounded() {
        for wave in [LFOWave.sine, .triangle, .saw, .square, .noise] {
            for i in 0..<200 {
                let v = wave.sample(phase: Float(i) * 0.037, seed: 99)
                #expect(v >= -1.0001 && v <= 1.0001)
            }
        }
    }
}

// MARK: - Noise

@Suite("LFOWave noise")
struct LFONoiseTests {
    @Test("deterministic: same phase + seed → same value")
    func deterministic() {
        for p in stride(from: Float(0), through: 5, by: 0.3) {
            #expect(LFOWave.noise.sample(phase: p, seed: 7)
                    == LFOWave.noise.sample(phase: p, seed: 7))
        }
    }

    @Test("different seeds decorrelate")
    func seededDecorrelation() {
        let a = (0..<32).map { LFOWave.noise.sample(phase: Float($0) * 0.5, seed: 1) }
        let b = (0..<32).map { LFOWave.noise.sample(phase: Float($0) * 0.5, seed: 2) }
        #expect(a != b)
    }

    @Test("continuous: tiny phase steps make tiny value steps")
    func continuous() {
        var prev = LFOWave.noise.sample(phase: 0, seed: 3)
        for i in 1...500 {
            let v = LFOWave.noise.sample(phase: Float(i) * 0.002, seed: 3)
            #expect(abs(v - prev) < 0.05)  // no clicks between lattice points
            prev = v
        }
    }
}

// MARK: - Combo evaluation

@Suite("LFOSpec combo evaluation")
struct LFOSpecTests {
    @Test("value = bias + Σ amplitude·wave")
    func comboSum() {
        let spec = LFOSpec(
            slot: .lfoA,
            components: [
                LFOComponent(wave: .sine, rateHz: 1, phase: 0, amplitude: 0.5),
                LFOComponent(wave: .sine, rateHz: 1, phase: 0, amplitude: 0.25),
            ],
            bias: 0.1)
        // At t = 0.25, both sines are at +1 → 0.1 + 0.5 + 0.25 = 0.85.
        #expect(isClose(spec.value(at: 0.25, seed: 0), 0.85))
    }

    @Test("rateHz 0 is time-invariant (a constant tap)")
    func frozen() {
        let spec = LFOSpec(
            slot: .lfoA,
            components: [LFOComponent(wave: .sine, rateHz: 0, phase: 0.25, amplitude: 1)])
        let a = spec.value(at: 0, seed: 0)
        let b = spec.value(at: 123.4, seed: 0)
        #expect(a == b)
        #expect(isClose(a, 1))  // sine at phase 0.25
    }

    @Test("negative rate runs the shape backwards")
    func negativeRate() {
        let fwd = LFOSpec(slot: .lfoA,
            components: [LFOComponent(wave: .saw, rateHz: 1, phase: 0, amplitude: 1)])
        let rev = LFOSpec(slot: .lfoA,
            components: [LFOComponent(wave: .saw, rateHz: -1, phase: 0, amplitude: 1)])
        #expect(isClose(fwd.value(at: 0.25, seed: 0), -rev.value(at: 0.25, seed: 0), tol: 2e-3))
    }

    @Test("non-finite result is clamped to 0")
    func nonFiniteGuard() {
        let spec = LFOSpec(slot: .lfoA,
            components: [LFOComponent(wave: .sine, rateHz: 1, phase: 0, amplitude: .infinity)])
        #expect(spec.value(at: 0.25, seed: 0) == 0)
    }
}

// MARK: - LFOEngine publish path

@Suite("LFOEngine")
struct LFOEngineTests {
    @Test("publishes each enabled spec into its slot, fresh")
    func publishes() {
        let table = SignalTable(ids: [.lfoA, .lfoB])
        let engine = LFOEngine(lfos: [
            LFOSpec(slot: .lfoA,
                components: [LFOComponent(wave: .sine, rateHz: 1, phase: 0, amplitude: 1)]),
        ])
        engine.publish(into: table, now: 0.25)
        let a = table.read(id: .lfoA)
        #expect(isClose(a?.value.x ?? -9, 1))
        #expect(a?.confidence == 1)
        #expect(a?.timestamp == 0.25)
        // lfoB has no spec → never published.
        #expect(table.read(id: .lfoB)?.confidence == 0)
    }

    @Test("disabled specs are not published")
    func disabledSkipped() {
        let table = SignalTable(ids: [.lfoA])
        let engine = LFOEngine(lfos: [
            LFOSpec(slot: .lfoA, components: [LFOComponent()], enabled: false),
        ])
        engine.publish(into: table, now: 1)
        #expect(table.read(id: .lfoA)?.confidence == 0)
        #expect(engine.lastSkippedCount == 0)  // disabled ≠ skipped
    }

    @Test("duplicate slots: first wins, extras counted as skips")
    func duplicateSlots() {
        let table = SignalTable(ids: [.lfoA])
        let engine = LFOEngine(lfos: [
            LFOSpec(slot: .lfoA,
                components: [LFOComponent(wave: .sine, rateHz: 0, phase: 0.25, amplitude: 1)]),
            LFOSpec(slot: .lfoA,
                components: [LFOComponent(wave: .sine, rateHz: 0, phase: 0, amplitude: 1)]),
        ])
        engine.publish(into: table, now: 0)
        #expect(engine.lastSkippedCount == 1)
        #expect(isClose(table.read(id: .lfoA)?.value.x ?? -9, 1))  // first spec (phase 0.25)
    }

    @Test("assigning lfos rebuilds the cache")
    func reassign() {
        let engine = LFOEngine()
        #expect(engine.lastSkippedCount == 0)
        engine.lfos = [
            LFOSpec(slot: .lfoA, components: [LFOComponent()]),
            LFOSpec(slot: .lfoA, components: [LFOComponent()]),
        ]
        #expect(engine.lastSkippedCount == 1)
    }
}

// MARK: - Codec

@Suite("LFOSpec Codable")
struct LFOCodableTests {
    @Test("round-trips through JSON")
    func roundTrip() throws {
        let spec = LFOSpec(
            slot: .lfoC,
            name: "wobble",
            components: [
                LFOComponent(wave: .triangle, rateHz: 2, phase: 0.1, amplitude: 0.7),
                LFOComponent(wave: .noise, rateHz: 0.3, phase: 0, amplitude: 0.2),
            ],
            bias: -0.1,
            enabled: true)
        let data = try JSONEncoder().encode(spec)
        let back = try JSONDecoder().decode(LFOSpec.self, from: data)
        #expect(back == spec)
    }

    @Test("unknown waveform name degrades to sine (forward compat)")
    func unknownWave() throws {
        let json = """
        {"wave":"wobblotron","rateHz":1.5,"phase":0.2,"amplitude":0.9}
        """.data(using: .utf8)!
        let comp = try JSONDecoder().decode(LFOComponent.self, from: json)
        #expect(comp.wave == .sine)
        #expect(comp.rateHz == 1.5)
    }
}
