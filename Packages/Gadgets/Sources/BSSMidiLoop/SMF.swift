import Foundation

/// Why a MIDI file, or its loop map, could not be used. Every bad input becomes one of these; nothing traps.
public enum MIDILoopError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformedMIDI(String)
    case unsupportedMIDI(String)
    case invalidSidecar(String)
    case sidecarWriteFailed(String)

    public var description: String {
        switch self {
        case .malformedMIDI(let why): return "Not a readable MIDI file: \(why)"
        case .unsupportedMIDI(let why): return "MIDI file not supported: \(why)"
        case .invalidSidecar(let why): return "Loop map file is not usable: \(why)"
        case .sidecarWriteFailed(let why): return "Could not write the loop map file: \(why)"
        }
    }
}

/// One decoded event from a track, before note-ons are paired with note-offs.
struct SMFEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case noteOn(channel: UInt8, pitch: UInt8, velocity: UInt8)
        case noteOff(channel: UInt8, pitch: UInt8)
        case controller(channel: UInt8, number: UInt8, value: UInt8)
        case tempo(microseconds: Int)
        case timeSignature(numerator: Int, denominator: Int)
        case keySignature(sharps: Int, minor: Bool)
    }

    let tick: Int
    let kind: Kind
}

/// Reads a Standard MIDI File (formats 0, 1 and 2) into per-track events.
/// Running status, sysex and unknown meta events are skipped safely. Hard caps keep a hostile file from using all memory,
/// and every read is bounds-checked, so a corrupt file throws `MIDILoopError` instead of trapping.
struct SMFReader {
    static let maxTracks = 256
    static let maxEventsPerTrack = 500_000

    private let bytes: [UInt8]
    private var position = 0
    private var limit: Int

    static func read(_ data: Data) throws -> (ticksPerQuarter: Int, tracks: [[SMFEvent]]) {
        var reader = SMFReader(bytes: [UInt8](data))
        return try reader.parseFile()
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
        self.limit = bytes.count
    }

    private func failure(_ why: String) -> MIDILoopError {
        return .malformedMIDI("\(why), at byte \(position)")
    }

    private mutating func byte() throws -> Int {
        guard position < limit else { throw failure("unexpected end of data") }
        let value = Int(bytes[position])
        position += 1
        return value
    }

    private mutating func dataByte() throws -> Int {
        let value = try byte()
        guard value < 0x80 else { throw failure("expected a data byte") }
        return value
    }

    private mutating func unsigned(bytes count: Int) throws -> Int {
        var value = 0
        for _ in 0..<count {
            let next = try byte()
            value = (value << 8) | next
        }
        return value
    }

    private mutating func variableLength() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let next = try byte()
            value = (value << 7) | (next & 0x7F)
            if next & 0x80 == 0 { return value }
        }
        throw failure("variable-length number longer than four bytes")
    }

    private mutating func chunkTag() throws -> [UInt8] {
        var tag: [UInt8] = []
        for _ in 0..<4 {
            let next = try byte()
            tag.append(UInt8(next))
        }
        return tag
    }

    private mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= limit - position else { throw failure("data runs past the end") }
        position += count
    }

    private mutating func parseFile() throws -> (ticksPerQuarter: Int, tracks: [[SMFEvent]]) {
        let header = try chunkTag()
        guard header == Array("MThd".utf8) else { throw failure("no MThd header") }
        let headerLength = try unsigned(bytes: 4)
        guard headerLength >= 6 else { throw failure("header too short") }
        let format = try unsigned(bytes: 2)
        let trackCount = try unsigned(bytes: 2)
        let division = try unsigned(bytes: 2)
        try skip(headerLength - 6)
        guard format <= 2 else { throw failure("unknown MIDI format \(format)") }
        guard trackCount <= SMFReader.maxTracks else { throw MIDILoopError.unsupportedMIDI("\(trackCount) tracks") }
        guard division & 0x8000 == 0 else { throw MIDILoopError.unsupportedMIDI("SMPTE time division") }
        guard division > 0 else { throw failure("zero ticks per quarter note") }

        var tracks: [[SMFEvent]] = []
        while tracks.count < trackCount {
            guard limit - position >= 8 else { throw failure("missing track data") }
            let tag = try chunkTag()
            let length = try unsigned(bytes: 4)
            guard length <= limit - position else { throw failure("a chunk runs past the end of the file") }
            if tag == Array("MTrk".utf8) {
                tracks.append(try readTrack(length: length))
            } else {
                try skip(length)
            }
        }
        guard !tracks.isEmpty else { throw failure("no tracks") }
        return (division, tracks)
    }

    private mutating func readTrack(length: Int) throws -> [SMFEvent] {
        let outerLimit = limit
        let chunkEnd = position + length
        limit = chunkEnd
        defer { limit = outerLimit }

        var events: [SMFEvent] = []
        var tick = 0
        var running: Int? = nil
        loop: while position < limit {
            let delta = try variableLength()
            tick += delta
            var status = try byte()
            if status < 0x80 {
                guard let previous = running else { throw failure("data byte with no running status") }
                status = previous
                position -= 1
            } else if status < 0xF0 {
                running = status
            } else {
                running = nil
            }
            guard events.count < SMFReader.maxEventsPerTrack else {
                throw MIDILoopError.unsupportedMIDI("more than \(SMFReader.maxEventsPerTrack) events in one track")
            }
            let channel = UInt8(status & 0x0F)
            switch status >> 4 {
            case 0x8:
                let pitch = try dataByte()
                _ = try dataByte()
                events.append(SMFEvent(tick: tick, kind: .noteOff(channel: channel, pitch: UInt8(pitch))))
            case 0x9:
                let pitch = try dataByte()
                let velocity = try dataByte()
                let kind: SMFEvent.Kind = velocity == 0
                    ? .noteOff(channel: channel, pitch: UInt8(pitch))
                    : .noteOn(channel: channel, pitch: UInt8(pitch), velocity: UInt8(velocity))
                events.append(SMFEvent(tick: tick, kind: kind))
            case 0xA, 0xE:
                _ = try dataByte()
                _ = try dataByte()
            case 0xB:
                let number = try dataByte()
                let value = try dataByte()
                events.append(SMFEvent(tick: tick, kind: .controller(channel: channel, number: UInt8(number), value: UInt8(value))))
            case 0xC, 0xD:
                _ = try dataByte()
            case 0xF:
                if status == 0xFF {
                    let type = try byte()
                    let length = try variableLength()
                    guard length <= limit - position else { throw failure("meta event runs past the track") }
                    let start = position
                    if type == 0x2F {
                        position = start + length
                        break loop
                    }
                    if type == 0x51, length == 3 {
                        let microseconds = (Int(bytes[start]) << 16) | (Int(bytes[start + 1]) << 8) | Int(bytes[start + 2])
                        if microseconds > 0 {
                            events.append(SMFEvent(tick: tick, kind: .tempo(microseconds: microseconds)))
                        }
                    } else if type == 0x58, length >= 2, bytes[start] > 0, bytes[start + 1] <= 7 {
                        let denominator = 1 << Int(bytes[start + 1])
                        events.append(SMFEvent(tick: tick, kind: .timeSignature(numerator: Int(bytes[start]), denominator: denominator)))
                    } else if type == 0x59, length >= 2 {
                        let sharps = Int(Int8(bitPattern: bytes[start]))
                        events.append(SMFEvent(tick: tick, kind: .keySignature(sharps: sharps, minor: bytes[start + 1] != 0)))
                    }
                    position = start + length
                } else if status == 0xF0 || status == 0xF7 {
                    let length = try variableLength()
                    try skip(length)
                } else {
                    throw failure("unexpected status byte \(status)")
                }
            default:
                throw failure("unexpected status byte \(status)")
            }
        }
        position = chunkEnd
        return events
    }
}
