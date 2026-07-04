// AudioAnalyzer.swift — the THIN AVAudioEngine shell around AudioDSP
// (plan §8.2, ARCHITECTURE.md §5 `audio.*`). All signal-processing logic
// lives in `AudioDSP`; this file only owns acquisition (input tap), mono
// mixing, hop accumulation, and publishing into the SignalTable.
//
// TIMEBASE: published timestamps are the SAMPLE CLOCK — accumulated samples
// divided by the sample rate — plus `timebaseOffset`. NO wall time is read
// anywhere (Invariant 9). The BindingEngine judges staleness against the
// SESSION clock (`AppClock.now`), so the app MUST bridge the two timebases:
// set `timebaseOffset` (typically to the session-clock time at which capture
// started) so `sampleTime + timebaseOffset` tracks the render clock. Without
// that bridge, audio signals published near sample-time 0 look permanently
// stale to a session clock that has been running for a while.

import ThresholdCore

/// Maps one `AudioFeatures` frame onto the six standard `audio.*` signals
/// (SignalIDs.swift), confidence 1. Pure fan-out — kept out of the AVFAudio
/// gate so it is testable everywhere.
enum AudioSignalPublisher {
    static func publish(_ f: AudioFeatures, into signals: SignalTable, timestamp: Double) {
        func put(_ id: SignalID, _ v: Float) {
            signals.publish(
                id: id, value: SIMD4(v, 0, 0, 0), confidence: 1, timestamp: timestamp)
        }
        put(.audioRMS, f.rms)
        put(.audioBandLow, f.bandLow)
        put(.audioBandMid, f.bandMid)
        put(.audioBandHigh, f.bandHigh)
        put(.audioCentroid, f.centroid)
        put(.audioOnset, f.onset)
    }
}

#if canImport(AVFAudio)
import AVFAudio
import Synchronization

/// Owns an `AVAudioEngine` input-node tap that feeds `AudioDSP` in
/// 1024-frame hops and publishes the extracted features.
///
/// Concurrency: the analyzer itself is NOT Sendable — construct, `start`,
/// `stop`, and set `timebaseOffset` from one owner (the app shell). The tap
/// callback runs on AVAudioEngine's internal queue and touches only
/// `TapSink`, a compiler-checked Sendable box (a `Mutex` around the DSP
/// state — no `@unchecked` anywhere). Publishing into the `SignalTable` is
/// the sanctioned any-thread ingress (Invariant 13).
public final class AudioAnalyzer {
    /// Hop size in frames; also the DSP's FFT size.
    public static let hopSize = 1024

    /// Requested capture rate, used only as a fallback when the input node
    /// reports no format. The hardware's actual input rate always wins —
    /// the DSP's band edges are computed from the rate in effect at
    /// `start()`.
    public let preferredSampleRate: Double

    private let engine = AVAudioEngine()
    private let sink: TapSink
    private var isRunning = false

    /// Added to every published timestamp to bridge the sample clock into
    /// the session clock (see the timebase note at the top of this file).
    /// Settable at any time, including while running.
    public var timebaseOffset: Double {
        get { sink.state.withLock { $0.timebaseOffset } }
        set { sink.state.withLock { $0.timebaseOffset = newValue } }
    }

    /// The user's tunable Focus Band. Published into `audio.band.user` each hop
    /// while `enabled`; settable any time (including while running). The app
    /// shell mirrors this from the UI / a loaded scene (it is not render-session
    /// state — see AudioFocusBand.swift).
    public var focusBand: AudioFocusBand {
        get { sink.state.withLock { $0.focusBand } }
        set { sink.state.withLock { $0.focusBand = newValue } }
    }

    /// Convenience for the app-shell bridge (mirror/scene → analyzer).
    public func setFocusBand(_ band: AudioFocusBand) { focusBand = band }

    /// - Parameters:
    ///   - signals: table the `audio.*` namespace publishes into; register
    ///     `SignalID.standardAudio` (at least) when building it.
    ///   - preferredSampleRate: fallback rate, see `preferredSampleRate`.
    public init(signals: SignalTable, preferredSampleRate: Double = 44_100) {
        precondition(preferredSampleRate > 0)
        self.preferredSampleRate = preferredSampleRate
        self.sink = TapSink(signals: signals)
    }

    deinit {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Install the input tap and start the engine. Microphone permission /
    /// audio-session category is the app's responsibility, before this call.
    /// Restarting after `stop()` resets the DSP state and the sample clock.
    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : preferredSampleRate
        sink.state.withLock { $0.prepare(sampleRate: sampleRate) }

        // Capture only the Sendable sink; buffer sizes delivered by the tap
        // are a request, not a guarantee — the sink re-chunks into exact
        // `hopSize` frames.
        let sink = self.sink
        input.installTap(
            onBus: 0, bufferSize: AVAudioFrameCount(Self.hopSize), format: nil
        ) { buffer, _ in
            sink.consume(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    /// Remove the tap and stop the engine. Idempotent. Publishes one silent
    /// frame so the `audio.*` signals fall to rest — meters drop to zero and
    /// momentary music routes release instead of freezing on the last value.
    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        sink.publishSilence()
    }
}

/// The Sendable box the tap block captures: a `Mutex` over the (non-Sendable)
/// DSP + accumulation state, plus the (Sendable) signal table. The tap is the
/// only contender for the lock besides the cheap `timebaseOffset` accessor,
/// so the critical section (one FFT per hop) never blocks the render thread —
/// signal publication is the lock-free seqlock path.
private final class TapSink: Sendable {
    struct State {
        var dsp: AudioDSP?
        /// Mono samples awaiting a full hop.
        var pending: [Float] = []
        /// Total samples consumed by the DSP — the sample clock.
        var samplesProcessed: Int = 0
        var sampleRate: Double = 44_100
        var timebaseOffset: Double = 0
        var focusBand: AudioFocusBand = .default

        mutating func prepare(sampleRate: Double) {
            dsp = AudioDSP(sampleRate: sampleRate, fftSize: AudioAnalyzer.hopSize)
            pending.removeAll(keepingCapacity: true)
            samplesProcessed = 0
            self.sampleRate = sampleRate
        }
    }

    let signals: SignalTable
    let state: Mutex<State>

    init(signals: SignalTable) {
        self.signals = signals
        self.state = Mutex(State())
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }

        state.withLock { s in
            guard let dsp = s.dsp else { return }

            // Mono mix (equal-weight average) into the pending buffer.
            s.pending.reserveCapacity(s.pending.count + frames)
            if channelCount == 1 {
                s.pending.append(
                    contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            } else {
                let gain = 1 / Float(channelCount)
                for i in 0..<frames {
                    var acc: Float = 0
                    for c in 0..<channelCount { acc += channels[c][i] }
                    s.pending.append(acc * gain)
                }
            }

            // Feed complete hops. Timestamp = sample clock at the END of the
            // hop (the features describe audio up to that instant), bridged
            // by timebaseOffset.
            let hop = AudioAnalyzer.hopSize
            var consumed = 0
            while s.pending.count - consumed >= hop {
                let frame = Array(s.pending[consumed..<(consumed + hop)])
                let features = dsp.process(frame)
                consumed += hop
                s.samplesProcessed += hop
                let timestamp =
                    Double(s.samplesProcessed) / s.sampleRate + s.timebaseOffset
                AudioSignalPublisher.publish(features, into: signals, timestamp: timestamp)

                // Focus Band: an arbitrary window over THIS hop's spectrum
                // (dsp.bandLevel reads the frame just processed). Only when
                // enabled — a disabled band leaves audio.band.user to go stale.
                let band = s.focusBand
                if band.enabled {
                    let level = dsp.bandLevel(lowHz: band.lowHz, highHz: band.highHz) * band.gain
                    signals.publish(
                        id: .audioBandUser, value: SIMD4(level, 0, 0, 0),
                        confidence: 1, timestamp: timestamp)
                }
            }
            if consumed > 0 { s.pending.removeFirst(consumed) }
        }
    }

    /// Publish one silent frame (all `audio.*` → 0) at the current sample
    /// clock, so meters and momentary routes return to rest when capture stops.
    func publishSilence() {
        state.withLock { s in
            let timestamp = Double(s.samplesProcessed) / s.sampleRate + s.timebaseOffset
            AudioSignalPublisher.publish(.zero, into: signals, timestamp: timestamp)
            signals.publish(
                id: .audioBandUser, value: .zero, confidence: 1, timestamp: timestamp)
        }
    }
}
#endif  // canImport(AVFAudio)
