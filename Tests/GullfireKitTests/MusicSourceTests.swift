import Testing
@testable import GullfireKit

@Suite("Music source")
struct MusicSourceTests {
    private static let all: [MusicSource] = [.demo(loop: false), .demo(loop: true), .folder, .cathedral,
                                             .midiFile(loop: false), .midiFile(loop: true)]

    @Test func everySourceRoundTripsThroughTheSavedKeys() {
        for source in Self.all {
            #expect(MusicState.state(for: source).source == source, "\(source)")
        }
    }

    @Test func nothingChosenPlaysTheDemoEndlessly() {
        let none = MusicState(useCathedral: false, midiMode: nil, hasMIDIFile: false, hasMusicFolder: false)
        #expect(none.source == .demo(loop: false))
    }

    @Test func aMIDIModeWinsOverTheCathedralAndTheFolderAsItDoesWhenMPressed() {
        let all = MusicState(useCathedral: true, midiMode: .loop, hasMIDIFile: true, hasMusicFolder: true)
        #expect(all.source == .midiFile(loop: true))
    }

    @Test func theCathedralWinsOverTheFolder() {
        let both = MusicState(useCathedral: true, midiMode: nil, hasMIDIFile: false, hasMusicFolder: true)
        #expect(both.source == .cathedral)
    }

    @Test func theFolderIsKeptWhenTheCathedralIsChosen() {
        // "Back to my music folder" keeps the folder, so a folder saved before the cathedral still plays.
        let back = MusicState(useCathedral: false, midiMode: nil, hasMIDIFile: false, hasMusicFolder: true)
        #expect(back.source == .folder)
    }

    @Test func theSavedKeysAreTheOnesTheAppAlreadyWrites() {
        #expect(MusicSource.savedKeys == ["musicFolder", "useCathedral", "cathedralPath", "midiMode", "midiFile"])
    }
}
