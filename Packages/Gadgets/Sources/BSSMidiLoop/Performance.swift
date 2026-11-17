import Foundation

/// A MIDI piece, read and worked out for playback: its notes with the sustain pedal applied, the tempo map, the meters,
/// the keys and every controller change. Ticks are the file's own; `seconds(atTick:)` turns them into time.
public struct MIDIPerformance: Sendable {
    public struct Note: Sendable, Equatable {
        public let channel: UInt8
        public let pitch: UInt8
        public let velocity: UInt8
        /// The tick the key goes down.
        public let start: Int
        /// The tick the key comes up in the score.
        public let end: Int
        /// The tick the sound stops: `end`, or later while the sustain pedal holds the note.
        public let soundingEnd: Int
    }

    public struct Controller: Sendable, Equatable {
        public let tick: Int
        public let channel: UInt8
        public let number: UInt8
        public let value: UInt8
    }

    public struct TempoChange: Sendable, Equatable {
        public let tick: Int
        public let microseconds: Int
    }

    public struct Meter: Sendable, Equatable {
        public let tick: Int
        public let numerator: Int
        public let denominator: Int
    }

    public struct KeySignature: Sendable, Equatable {
        public let tick: Int
        public let sharps: Int
        public let minor: Bool
    }

    public let ticksPerQuarter: Int
    /// Sorted by start tick, then channel and pitch.
    public let notes: [Note]
    public let controllers: [Controller]
    public let tempo: [TempoChange]
    public let meters: [Meter]
    public let keys: [KeySignature]
    /// The last tick anything in the piece sounds or sets.
    public let endTick: Int
    /// FNV-1a 64-bit hash of the file's bytes, in hex. A loop map records it so it can tell that it belongs to this file.
    public let fingerprint: String

    struct NoteKey: Hashable, Sendable {
        let channel: UInt8
        let pitch: UInt8
    }

    struct TempoSegment: Sendable {
        let tick: Int
        let seconds: Double
        let microseconds: Int
    }

    /// One thing to play, in the order it happens. `rank` puts controllers first, then note-offs, then note-ons on one tick,
    /// so a note that is struck again on the tick it ends is cut and restruck, never left on.
    struct PlaybackEvent: Sendable {
        enum Kind: Sendable {
            case controller(Controller)
            case noteOff(Int)
            case noteOn(Int)
        }
        let tick: Int
        let rank: Int
        let kind: Kind
    }

    let playback: [PlaybackEvent]
    let barTicks: [Int]
    let pedalByChannel: [UInt8: [Controller]]
    private let tempoSegments: [TempoSegment]

    /// Pieces longer than this many ticks are refused: a hostile file cannot make the bar table enormous.
    static let maxEndTick = 100_000_000

    public init(data: Data) throws {
        let (division, tracks) = try SMFReader.read(data)

        struct RawNote {
            let channel: UInt8
            let pitch: UInt8
            let velocity: UInt8
            let start: Int
            let end: Int
        }

        var raw: [RawNote] = []
        var controllers: [Controller] = []
        var tempo: [TempoChange] = []
        var meters: [Meter] = []
        var keys: [KeySignature] = []
        var trackEnd = 0

        for track in tracks {
            // Pair note-ons with note-offs within the track, first in first out. Unmatched note-offs are ignored.
            var pending: [NoteKey: [(start: Int, velocity: UInt8)]] = [:]
            var lastTick = 0
            for event in track {
                lastTick = max(lastTick, event.tick)
                switch event.kind {
                case let .noteOn(channel, pitch, velocity):
                    pending[NoteKey(channel: channel, pitch: pitch), default: []].append((event.tick, velocity))
                case let .noteOff(channel, pitch):
                    let key = NoteKey(channel: channel, pitch: pitch)
                    guard var starts = pending[key], !starts.isEmpty else { continue }
                    let first = starts.removeFirst()
                    pending[key] = starts
                    raw.append(RawNote(channel: channel, pitch: pitch, velocity: first.velocity, start: first.start, end: event.tick))
                case let .controller(channel, number, value):
                    controllers.append(Controller(tick: event.tick, channel: channel, number: number, value: value))
                case let .tempo(microseconds):
                    tempo.append(TempoChange(tick: event.tick, microseconds: microseconds))
                case let .timeSignature(numerator, denominator):
                    meters.append(Meter(tick: event.tick, numerator: numerator, denominator: denominator))
                case let .keySignature(sharps, minor):
                    keys.append(KeySignature(tick: event.tick, sharps: sharps, minor: minor))
                }
            }
            // Notes still down at the end of the track sound until the track ends.
            for (key, starts) in pending {
                for first in starts {
                    raw.append(RawNote(channel: key.channel, pitch: key.pitch, velocity: first.velocity, start: first.start, end: lastTick))
                }
            }
            trackEnd = max(trackEnd, lastTick)
        }

        controllers.sort { $0.tick < $1.tick }
        tempo.sort { $0.tick < $1.tick }
        meters.sort { $0.tick < $1.tick }
        keys.sort { $0.tick < $1.tick }
        raw.sort { ($0.start, $0.channel, $0.pitch, $0.end) < ($1.start, $1.channel, $1.pitch, $1.end) }

        var pedal: [UInt8: [Controller]] = [:]
        for controller in controllers where controller.number == 64 {
            pedal[controller.channel, default: []].append(controller)
        }

        // The sustain pedal holds a note from its key-up until the pedal is next lifted.
        var built: [Note] = []
        built.reserveCapacity(raw.count)
        for note in raw {
            var sounding = note.end
            if let changes = pedal[note.channel] {
                let changesSoFar = indexOfFirst(in: changes) { $0.tick > note.end }
                if changesSoFar > 0, changes[changesSoFar - 1].value >= 64 {
                    if let lift = changes[changesSoFar...].first(where: { $0.value < 64 }) {
                        sounding = max(note.end, lift.tick)
                    } else {
                        sounding = max(note.end, trackEnd)
                    }
                }
            }
            built.append(Note(channel: note.channel, pitch: note.pitch, velocity: note.velocity,
                              start: note.start, end: note.end, soundingEnd: sounding))
        }

        let endTick = max(trackEnd, built.map(\.soundingEnd).max() ?? 0)
        guard endTick <= MIDIPerformance.maxEndTick else {
            throw MIDILoopError.unsupportedMIDI("a piece longer than \(MIDIPerformance.maxEndTick) ticks")
        }

        var events: [PlaybackEvent] = []
        for controller in controllers {
            events.append(PlaybackEvent(tick: controller.tick, rank: 0, kind: .controller(controller)))
        }
        for (id, note) in built.enumerated() {
            events.append(PlaybackEvent(tick: note.soundingEnd, rank: 1, kind: .noteOff(id)))
            events.append(PlaybackEvent(tick: note.start, rank: 2, kind: .noteOn(id)))
        }
        let ordered = events.enumerated()
            .sorted { ($0.element.tick, $0.element.rank, $0.offset) < ($1.element.tick, $1.element.rank, $1.offset) }
            .map(\.element)

        var segments: [TempoSegment] = [TempoSegment(tick: 0, seconds: 0, microseconds: 500_000)]
        for change in tempo {
            let last = segments[segments.count - 1]
            if change.tick <= last.tick {
                segments[segments.count - 1] = TempoSegment(tick: last.tick, seconds: last.seconds, microseconds: change.microseconds)
            } else {
                let seconds = last.seconds + Double(change.tick - last.tick) * Double(last.microseconds) / 1_000_000 / Double(division)
                segments.append(TempoSegment(tick: change.tick, seconds: seconds, microseconds: change.microseconds))
            }
        }

        self.ticksPerQuarter = division
        self.notes = built
        self.controllers = controllers
        self.tempo = tempo
        self.meters = meters
        self.keys = keys
        self.endTick = endTick
        self.fingerprint = MIDIPerformance.fingerprint(of: data)
        self.playback = ordered
        self.pedalByChannel = pedal
        self.tempoSegments = segments
        self.barTicks = MIDIPerformance.bars(endTick: endTick, division: division, meters: meters)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// Seconds from the start of the piece to a tick, following the tempo map.
    public func seconds(atTick tick: Int) -> Double {
        let t = max(0, tick)
        let index = max(0, indexOfFirst(in: tempoSegments) { $0.tick > t } - 1)
        let segment = tempoSegments[index]
        return segment.seconds + Double(t - segment.tick) * Double(segment.microseconds) / 1_000_000 / Double(ticksPerQuarter)
    }

    /// The tempo in quarter notes per minute at a tick.
    public func beatsPerMinute(atTick tick: Int) -> Double {
        let t = max(0, tick)
        let index = max(0, indexOfFirst(in: tempoSegments) { $0.tick > t } - 1)
        return 60_000_000 / Double(tempoSegments[index].microseconds)
    }

    /// The value of a channel's sustain pedal (CC 64) just before a tick: every change before it, applied in order.
    public func pedalValue(channel: UInt8, beforeTick tick: Int) -> UInt8 {
        guard let changes = pedalByChannel[channel] else { return 0 }
        let count = indexOfFirst(in: changes) { $0.tick >= tick }
        return count > 0 ? changes[count - 1].value : 0
    }

    /// Seconds in one quarter note at a tick.
    func quarterSeconds(atTick tick: Int) -> Double {
        return seconds(atTick: tick + ticksPerQuarter) - seconds(atTick: tick)
    }

    func playbackEvents(from start: Int, to end: Int) -> ArraySlice<PlaybackEvent> {
        let lower = indexOfFirst(in: playback) { $0.tick >= start }
        let upper = indexOfFirst(in: playback) { $0.tick >= end }
        return playback[lower..<max(lower, upper)]
    }

    /// Bar start ticks, with one more entry than there are bars: the last one lies past the end of the music.
    static func bars(endTick: Int, division: Int, meters: [Meter]) -> [Int] {
        var starts = [0]
        var tick = 0
        while tick <= endTick {
            var numerator = 4
            var denominator = 4
            let inForce = indexOfFirst(in: meters) { $0.tick > tick } - 1
            if inForce >= 0 {
                numerator = meters[inForce].numerator
                denominator = meters[inForce].denominator
            }
            let length = max(division, numerator * 4 * division / max(1, denominator))
            tick += length
            starts.append(tick)
        }
        return starts
    }

    static func fingerprint(of data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

/// The first index whose element is "after" the target, for an array sorted so that the predicate is false and then true.
/// Returns `array.count` when nothing is after it.
func indexOfFirst<T>(in array: [T], where isAfter: (T) -> Bool) -> Int {
    var low = 0
    var high = array.count
    while low < high {
        let middle = (low + high) / 2
        if isAfter(array[middle]) {
            high = middle
        } else {
            low = middle + 1
        }
    }
    return low
}
