import Testing
import Foundation
import AVFAudio
@testable import BSSMidiLoop
@testable import BSSMidiPlayer

/// Collects the tapped left channel from the audio thread.
final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate = 48_000.0

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        lock.lock()
        rate = buffer.format.sampleRate
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func snapshot() -> (samples: [Float], rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, rate)
    }
}

/// A 16-bar chord piece with a sustain pedal across bars, written here in code (no real score).
func chordPieceMIDI() -> Data {
    var events: [(tick: Int, bytes: [UInt8])] = []
    let division = 480
    let bar = 4 * division
    events.append((0, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]))        // 120 bpm
    events.append((0, [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]))  // 4/4
    events.append((bar, [0xB0, 64, 127]))
    events.append((3 * bar, [0xB0, 64, 0]))
    let progression: [[UInt8]] = [[48, 55, 60, 64], [45, 52, 57, 60], [41, 48, 53, 57], [43, 50, 55, 59]]
    for b in 0..<16 {
        for pitch in progression[b % 4] {
            events.append((b * bar, [0x90, pitch, 80]))
            events.append((b * bar + bar - 1, [0x80, pitch, 0]))
        }
    }
    var body: [UInt8] = []
    var last = 0
    for event in events.sorted(by: { $0.tick < $1.tick }) {
        body += variableLength(event.tick - last)
        body += event.bytes
        last = event.tick
    }
    body += [0x00, 0xFF, 0x2F, 0x00]
    var out: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
    out += Array("MTrk".utf8) + [UInt8((body.count >> 24) & 0xFF), UInt8((body.count >> 16) & 0xFF),
                                 UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)]
    out += body
    return Data(out)
}

func variableLength(_ value: Int) -> [UInt8] {
    var groups = [UInt8(value & 0x7F)]
    var rest = value >> 7
    while rest > 0 {
        groups.insert(UInt8((rest & 0x7F) | 0x80), at: 0)
        rest >>= 7
    }
    return groups
}

/// One tap run: a real engine, the pad through its reverb, the output muted, and the reverb's output tapped.
/// `actions` run on the test thread at the given times (seconds from the start of play).
struct TapRun {
    /// The samples while play was running (up to the stop). The release after stop is not part of play.
    let samples: [Float]
    /// The release after stop, for the silence checks.
    let afterStop: [Float]
    let rate: Double
    let piece: MIDIPerformance
    /// Seconds from stop until no synth voice is sounding; nil if one was still sounding at the end of the wait.
    let voicesIdleAfterStop: Double?
    /// Render callbacks that ran past the events the scheduler had queued.
    let underruns: Int

    static func run(seconds: Double, tail: Double = 3, seed: UInt64 = 9,
                    actions: [(at: Double, action: (MIDILoopPlayer) -> Void)] = []) throws -> TapRun {
        let piece = try MIDIPerformance(data: chordPieceMIDI())
        let map = LoopAnalysis.analyze(piece, style: .balanced)

        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        mixer.outputVolume = 0

        let player = try MIDILoopPlayer(engine: engine, output: mixer)
        let recorder = SampleRecorder()
        player.reverbNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, _ in
            recorder.append(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play(EventCursor(piece: piece, map: map, mode: .endless, seed: seed))

        let started = Date()
        for scheduled in actions.sorted(by: { $0.at < $1.at }) {
            let wait = scheduled.at - Date().timeIntervalSince(started)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            scheduled.action(player)
        }
        let rest = seconds - Date().timeIntervalSince(started)
        if rest > 0 { Thread.sleep(forTimeInterval: rest) }
        let playCount = recorder.count
        player.stop()
        let stopped = Date()
        var idleAfter: Double? = nil
        while Date().timeIntervalSince(stopped) < 6 {
            if player.soundingVoices == 0 {
                idleAfter = Date().timeIntervalSince(stopped)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let rest2 = tail - Date().timeIntervalSince(stopped)
        if rest2 > 0 { Thread.sleep(forTimeInterval: rest2) }
        let underruns = player.underruns
        player.reverbNode.removeTap(onBus: 0)
        engine.stop()

        let (samples, rate) = recorder.snapshot()
        return TapRun(samples: Array(samples[..<playCount]), afterStop: Array(samples[playCount...]), rate: rate,
                      piece: piece, voicesIdleAfterStop: idleAfter, underruns: underruns)
    }
}

/// The tap test, one at a time (real engines glitch when several run together).
@Suite(.serialized) struct PlayerTapTests {
    /// The end of the piece, in seconds from the first sound: where the planned breath may begin.
    static func pieceEnds(for piece: MIDIPerformance) -> [Double] {
        return [piece.seconds(atTick: piece.endTick)]
    }

    @Test(.timeLimit(.minutes(3)))
    func sixtySecondsOfEndlessPlayHasNoGapAndNoClick() throws {
        let run = try TapRun.run(seconds: 60)
        let report = LevelReport(samples: run.samples, rate: run.rate, pieceEnds: Self.pieceEnds(for: run.piece))
        print("TAP 60 s: first sound \(String(format: "%.3f", report.firstSound)) s; steady \(String(format: "%.4f", report.steady)); "
              + "quietest \(String(format: "%.4f", report.quietest)); raw quiet windows \(report.rawQuietWindows); "
              + "excused breaths at \(report.excusedBreaths.map { String(format: "%.2f", $0) }); gap windows \(report.gapWindows) "
              + "at \(report.gapStarts.map { String(format: "%.2f", $0) }); largest step \(String(format: "%.4f", report.largestStep)); "
              + "steps over \(LevelReport.clickLimit) \(report.clicks); longest silence \(String(format: "%.2f", report.longestSilence)) s")
        #expect(report.gapWindows == 0)
        #expect(report.clicks == 0)
        print("UNDERRUNS 60 s: \(run.underruns)")
        #expect(run.underruns == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func mainThreadStallOfOneAndAHalfSecondsLeavesNoGap() throws {
        // The main thread is not on the audio path, so blocking it changes nothing here; this run shows that.
        let run = try TapRun.run(seconds: 20, actions: [(8, { _ in Thread.sleep(forTimeInterval: 1.5) })])
        let report = LevelReport(samples: run.samples, rate: run.rate, pieceEnds: Self.pieceEnds(for: run.piece))
        print("STALL main thread 1.5 s: gap windows \(report.gapWindows) at \(report.gapStarts.map { String(format: "%.2f", $0) }); "
              + "largest step \(String(format: "%.4f", report.largestStep)); steps over limit \(report.clicks); raw quiet \(report.rawQuietWindows)")
        #expect(report.gapWindows == 0)
        #expect(report.clicks == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func schedulerStallOfOneAndAHalfSecondsLeavesNoGap() throws {
        let run = try TapRun.run(seconds: 20, actions: [(8, { $0.stallScheduler(milliseconds: 1_500) })])
        let report = LevelReport(samples: run.samples, rate: run.rate, pieceEnds: Self.pieceEnds(for: run.piece))
        print("STALL scheduler 1.5 s: gap windows \(report.gapWindows) at \(report.gapStarts.map { String(format: "%.2f", $0) }); "
              + "largest step \(String(format: "%.4f", report.largestStep)); steps over limit \(report.clicks); raw quiet \(report.rawQuietWindows)")
        #expect(report.gapWindows == 0)
        #expect(report.clicks == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func schedulerStallOfThreeSecondsIsReportedAndEndsWithoutStuckNotes() throws {
        // Beyond the two-second lookahead: the scheduler catches up. Audible damage is allowed; a stuck note is not.
        let run = try TapRun.run(seconds: 20, tail: 4, actions: [(8, { $0.stallScheduler(milliseconds: 3_000) })])
        let report = LevelReport(samples: run.samples, rate: run.rate, pieceEnds: Self.pieceEnds(for: run.piece))
        print("STALL scheduler 3 s: gap windows \(report.gapWindows) at \(report.gapStarts.map { String(format: "%.2f", $0) }); "
              + "largest step \(String(format: "%.4f", report.largestStep)); steps over limit \(report.clicks); "
              + "longest silence \(String(format: "%.2f", report.longestSilence)) s")
        // A stuck note keeps a voice sounding after stop. The reverb's own tail is not a note, so the check is on voices.
        print("UNDERRUNS scheduler 3 s stall: \(run.underruns) (render callbacks past the queued events)")
        #expect(run.underruns > 0)
        print("STALL scheduler 3 s: voices idle \(run.voicesIdleAfterStop.map { String(format: "%.2f", $0) } ?? "never") s after stop")
        #expect(run.voicesIdleAfterStop != nil)
        #expect((run.voicesIdleAfterStop ?? 99) < 3)
    }
}
