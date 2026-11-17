import AVFoundation
import Foundation
import Testing
@testable import GullfireKit

/// Generated tones only (public domain by construction), written into a temporary folder.
private func writeTone(_ url: URL, hz: Double, seconds: Double, sampleRate: Double = 44100, channels: Int = 2) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<channels {
        let p = buffer.floatChannelData![c]
        for i in 0..<Int(frames) { p[i] = Float(0.1 * sin(2 * .pi * hz * Double(i) / sampleRate)) }
    }
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ])
    try file.write(from: buffer)
}

private func makeFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gullfire-music-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
    return root
}

@Suite("Music library")
struct MusicLibraryTests {
    @Test func scanFindsPlayableFilesInSubfoldersAndSkipsTheRest() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTone(root.appendingPathComponent("a.wav"), hz: 440, seconds: 1)
        try writeTone(root.appendingPathComponent("sub/b.wav"), hz: 550, seconds: 1)
        try writeTone(root.appendingPathComponent("sub/deeper/c.caf"), hz: 660, seconds: 1)
        try writeTone(root.appendingPathComponent(".hidden.wav"), hz: 770, seconds: 1)
        try "not audio".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try Data(repeating: 7, count: 2048).write(to: root.appendingPathComponent("broken.mp3"))
        try Data().write(to: root.appendingPathComponent("empty.wav"))

        let result = MusicLibrary.scan(folder: root)
        // Path order: a.wav, sub/b.wav, sub/deeper/c.caf. The hidden file is not listed.
        #expect(result.tracks.map(\.lastPathComponent) == ["a.wav", "b.wav", "c.caf"])
        #expect(Set(result.skipped.map(\.url.lastPathComponent)) == ["broken.mp3", "empty.wav"])
    }

    @Test func emptyOrMissingFolderGivesNoTracks() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        #expect(MusicLibrary.scan(folder: missing).tracks.isEmpty)
    }

    @Test func shuffleKeepsEveryTrackAndFollowsTheGenerator() {
        struct Counter: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        }
        let tracks = (0..<20).map { URL(fileURLWithPath: "/t/\($0).wav") }
        var g1 = Counter(state: 1), g2 = Counter(state: 1)
        let a = MusicLibrary.shuffled(tracks, using: &g1), b = MusicLibrary.shuffled(tracks, using: &g2)
        #expect(a == b)
        #expect(Set(a) == Set(tracks))
        #expect(a != tracks)
    }
}

@Suite("Crossfade plan")
struct CrossfadePlanTests {
    @Test func gainsRunFromOutgoingToIncomingAtEqualPower() {
        let start = CrossfadePlan.gains(progress: 0), end = CrossfadePlan.gains(progress: 1)
        #expect(start.outgoing == 1 && start.incoming == 0)
        #expect(abs(end.outgoing) < 1e-6 && end.incoming == 1)
        for step in 0...100 {
            let g = CrossfadePlan.gains(progress: Double(step) / 100)
            #expect(abs(g.outgoing * g.outgoing + g.incoming * g.incoming - 1) < 1e-5)
        }
        // Outside 0...1 it holds the end values.
        #expect(CrossfadePlan.gains(progress: -1).outgoing == 1)
        #expect(CrossfadePlan.gains(progress: 2).incoming == 1)
    }

    @Test func gainsOnlyMoveOneWay() {
        var last = CrossfadePlan.gains(progress: 0)
        for step in 1...100 {
            let g = CrossfadePlan.gains(progress: Double(step) / 100)
            #expect(g.outgoing <= last.outgoing && g.incoming >= last.incoming)
            last = g
        }
    }

    @Test func fadeIsShortenedForShortTracksAndStartsEarlyEnough() {
        #expect(CrossfadePlan.effectiveFade(requested: 5, outgoing: 200, incoming: 200) == 5)
        #expect(CrossfadePlan.effectiveFade(requested: 5, outgoing: 6, incoming: 200) == 3)
        #expect(CrossfadePlan.effectiveFade(requested: 5, outgoing: 200, incoming: 4) == 2)
        #expect(CrossfadePlan.effectiveFade(requested: 0, outgoing: 200, incoming: 200) == 0)
        #expect(CrossfadePlan.fadeStart(duration: 200, fade: 5) == 195)
        #expect(CrossfadePlan.fadeStart(duration: 3, fade: 5) == 0)
    }
}

/// Blocks the calling (main) thread. A plain function, because `Thread.sleep` is refused in async code.
private func blockMainThread(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

/// Records the mixed music from the player's tap into a CAF file, then analyses it.
private final class TapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    let url: URL
    init(url: URL) { self.url = url }
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if file == nil { file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings) }
        try? file?.write(from: buffer)
    }
    func finish() { lock.lock(); file = nil; lock.unlock() }
}

private struct Capture {
    var left: [Float]
    var right: [Float]
    var rate: Double
    var count: Int { left.count }
    /// RMS over both channels of each 50 ms window. A mono file may land in one channel or both; this counts either.
    var windows: [Double] {
        let n = Int(rate * 0.05)
        return stride(from: 0, to: count - n, by: n).map { start in
            var sum = 0.0
            for i in start..<(start + n) { sum += Double(left[i] * left[i] + right[i] * right[i]) / 2 }
            return (sum / Double(n)).squareRoot()
        }
    }
    /// Window indices of the first and last sound, and the seconds between.
    func audible(threshold: Double) -> (start: Int, end: Int, seconds: Double)? {
        let w = windows
        guard let first = w.firstIndex(where: { $0 > threshold }), let last = w.lastIndex(where: { $0 > threshold }) else { return nil }
        return (first, last, Double(last - first + 1) * 0.05)
    }
    /// The largest sample-to-sample change in either channel between two sample indices.
    func largestStep(from: Int, to: Int) -> Float {
        var step: Float = 0
        for i in (from + 1)..<to {
            step = max(step, abs(left[i] - left[i - 1]), abs(right[i] - right[i - 1]))
        }
        return step
    }
}

private func readCapture(_ url: URL) throws -> Capture {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let n = Int(buffer.frameLength)
    let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
    let right = file.processingFormat.channelCount > 1 ? Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n)) : left
    return Capture(left: left, right: right, rate: file.processingFormat.sampleRate)
}

/// Every title the player shows, in order, recorded by observation (see playsThroughThreeTracksAndLoops).
/// Each change is seen when it happens; the observation is re-armed after every change.
@MainActor
final class TitleLog {
    private(set) var seen: [String] = []
    private let player: CrossfadePlayer
    init(_ player: CrossfadePlayer) {
        self.player = player
        seen = [player.currentTitle]
        watch()
    }

    private func watch() {
        withObservationTracking {
            _ = player.currentTitle
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.player.currentTitle != self.seen.last { self.seen.append(self.player.currentTitle) }
                self.watch()
            }
        }
    }
}

@MainActor
@Suite("Crossfade audio", .serialized)
struct CrossfadeAudioTests {
    @MainActor
    @Suite("Crossfade player", .serialized)
    struct CrossfadePlayerTests {
        /// Runs the real engine with the output muted, and watches the title change as tracks blend.
        @Test func playsThroughThreeTracksAndLoops() async throws {
            let root = try makeFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let urls = ["one", "two", "three"].enumerated().map { root.appendingPathComponent("\($1).wav") }
            for (i, url) in urls.enumerated() { try writeTone(url, hz: 440 + 110 * Double(i), seconds: 2) }
            let player = CrossfadePlayer()
            player.outputVolume = 0
            player.fadeSeconds = 0.5
            player.start(tracks: urls)
            // Every change of the title is recorded through Observation, not sampled, so a title shown for less
            // than one poll interval cannot be missed.
            let log = TitleLog(player)
            for _ in 0..<110 {                                // 11 s: three 2 s tracks overlapped by 0.5 s, then back to the first
                try await Task.sleep(for: .milliseconds(100))
            }
            player.stop()
            let seen = log.seen
            #expect(Array(seen.prefix(4)) == ["one", "two", "three", "one"])
            #expect(!player.isOn && player.currentTitle.isEmpty)
        }

        @Test func pauseStopsTheClockAndNextBlendsAtOnce() async throws {
            let root = try makeFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let urls = ["a", "b"].map { root.appendingPathComponent("\($0).wav") }
            for (i, url) in urls.enumerated() { try writeTone(url, hz: 440 + 110 * Double(i), seconds: 30) }
            let player = CrossfadePlayer()
            player.outputVolume = 0
            player.fadeSeconds = 0.4
            player.start(tracks: urls)
            try await Task.sleep(for: .milliseconds(150))
            #expect(player.currentTitle == "a" && player.isPlaying)
            player.togglePlayPause()
            #expect(!player.isPlaying)
            player.togglePlayPause()
            #expect(player.isPlaying)
            player.next()
            for _ in 0..<20 where player.currentTitle != "b" { try await Task.sleep(for: .milliseconds(50)) }
            #expect(player.currentTitle == "b")
            try await Task.sleep(for: .milliseconds(700))
            #expect(player.currentTitle == "b" && player.isPlaying)
            player.stop()
        }
    }

    @MainActor
    @Suite("Crossfade on the audio clock", .serialized)
    struct CrossfadeCaptureTests {
        /// Plays two generated tracks through the real engine, muted, taps the mixed music and checks it.
        private func record(_ a: URL, _ b: URL, fade: Double, lookahead: Double, seconds: Double, stall: (after: Double, for: Double)? = nil) async throws -> Capture {
            let player = CrossfadePlayer()
            player.outputVolume = 0
            player.fadeSeconds = fade
            player.lookahead = lookahead
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: out) }
            let recorder = TapRecorder(url: out)
            player.installTap { recorder.write($0) }
            player.start(tracks: [a, b])
            var waited = 0.0
            while waited < seconds {
                try await Task.sleep(for: .milliseconds(50))
                waited += 0.05
                if let stall, abs(waited - stall.after) < 0.025 { blockMainThread(stall.for); waited += stall.for }
            }
            player.removeTap()
            player.stop()
            recorder.finish()
            return try readCapture(out)
        }

        /// No window quiet enough to be a gap and no step big enough to be a click, from the first sound to the
        /// end of the recording. The two tracks loop, so the music must still be playing at the end: a late
        /// start of the second track would leave a quiet stretch, and the loop would not show it as a short span.
        private func expectSmooth(_ c: Capture, level: Double, maxStep: Float, minimumSeconds: Double) throws {
            let span = try #require(c.audible(threshold: level * 0.3))
            let w = c.windows
            let quietest = w[span.start...span.end].min() ?? 0
            let q = w[span.start...span.end].firstIndex(of: quietest) ?? 0
            #expect(quietest > level * 0.5, "quietest 50 ms window \(quietest) at \(Double(q) * 0.05) s, steady level \(level); windows \(w[span.start...span.end].map { String(format: "%.2f", $0) }.joined(separator: " "))")
            let from = c.count * span.start / w.count, to = min(c.count - 1, c.count * (span.end + 1) / w.count)
            let step = c.largestStep(from: from, to: to)
            #expect(step < maxStep, "largest step \(step)")
            #expect(span.seconds > minimumSeconds, "audible \(span.seconds) s from window \(span.start) of \(w.count), recording \(Double(c.count) / c.rate) s, loud windows after: \(w.enumerated().filter { $0.offset > span.end && $0.element > 0.01 }.map { String(format: "%.2f", Double($0.offset) * 0.05) }.prefix(6)), wanted more than \(minimumSeconds) s")
        }

        @Test(arguments: [(44100.0, 2, 48000.0, 2), (48000.0, 1, 44100.0, 2), (44100.0, 2, 44100.0, 1)])
        func blendsMixedFormatsWithoutGapOrClick(rateA: Double, channelsA: Int, rateB: Double, channelsB: Int) async throws {
            let root = try makeFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let a = root.appendingPathComponent("a.wav"), b = root.appendingPathComponent("b.wav")
            try writeTone(a, hz: 440, seconds: 3, sampleRate: rateA, channels: channelsA)
            try writeTone(b, hz: 660, seconds: 3, sampleRate: rateB, channels: channelsB)
            let c = try await record(a, b, fade: 0.5, lookahead: 1.0, seconds: 7)
            // A, then B (blended in 0.5 s before A ends), then A again: 7 s recorded, so well over 6 s of continuous sound.
            try expectSmooth(c, level: 0.07, maxStep: 0.03, minimumSeconds: 6)
        }

        @Test func fadeStartsOnTimeEvenAfterTheMainThreadStalls() async throws {
            let root = try makeFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let a = root.appendingPathComponent("a.wav"), b = root.appendingPathComponent("b.wav")
            try writeTone(a, hz: 440, seconds: 4)
            try writeTone(b, hz: 660, seconds: 4)
            // The main thread is blocked for 1.5 s from 1.0 s, past the point (1.5 s) where the next track is
            // scheduled. It is scheduled late but still ahead of the fade, because the start is on the audio clock.
            let c = try await record(a, b, fade: 0.5, lookahead: 2.0, seconds: 8.5, stall: (after: 1.0, for: 1.5))
            try expectSmooth(c, level: 0.07, maxStep: 0.03, minimumSeconds: 7.5)
        }
    }
}
