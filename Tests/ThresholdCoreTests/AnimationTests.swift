// AnimationTests.swift — Phase 6 (plan §11): keyframe track evaluation, loop
// modes, the AnimationPlayer's lane semantics (stop zeroes the lane; other
// lanes survive), absolute-vs-offset per composition, determinism, and the
// .threshanim codec (round-trip, unknown-key preservation, version guards).

import Foundation
import Testing

@testable import ThresholdCore

// MARK: - Track evaluation

@Suite("AnimationTrack evaluation")
struct AnimationTrackTests {
    private func track(_ mode: TrackMode = .offset, _ keys: [Keyframe]) -> AnimationTrack {
        AnimationTrack(param: ParamKey("a.b"), mode: mode, keyframes: keys)
    }

    @Test func emptyTrackReturnsNil() {
        #expect(track(.offset, []).value(at: 0) == nil)
    }

    @Test func holdsBeforeFirstAndAfterLast() {
        let t = track(.offset, [
            Keyframe(time: 1, value: 10), Keyframe(time: 2, value: 20),
        ])
        #expect(t.value(at: 0) == [10])
        #expect(t.value(at: 5) == [20])
    }

    @Test func linearInterpolates() {
        let t = track(.offset, [
            Keyframe(time: 0, value: 0), Keyframe(time: 2, value: 10),
        ])
        #expect(t.value(at: 1) == [5])
        #expect(t.value(at: 0.5) == [2.5])
    }

    @Test func stepHoldsLeadingValue() {
        let t = track(.offset, [
            Keyframe(time: 0, value: 3, interpolation: .step),
            Keyframe(time: 1, value: 9),
        ])
        #expect(t.value(at: 0.999) == [3])
        #expect(t.value(at: 1) == [9])
    }

    @Test func smoothIsSmoothstep() throws {
        let t = track(.offset, [
            Keyframe(time: 0, value: 0, interpolation: .smooth),
            Keyframe(time: 1, value: 1),
        ])
        // smoothstep(0.25) = 3u² − 2u³ = 0.15625
        let v = try #require(t.value(at: 0.25))
        #expect(abs(v[0] - 0.15625) < 1e-6)
        // midpoint stays 0.5; endpoints exact
        #expect(t.value(at: 0.5) == [0.5])
    }

    @Test func unsortedKeyframesAreSorted() {
        let t = track(.offset, [
            Keyframe(time: 2, value: 20), Keyframe(time: 0, value: 0),
        ])
        #expect(t.value(at: 1) == [10])
    }

    @Test func coincidentTimesLaterWins() {
        let t = track(.offset, [
            Keyframe(time: 1, value: 5), Keyframe(time: 1, value: 7),
        ])
        #expect(t.value(at: 1) == [7])
        #expect(t.value(at: 2) == [7])
    }

    @Test func vectorTracksBlendComponentwise() {
        let t = track(.offset, [
            Keyframe(time: 0, values: [0, 10, -4]),
            Keyframe(time: 1, values: [2, 20, 4]),
        ])
        #expect(t.value(at: 0.5) == [1, 15, 0])
    }
}

// MARK: - Loop modes

@Suite("AnimationClip loop modes")
struct AnimationClipLoopTests {
    private func clip(_ loop: LoopMode, duration: Double? = nil) -> AnimationClip {
        AnimationClip(
            loop: loop, duration: duration,
            tracks: [AnimationTrack(param: ParamKey("a.b"), keyframes: [
                Keyframe(time: 0, value: 0), Keyframe(time: 4, value: 4),
            ])])
    }

    @Test func durationDerivesFromLatestKeyframe() {
        #expect(clip(.once).effectiveDuration == 4)
        #expect(clip(.once, duration: 10).effectiveDuration == 10)
    }

    @Test func onceClampsAndFinishes() {
        let c = clip(.once)
        #expect(c.clipTime(forPlayhead: 2) == (2, false))
        #expect(c.clipTime(forPlayhead: 4) == (4, true))
        #expect(c.clipTime(forPlayhead: 9) == (4, true))
    }

    @Test func loopWraps() {
        let c = clip(.loop)
        #expect(c.clipTime(forPlayhead: 5).time == 1)
        #expect(c.clipTime(forPlayhead: 5).finished == false)
    }

    @Test func pingPongBounces() {
        let c = clip(.pingPong)
        #expect(c.clipTime(forPlayhead: 3).time == 3)
        #expect(c.clipTime(forPlayhead: 5).time == 3)  // 2·4 − 5
        #expect(c.clipTime(forPlayhead: 8).time == 0)
        #expect(c.clipTime(forPlayhead: 9).time == 1)
    }

    @Test func zeroDurationEvaluatesAtZero() {
        let c = AnimationClip(loop: .loop, tracks: [])
        #expect(c.clipTime(forPlayhead: 7).time == 0)
    }
}

// MARK: - Player

@Suite("AnimationPlayer")
struct AnimationPlayerTests {
    /// Scalar additive param "p.x" default 10, plus a multiplicative and a
    /// replace param for composition coverage. Instant smoothing everywhere.
    private func makeWorld() throws -> (
        clock: FixedStepClock, engine: ModulationEngine, player: AnimationPlayer,
        slotX: Int, slotM: Int, slotR: Int
    ) {
        let clock = FixedStepClock(step: 0.25)  // 4 fps: easy math
        let engine = try makeEngine(
            [
                spec("p.x", default: 10),
                spec("p.m", range: 0...100, default: 2, composition: .multiplicative),
                spec("p.r", range: 0...10, default: 1, composition: .replace),
            ], clock: clock)
        let player = AnimationPlayer(layout: engine.layout)
        let slotX = engine.layout.slot(for: ParamKey("p.x"))!
        let slotM = engine.layout.slot(for: ParamKey("p.m"))!
        let slotR = engine.layout.slot(for: ParamKey("p.r"))!
        return (clock, engine, player, slotX, slotM, slotR)
    }

    private func frame(
        _ clock: FixedStepClock, _ player: AnimationPlayer, _ engine: ModulationEngine
    ) -> ResolvedParams {
        clock.advance()
        player.step(engine: engine, scaledDelta: clock.delta * clock.timeScale)
        return engine.resolve()
    }

    private func rampClip(param: String = "p.x", mode: TrackMode) -> AnimationClip {
        AnimationClip(
            name: "ramp", loop: .once,
            tracks: [AnimationTrack(param: ParamKey(param), mode: mode, keyframes: [
                Keyframe(time: 0, value: 0), Keyframe(time: 1, value: 8),
            ])])
    }

    @Test func offsetTrackAddsOnTopOfBase() throws {
        let w = try makeWorld()
        w.player.setClip(rampClip(mode: .offset))
        w.player.play()
        // Frame 1 advances playhead to 0.25 → track value 2 → 10 + 2.
        let r = frame(w.clock, w.player, w.engine)
        #expect(r.values[w.slotX] == 12)
    }

    @Test func absoluteTrackReplacesBase() throws {
        let w = try makeWorld()
        w.player.setClip(rampClip(mode: .absolute))
        w.player.play()
        let r = frame(w.clock, w.player, w.engine)
        #expect(r.values[w.slotX] == 2)  // resolved == track value, base inverted out
    }

    @Test func absoluteMultiplicativeAndReplace() throws {
        let w = try makeWorld()
        w.player.setClip(AnimationClip(loop: .once, tracks: [
            AnimationTrack(param: ParamKey("p.m"), mode: .absolute, keyframes: [
                Keyframe(time: 0, value: 6), Keyframe(time: 10, value: 6),
            ]),
            AnimationTrack(param: ParamKey("p.r"), mode: .absolute, keyframes: [
                Keyframe(time: 0, value: 7), Keyframe(time: 10, value: 7),
            ]),
        ]))
        w.player.play()
        let r = frame(w.clock, w.player, w.engine)
        #expect(abs(r.values[w.slotM] - 6) < 1e-5)  // base 2, lane write 3
        #expect(r.values[w.slotR] == 7)
    }

    @Test func stopZeroesTheLaneAndOtherLanesSurvive() throws {
        let w = try makeWorld()
        // A user offset that must survive playback + stop (plan §3.2).
        w.engine.write(lane: .user, slot: w.slotX, value: 5)
        w.player.setClip(rampClip(mode: .offset))
        w.player.play()
        var r = frame(w.clock, w.player, w.engine)
        #expect(r.values[w.slotX] == 17)  // 10 + anim 2 + user 5

        w.player.stop()
        r = frame(w.clock, w.player, w.engine)
        #expect(r.values[w.slotX] == 15)  // animation lane released, user survives
        #expect(w.engine.currentValue(lane: .animation, slot: w.slotX) == nil)
    }

    @Test func pauseFreezesPlayheadAndHoldsPose() throws {
        let w = try makeWorld()
        w.player.setClip(rampClip(mode: .offset))
        w.player.play()
        _ = frame(w.clock, w.player, w.engine)  // playhead 0.25 → +2
        w.player.pause()
        let r1 = frame(w.clock, w.player, w.engine)
        let r2 = frame(w.clock, w.player, w.engine)
        #expect(r1.values[w.slotX] == 12)
        #expect(r2.values[w.slotX] == 12)
        #expect(w.player.playbackState.isPlaying == false)
    }

    @Test func onceFinishesAndHoldsFinalPose() throws {
        let w = try makeWorld()
        w.player.setClip(rampClip(mode: .offset))  // duration 1 s = 4 frames
        w.player.play()
        for _ in 0..<6 { _ = frame(w.clock, w.player, w.engine) }
        #expect(w.player.isFinished)
        #expect(w.player.playbackState.isPlaying == false)
        let r = frame(w.clock, w.player, w.engine)
        #expect(r.values[w.slotX] == 18)  // holds 10 + 8
        // Re-play restarts from 0.
        w.player.play()
        #expect(w.player.playhead == 0)
        let r2 = frame(w.clock, w.player, w.engine)
        #expect(r2.values[w.slotX] == 12)
    }

    @Test func seekWhileStoppedShowsPoseWithoutPlaying() throws {
        let w = try makeWorld()
        w.player.setClip(rampClip(mode: .offset))
        w.player.seek(to: 0.5)
        let r = frame(w.clock, w.player, w.engine)
        #expect(r.values[w.slotX] == 14)  // 10 + 4
        #expect(w.player.playbackState.isPlaying == false)
    }

    @Test func swappingClipsReleasesOldClipSlots() throws {
        let w = try makeWorld()
        w.player.setClip(rampClip(param: "p.x", mode: .offset))
        w.player.seek(to: 1)
        _ = frame(w.clock, w.player, w.engine)
        #expect(w.engine.currentValue(lane: .animation, slot: w.slotX) != nil)

        // Swap to a clip on a DIFFERENT param: the old slot must be released.
        w.player.setClip(AnimationClip(loop: .once, tracks: [
            AnimationTrack(param: ParamKey("p.r"), mode: .offset, keyframes: [
                Keyframe(time: 0, value: 3)
            ])
        ]))
        let r = frame(w.clock, w.player, w.engine)
        #expect(w.engine.currentValue(lane: .animation, slot: w.slotX) == nil)
        #expect(r.values[w.slotX] == 10)
    }

    @Test func structuralSkipsAreCountedNotFatal() throws {
        let w = try makeWorld()
        w.player.setClip(AnimationClip(loop: .once, tracks: [
            AnimationTrack(param: ParamKey("no.such.param"), keyframes: [
                Keyframe(time: 0, value: 1)
            ]),
            AnimationTrack(param: ParamKey("p.x"), keyframes: [
                Keyframe(time: 0, values: [1, 2, 3])  // width mismatch (scalar param)
            ]),
            AnimationTrack(param: ParamKey("p.x"), keyframes: []),  // empty
            AnimationTrack(param: ParamKey("p.x"), mode: .offset, keyframes: [
                Keyframe(time: 0, value: 1)
            ]),
        ]))
        #expect(w.player.lastSkippedCount == 3)
        w.player.play()
        let r = frame(w.clock, w.player, w.engine)
        #expect(r.values[w.slotX] == 11)  // the one valid track still runs
    }

    @Test func pausedClockFreezesPlayback() throws {
        let w = try makeWorld()
        w.player.setClip(rampClip(mode: .offset))
        w.player.play()
        _ = frame(w.clock, w.player, w.engine)
        w.clock.paused = true
        _ = frame(w.clock, w.player, w.engine)
        _ = frame(w.clock, w.player, w.engine)
        #expect(w.player.playhead == 0.25)  // did not advance while paused
    }

    @Test func deterministicAcrossRuns() throws {
        func run() throws -> [Float] {
            let w = try makeWorld()
            w.player.setClip(AnimationClip(loop: .pingPong, tracks: [
                AnimationTrack(param: ParamKey("p.x"), mode: .offset, keyframes: [
                    Keyframe(time: 0, value: 0, interpolation: .smooth),
                    Keyframe(time: 0.7, value: 5, interpolation: .linear),
                    Keyframe(time: 1.3, value: -2, interpolation: .step),
                    Keyframe(time: 2, value: 1),
                ])
            ]))
            w.player.play()
            var out: [Float] = []
            for _ in 0..<40 {
                out.append(frame(w.clock, w.player, w.engine).values[w.slotX])
            }
            return out
        }
        #expect(try run() == run())
    }
}

// MARK: - Codec

@Suite(".threshanim codec")
struct AnimationCodecTests {
    private var sample: AnimationEnvelope {
        AnimationEnvelope(clip: AnimationClip(
            name: "orbit", loop: .pingPong, duration: 12,
            tracks: [
                AnimationTrack(param: ParamKey("p.x"), mode: .absolute, keyframes: [
                    Keyframe(time: 0, value: 1, interpolation: .smooth),
                    Keyframe(time: 12, value: 4, interpolation: .step),
                ]),
                AnimationTrack(param: ParamKey("cam.pos"), mode: .offset, keyframes: [
                    Keyframe(time: 0, values: [0, 0, 3]),
                ]),
            ]))
    }

    @Test func roundTrips() throws {
        let data = try AnimationCodec.encode(sample)
        let decoded = try AnimationCodec.decode(data)
        #expect(decoded == sample)
    }

    @Test func encodeIsDeterministic() throws {
        #expect(try AnimationCodec.encode(sample) == AnimationCodec.encode(sample))
    }

    @Test func unknownTopLevelKeysSurvive() throws {
        let json = """
            {"version": 1, "loop": "loop", "tracks": [],
             "futureThing": {"a": [1, 2]}}
            """
        let decoded = try AnimationCodec.decode(Data(json.utf8))
        #expect(decoded.unknown["futureThing"] != nil)
        let reencoded = try AnimationCodec.decode(AnimationCodec.encode(decoded))
        #expect(reencoded.unknown["futureThing"] == decoded.unknown["futureThing"])
    }

    @Test func unknownEnumNamesDegradeGracefully() throws {
        let json = """
            {"version": 1, "loop": "hyperloop", "tracks": [
              {"param": "p.x", "mode": "quantum", "keyframes": [
                {"time": 0, "values": [1], "interpolation": "bezier"}]}]}
            """
        let decoded = try AnimationCodec.decode(Data(json.utf8))
        #expect(decoded.clip.loop == .once)
        #expect(decoded.clip.tracks[0].mode == .offset)
        #expect(decoded.clip.tracks[0].keyframes[0].interpolation == .linear)
    }

    @Test func newerVersionIsRejected() {
        let json = #"{"version": 99, "tracks": []}"#
        #expect(throws: SceneCodecError.unsupportedVersion(99)) {
            try AnimationCodec.decode(Data(json.utf8))
        }
    }

    @Test func missingAndCorruptVersionsAreMalformed() {
        for json in [
            #"{"tracks": []}"#,
            #"{"version": 1e300, "tracks": []}"#,
            #"[1, 2, 3]"#,
            "not json",
        ] {
            #expect(throws: SceneCodecError.self) {
                try AnimationCodec.decode(Data(json.utf8))
            }
        }
    }
}
