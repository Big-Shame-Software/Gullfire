import Foundation
@testable import BSSMidiLoop

/// Writes Standard MIDI Files in code, so every test piece is made here. Nothing comes from a real score.
struct MIDIWriter {
    var division = 480
    var format = 1
    private(set) var tracks: [[(tick: Int, bytes: [UInt8])]] = []

    mutating func addTrack(_ events: [(tick: Int, bytes: [UInt8])]) {
        tracks.append(events)
    }

    func data() -> Data {
        var out: [UInt8] = []
        out += Array("MThd".utf8)
        out += MIDIWriter.be32(6)
        out += MIDIWriter.be16(format)
        out += MIDIWriter.be16(tracks.count)
        out += MIDIWriter.be16(division)
        for track in tracks {
            var body: [UInt8] = []
            var last = 0
            let ordered = track.enumerated()
                .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
                .map(\.element)
            for event in ordered {
                body += MIDIWriter.variableLength(event.tick - last)
                body += event.bytes
                last = event.tick
            }
            body += [0x00, 0xFF, 0x2F, 0x00]
            out += Array("MTrk".utf8)
            out += MIDIWriter.be32(body.count)
            out += body
        }
        return Data(out)
    }

    static func be16(_ value: Int) -> [UInt8] {
        return [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func be32(_ value: Int) -> [UInt8] {
        return [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func variableLength(_ value: Int) -> [UInt8] {
        var groups = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            groups.insert(UInt8((rest & 0x7F) | 0x80), at: 0)
            rest >>= 7
        }
        return groups
    }
}

/// A 16-bar piece in 4/4 at 120 bpm (2 s a bar), in C major for bars 0 to 11 and G major for bars 12 to 15.
/// Sections: A (bars 0 to 3), B (4 to 7), A again (8 to 11), C (12 to 15). A sustain pedal is down from bar 1, beat 2,
/// to bar 2, beat 2. Each bar holds a chord, and a bass note crosses every bar line.
enum GeneratedPiece {
    static let division = 480
    static let barTicks = 4 * division
    static let bars = 16

    static let sectionA: [[UInt8]] = [[60, 64, 67], [57, 60, 64], [65, 69, 72], [55, 59, 62]]
    static let sectionB: [[UInt8]] = [[61, 66, 70], [63, 68, 70], [66, 70, 73], [68, 73, 75]]  // black-key chords, so B stands apart
    static let sectionC: [[UInt8]] = [[55, 59, 62], [52, 55, 59], [60, 63, 67], [62, 66, 69]]

    static func chord(forBar bar: Int) -> [UInt8] {
        switch bar {
        case 0..<4: return sectionA[bar]
        case 4..<8: return sectionB[bar - 4]
        case 8..<12: return sectionA[bar - 8]
        default: return sectionC[bar - 12]
        }
    }

    static func data(bars count: Int = bars) -> Data {
        var events: [(tick: Int, bytes: [UInt8])] = []
        events.append((0, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]))        // 500,000 microseconds a quarter: 120 bpm
        events.append((0, [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]))  // 4/4
        events.append((0, [0xFF, 0x59, 0x02, 0x00, 0x00]))              // C major
        events.append((12 * barTicks, [0xFF, 0x59, 0x02, 0x01, 0x00]))  // G major: the key change at bar 12
        events.append((barTicks + division, [0xB0, 64, 127]))           // pedal down: bar 1, beat 2
        events.append((2 * barTicks + division, [0xB0, 64, 0]))         // pedal up: bar 2, beat 2

        for bar in 0..<min(count, bars) {
            let start = bar * barTicks
            let end = start + barTicks - 1
            for pitch in chord(forBar: bar) {
                events.append((start, [0x90, pitch, 90]))
                events.append((end, [0x80, pitch, 0]))
            }
            // A bass note that starts late in one bar and ends late in the next, so jumps meet notes still sounding.
            let bass = chord(forBar: bar)[0] - 24
            events.append((start + division * 2, [0x90, bass, 70]))
            events.append((start + barTicks + division * 2, [0x80, bass, 0]))
        }
        var writer = MIDIWriter()
        writer.addTrack(events)
        return writer.data()
    }

    static func piece() throws -> MIDIPerformance {
        return try MIDIPerformance(data: data())
    }
}

/// A stress piece for stuck notes, 24 bars of 4/4 starting at 120 bpm. It is built to make jumps hard:
/// a key change at bar 6 and back at bar 12, a tempo change to about 90 bpm at bar 8, sustain pedal down across
/// boundaries and lifted mid-segment, chords of 16 or 24 notes (with the pedal, more than 32 can sound at once),
/// the same pitch struck again while it still sounds, and notes held across bar lines.
enum StressPiece {
    static let division = 480
    static let bar = 4 * division
    static let bars = 24

    static func data() -> Data {
        var events: [(tick: Int, bytes: [UInt8])] = []
        events.append((0, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]))        // 120 bpm
        events.append((0, [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]))  // 4/4
        events.append((0, [0xFF, 0x59, 0x02, 0x00, 0x00]))              // C major
        events.append((6 * bar, [0xFF, 0x59, 0x02, 0x03, 0x00]))        // A major (three sharps), at bar 6
        events.append((8 * bar, [0xFF, 0x51, 0x03, 0x0A, 0x2C, 0x2B]))  // 666,667 microseconds: 90 bpm, at bar 8
        events.append((12 * bar, [0xFF, 0x59, 0x02, 0x00, 0x00]))       // back to C major at bar 12
        // Pedal: down at bar 2, lifted mid-bar 5 (inside a segment); down at bar 9, lifted in bar 14 (across boundaries).
        events.append((2 * bar, [0xB0, 64, 127]))
        events.append((5 * bar + 2 * division, [0xB0, 64, 0]))
        events.append((9 * bar, [0xB0, 64, 127]))
        events.append((14 * bar + division, [0xB0, 64, 0]))

        for b in 0..<bars {
            let start = b * bar
            let count = b % 5 == 0 ? 24 : 16
            for i in 0..<count {
                let pitch = UInt8(36 + (b * 7 + i * 3) % 45)
                let length = b % 4 == 0 ? 2 * bar - 1 : bar - 1  // every fourth bar holds across the next bar line
                events.append((start, [0x90, pitch, 80]))
                events.append((start + length, [0x80, pitch, 0]))
            }
            // Pitch 60 struck again while it still sounds: two overlapping notes on one key, paired first in first out.
            events.append((start + division, [0x90, 60, 90]))
            events.append((start + 2 * division, [0x90, 60, 90]))
            events.append((start + 3 * division, [0x80, 60, 0]))
            events.append((start + bar + division, [0x80, 60, 0]))
            // A note held from beat 3 across the bar line.
            events.append((start + 3 * division, [0x90, 40, 70]))
            events.append((start + bar + 2 * division, [0x80, 40, 0]))
        }
        var writer = MIDIWriter()
        writer.addTrack(events)
        return writer.data()
    }
}

/// A piece of 16 bars whose last two bars are empty: chords sound in bars 0 to 13 only.
enum EndingPiece {
    static func data() -> Data {
        var events: [(tick: Int, bytes: [UInt8])] = []
        events.append((0, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]))
        events.append((0, [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]))
        events.append((0, [0xFF, 0x59, 0x02, 0x00, 0x00]))
        for bar in 0..<14 {
            let start = bar * GeneratedPiece.barTicks
            for pitch in GeneratedPiece.chord(forBar: bar) {
                events.append((start, [0x90, pitch, 90]))
                events.append((start + GeneratedPiece.barTicks - 1, [0x80, pitch, 0]))
            }
        }
        var writer = MIDIWriter()
        writer.addTrack(events)
        return writer.data()
    }
}
