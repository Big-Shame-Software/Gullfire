import Foundation

/// What plays when M is pressed (D2): one choice, shown as one radio group in Settings. It is a view of the
/// music settings the app already saves, not a new store: no key is renamed or dropped, and an install keeps its
/// choices (`savedKeys`).
public enum MusicSource: Equatable, Sendable {
    /// The bundled Satie demo piece, endless or as a loop.
    case demo(loop: Bool)
    /// Shuffled tracks from the music folder.
    case folder
    /// The cathedral track, looped with its fade.
    case cathedral
    /// A MIDI file the user chose, endless or as a loop.
    case midiFile(loop: Bool)

    /// The saved keys these choices are kept in (the `AppModel` keys). Never renamed or dropped.
    public static let savedKeys = ["musicFolder", "useCathedral", "cathedralPath", "midiMode", "midiFile"]
}

/// The four facts the saved keys record, which decide the source. `source` follows `AppModel.toggleMusic`: a MIDI
/// mode wins, then the cathedral, then the folder; with none of them, the demo piece plays endlessly.
public struct MusicState: Equatable, Sendable {
    public var useCathedral: Bool
    public var midiMode: MIDIMusic.Mode?
    public var hasMIDIFile: Bool
    public var hasMusicFolder: Bool

    public init(useCathedral: Bool, midiMode: MIDIMusic.Mode?, hasMIDIFile: Bool, hasMusicFolder: Bool) {
        self.useCathedral = useCathedral
        self.midiMode = midiMode
        self.hasMIDIFile = hasMIDIFile
        self.hasMusicFolder = hasMusicFolder
    }

    public var source: MusicSource {
        if let mode = midiMode {
            return hasMIDIFile ? .midiFile(loop: mode == .loop) : .demo(loop: mode == .loop)
        }
        if useCathedral { return .cathedral }
        if hasMusicFolder { return .folder }
        return .demo(loop: false)
    }

    /// The facts that record a source.
    public static func state(for source: MusicSource) -> MusicState {
        switch source {
        case .demo(let loop):
            MusicState(useCathedral: false, midiMode: loop ? .loop : .endless, hasMIDIFile: false, hasMusicFolder: false)
        case .folder:
            MusicState(useCathedral: false, midiMode: nil, hasMIDIFile: false, hasMusicFolder: true)
        case .cathedral:
            MusicState(useCathedral: true, midiMode: nil, hasMIDIFile: false, hasMusicFolder: false)
        case .midiFile(let loop):
            MusicState(useCathedral: false, midiMode: loop ? .loop : .endless, hasMIDIFile: true, hasMusicFolder: false)
        }
    }
}
