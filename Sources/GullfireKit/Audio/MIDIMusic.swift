import AVFAudio
import BSSMidiLoop
import BSSMidiPlayer
import Foundation
import Observation

/// The MIDI piece as a music source: an endless or looped plan of a MIDI file, played as a soft pad through the
/// same engine and music bus as the folder and the cathedral track. One source plays at a time; the app stops the
/// others first. Each jump is logged as it is reached: `midiloop: segment 3 -> 1, bars 31 -> 18, at 4:12`.
@MainActor
@Observable
public final class MIDIMusic {
    /// Endless: jumps are chosen as it plays. Loop: the whole piece, then the same end-of-piece jump.
    public enum Mode: String, Sendable, Equatable {
        case endless
        case loop
    }

    /// True from `start` until `stop`.
    public private(set) var isOn = false
    /// True while sound is meant to be coming out (on and not paused).
    public private(set) var isPlaying = false
    /// The title of the piece now playing (its file name without extension), empty when off.
    public private(set) var title = ""

    @ObservationIgnored private let engine: AVAudioEngine
    @ObservationIgnored private let player: MIDILoopPlayer
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var playingMode: Mode?

    /// Attaches the pad to the engine and bus the folder and cathedral sources share. Throws if the format is unusable.
    public init(engine: AVAudioEngine, output: AVAudioNode) throws {
        self.engine = engine
        self.player = try MIDILoopPlayer(engine: engine, output: output)
    }

    /// The line logged when a piece starts (4.2): the process, the piece, the mode, the seed and why it was started.
    /// Pure, so a test can check it.
    public static func playingLine(pid: Int32, title: String, mode: Mode, seed: UInt64, reason: String) -> String {
        "midiloop[pid \(pid)]: playing \(title), \(mode.rawValue), seed \(seed), reason \(reason)"
    }

    /// Plays a MIDI file. `sidecar` holds its loop map: read when it matches the file, written when it does not
    /// (a bundled file's map is read-only, so it must already match). `reason` says what asked for the start (logged).
    public func start(midi url: URL, sidecar: URL, mode: Mode, seed: UInt64, reason: String = "unspecified") throws {
        stop()
        let piece = try MIDIPerformance(contentsOf: url)
        let map = try LoopMap.load(piece, sidecar: sidecar, style: .balanced)
        let segments = map.segments
        let pid = ProcessInfo.processInfo.processIdentifier
        player.onJump = { seconds, from, to in
            let at = Int(seconds)
            let fromBar = from < segments.count ? segments[from].endBar : 0
            let toBar = to < segments.count ? segments[to].startBar : 0
            print("midiloop[pid \(pid)]: segment \(from) -> \(to), bars \(fromBar) -> \(toBar), at \(at / 60):\(String(format: "%02d", at % 60))")
        }
        if !engine.isRunning {
            try engine.start()
        }
        let cursor = EventCursor(piece: piece, map: map, mode: mode == .endless ? .endless : .loop, seed: seed)
        player.play(cursor)
        loadedURL = url
        playingMode = mode
        title = url.deletingPathExtension().lastPathComponent
        isOn = true
        isPlaying = true
        print(Self.playingLine(pid: ProcessInfo.processInfo.processIdentifier, title: title, mode: mode, seed: seed, reason: reason))
    }

    /// Stops the piece: every sounding note is released, then the engine stops (the app runs no other source now).
    public func stop() {
        guard isOn else { return }
        player.stop()
        if engine.isRunning { engine.stop() }
        isOn = false
        isPlaying = false
        title = ""
        loadedURL = nil
        playingMode = nil
    }

    /// The D9 guard (4.2): whether this piece is already playing in this mode. A start of the same piece in the same
    /// mode is then ignored, so a stray second call cannot restart it.
    public func isAlreadyPlaying(_ url: URL, mode: Mode) -> Bool {
        isOn && loadedURL == url && playingMode == mode
    }

    /// Pauses or resumes the engine, which holds the piece's place: the scheduler keeps its events ahead.
    public func togglePlayPause() {
        guard isOn else { return }
        if isPlaying {
            engine.pause()
            isPlaying = false
        } else {
            do {
                try engine.start()
                isPlaying = true
            } catch {
                print("midiloop: could not resume: \(error)")
            }
        }
    }

    /// The loop map's path for a MIDI file: `Song.mid` gives `Song.loopmap.json`.
    public static func sidecarURL(for midi: URL) -> URL {
        return LoopMap.sidecarURL(for: midi)
    }

    /// Underruns counted by the player (render callbacks that ran past the queued events). Above zero means the
    /// scheduler fell behind the audio clock.
    public var underruns: Int { player.underruns }
}
