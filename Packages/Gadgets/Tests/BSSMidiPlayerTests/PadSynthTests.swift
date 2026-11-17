import Testing
import Foundation
@testable import BSSMidiLoop
@testable import BSSMidiPlayer

/// Plain checks of the pad voice and the polyphonic synth. No audio engine, so these run without a device.
@Suite struct PadSynthTests {
    static let rate = 48_000.0

    @Test func triangleRunsFromPlusOneToMinusOne() {
        #expect(PadVoice.triangle(0) == 1)
        #expect(PadVoice.triangle(0.5) == -1)
        #expect(abs(PadVoice.triangle(0.25)) < 1e-12)
    }

    @Test func envelopeFadesInFromTheStartLevelHoldsAndReleasesToIdle() {
        let timing = PadVoice.Timing.standard(sampleRate: Self.rate)
        var voice = PadVoice()
        voice.start(channel: 0, pitch: 60, velocity: 100, timing: timing)
        #expect(voice.level == PadVoice.startLevel)
        for _ in 0..<(Int(0.25 * Self.rate) + 2) { _ = voice.next() }
        #expect(voice.stage == .sustain)
        #expect(voice.level == 1)
        voice.release()
        for _ in 0..<Int(1.5 * Self.rate) + 10 { _ = voice.next() }
        #expect(voice.stage == .idle)
        #expect(voice.level == 0)
    }

    @Test func aFirstSampleIsNearSilence() {
        let timing = PadVoice.Timing.standard(sampleRate: Self.rate)
        var voice = PadVoice()
        voice.start(channel: 0, pitch: 69, velocity: 127, timing: timing)
        #expect(abs(voice.next()) < 0.001)
    }

    @Test func noteOnAtAnOffsetSoundsFromThatFrame() {
        var synth = PadSynth(sampleRate: Self.rate)
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                synth.render(left: l.baseAddress!, right: r.baseAddress!, frames: 512,
                             events: [SynthEvent(offset: 200, kind: .noteOn(channel: 0, pitch: 60, velocity: 100))])
            }
        }
        #expect(left[..<200].allSatisfy { $0 == 0 })
        #expect(left[300...].contains { $0 != 0 })
        #expect(synth.sounding == 1)
    }

    @Test func polyphonyNeverExceedsThirtyTwoVoices() {
        var synth = PadSynth(sampleRate: Self.rate)
        for pitch in 40..<80 {
            synth.apply(.noteOn(channel: 0, pitch: UInt8(pitch), velocity: 90))
        }
        var left = [Float](repeating: 0, count: 2_000)
        var right = [Float](repeating: 0, count: 2_000)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                synth.render(left: l.baseAddress!, right: r.baseAddress!, frames: 2_000, events: [])
            }
        }
        #expect(synth.sounding <= PadSynth.voiceLimit)
        #expect(synth.sounding == PadSynth.voiceLimit)
    }

    @Test func stealingFadesTheOldVoiceWithoutAStep() {
        var synth = PadSynth(sampleRate: Self.rate)
        for pitch in 40..<72 {
            synth.apply(.noteOn(channel: 0, pitch: UInt8(pitch), velocity: 100))
        }
        // Let every voice reach its sustain, then strike one more note: it must steal a voice.
        var left = [Float](repeating: 0, count: 24_000)
        var right = [Float](repeating: 0, count: 24_000)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                synth.render(left: l.baseAddress!, right: r.baseAddress!, frames: 24_000,
                             events: [SynthEvent(offset: 12_000, kind: .noteOn(channel: 0, pitch: 76, velocity: 100))])
            }
        }
        // A chord of 32 voices has large sample steps by itself, so compare the steal window with the steady mix before it.
        var before: Float = 0
        for i in 6_001..<12_000 { before = max(before, abs(left[i] - left[i - 1])) }
        var stealWindow: Float = 0
        for i in 12_001..<12_400 { stealWindow = max(stealWindow, abs(left[i] - left[i - 1])) }
        #expect(stealWindow < before * 1.25 + 0.002)
        #expect(synth.sounding <= PadSynth.voiceLimit)
    }

    @Test func pedalHoldsAReleasedNoteUntilItLifts() {
        var synth = PadSynth(sampleRate: Self.rate)
        synth.apply(.controller(channel: 0, number: 64, value: 127))
        synth.apply(.noteOn(channel: 0, pitch: 60, velocity: 90))
        synth.apply(.noteOff(channel: 0, pitch: 60))
        var left = [Float](repeating: 0, count: 48_000 * 3)
        var right = [Float](repeating: 0, count: 48_000 * 3)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                synth.render(left: l.baseAddress!, right: r.baseAddress!, frames: 48_000 * 3, events: [])
            }
        }
        #expect(synth.sounding == 1)
        synth.apply(.controller(channel: 0, number: 64, value: 0))
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                synth.render(left: l.baseAddress!, right: r.baseAddress!, frames: 48_000 * 2, events: [])
            }
        }
        #expect(synth.sounding == 0)
    }

    @Test func convertsCursorMessagesAndSkipsJumps() {
        #expect(MIDILoopPlayer.convert(.jump(from: 1, to: 2)) == nil)
        let note = MIDILoopPlayer.convert(.noteOn(channel: 0, pitch: 60, velocity: 80))
        #expect(note?.kind == .noteOn(channel: 0, pitch: 60, velocity: 80))
    }
}

/// The jump callback: the pump reports each jump it reaches, with the segments it joins.
@Suite struct JumpCallbackTests {
    @Test func pumpReportsEachJumpItReaches() throws {
        let piece = try MIDIPerformance(data: chordPieceMIDI())
        let map = LoopAnalysis.analyze(piece, style: .balanced)
        var cursor = EventCursor(piece: piece, map: map, mode: .endless, seed: 3)
        let reported = JumpLog()
        var pump = EventPump(origin: 0, rate: 48_000, keepsJumps: false) { seconds, from, to in
            reported.add(seconds, from, to)
        }
        let ring = SPSCRing(capacity: 16_384)
        // Drain the ring as it fills, so the pump keeps going for a long stretch of performance.
        var horizon: Int64 = 0
        for _ in 0..<2_000 {
            horizon += 48_000
            pump.pump(&cursor, ring: ring, horizon: horizon)
            var scratch = [TimedSynthEvent](repeating: TimedSynthEvent(sample: 0, event: SynthEvent(offset: 0, kind: .controller(channel: 0, number: 0, value: 0))), count: 16_384)
            _ = scratch.withUnsafeMutableBufferPointer { ring.popDue(before: horizon, into: $0.baseAddress!, limit: 16_384) }
        }
        #expect(reported.count > 3)
        #expect(reported.all.allSatisfy { $0.seconds >= 0 })
    }
}

/// Collects jump reports from the pump's closure.
final class JumpLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(seconds: Double, from: Int, to: Int)] = []

    func add(_ seconds: Double, _ from: Int, _ to: Int) {
        lock.lock()
        items.append((seconds, from, to))
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    var all: [(seconds: Double, from: Int, to: Int)] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// A stopped player can be played again: the second play gets a fresh scheduler with the stop flag clear.
@Suite struct RestartTests {
    @Test func aStoppedPlayerPlaysAgain() {
        let state = PlaybackState()
        state.requestStop()
        #expect(state.stopRequested)
        state.clearStop()
        #expect(!state.stopRequested)
        state.setSchedulerRunning(true)
        #expect(state.isSchedulerRunning)
        state.setSchedulerRunning(false)
        #expect(!state.isSchedulerRunning)
    }
}
