import AVFoundation
import Foundation
import Testing
@testable import GullfireKit

/// Generated tones only, written into a temporary folder. No real music is in the repository.
private func writeTone(_ url: URL, seconds: Double) throws {
    let sampleRate = 44100.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<2 {
        let p = buffer.floatChannelData![c]
        for i in 0..<Int(frames) { p[i] = Float(0.1 * sin(2 * .pi * 440 * Double(i) / sampleRate)) }
    }
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ])
    try file.write(from: buffer)
}

private func makeFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gullfire-cathedral-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    return root
}

@Suite("Cathedral finder")
struct CathedralFinderTests {
    private func length(_ name: String, _ seconds: Double) -> CathedralFinder.Length {
        CathedralFinder.Length(url: URL(fileURLWithPath: "music/\(name)"), seconds: seconds)
    }

    @Test func keepsOnlyFilesWithinTolerance() {
        let found = CathedralFinder.rank([
            length("exact.m4a", 213.3),
            length("close.flac", 214.5),
            length("too-long.m4a", 215.0),
            length("too-short.mp3", 211.7),
            length("short.wav", 200),
        ], target: 213.3, tolerance: 1.5)
        #expect(found.map(\.title) == ["exact", "close"])
    }

    @Test func nameHitsComeFirstWhateverTheLength() {
        let found = CathedralFinder.rank([
            length("plain.m4a", 213.3),
            length("1-09 Debussy Engulfed Cathedral.m4a", 213.9),
        ], target: 213.3, tolerance: 1.5)
        #expect(found.first?.nameHit == true)
        #expect(found.first?.title == "1-09 Debussy Engulfed Cathedral")
    }

    @Test func withoutANameTheClosestLengthIsFirst() {
        let found = CathedralFinder.rank([
            length("far.m4a", 212.0),
            length("near.m4a", 213.2),
            length("mid.m4a", 213.6),
        ], target: 213.3, tolerance: 1.5)
        #expect(found.map(\.title) == ["near", "mid", "far"])
    }

    @Test func formatComesFromTheExtension() {
        let match = CathedralFinder.Match(url: URL(fileURLWithPath: "x/track.m4a"), seconds: 213.3, nameHit: false)
        #expect(match.format == "M4A")
    }

    @Test func clockReadsMinutesAndSeconds() {
        #expect(CathedralFinder.clock(213.3) == "3:33")
        #expect(CathedralFinder.clock(59.6) == "1:00")
    }
}

@Suite("Cathedral fade and lookup")
struct CathedralLookupTests {
    @Test func longestLoopFadeIsHalfTheTrack() {
        #expect(abs(CrossfadePlan.longestLoopFade(duration: 213.3) - 106.65) < 0.001)
        #expect(CrossfadePlan.longestLoopFade(duration: 0) == 0)
    }

    @Test func lengthsFindsEachPlayableFileOnceAcrossOverlappingFolders() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTone(root.appendingPathComponent("three.wav"), seconds: 3)
        try writeTone(root.appendingPathComponent("sub/two.wav"), seconds: 2)
        try "not audio".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let found = MusicLibrary.lengths(in: [root, root.appendingPathComponent("sub")])
        #expect(found.count == 2)
        let three = found.first { $0.url.lastPathComponent == "three.wav" }
        #expect(abs((three?.seconds ?? 0) - 3) < 0.01)
    }

    @Test func lengthIsNilForAFileThatIsNotAudio() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes.wav")
        try "not audio".write(to: notes, atomically: true, encoding: .utf8)
        #expect(MusicLibrary.length(of: notes) == nil)
    }

    @Test func missingFolderGivesNoLengths() {
        let missing = URL(fileURLWithPath: "no-such-folder-\(UUID().uuidString)")
        #expect(MusicLibrary.lengths(in: [missing]).isEmpty)
    }
}
