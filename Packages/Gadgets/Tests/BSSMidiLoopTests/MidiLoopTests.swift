import Testing
import Foundation
@testable import BSSMidiLoop

/// Pairs note-ons with note-offs per key, first in first out, and reports anything that breaks the rules:
/// an off with no on, a note that never stops, a note that sounds longer than the limit, or events out of time order.
func noteProblems(_ events: [TimedEvent], longestAllowed: Double) -> [String] {
    var problems: [String] = []
    var open: [String: [Double]] = [:]
    var previous = -Double.infinity
    for event in events {
        if event.seconds < previous { problems.append("event out of time order at \(event.seconds)") }
        previous = event.seconds
        switch event.message {
        case let .noteOn(channel, pitch, _):
            open["\(channel)-\(pitch)", default: []].append(event.seconds)
        case let .noteOff(channel, pitch):
            let key = "\(channel)-\(pitch)"
            guard var starts = open[key], !starts.isEmpty else {
                problems.append("note-off with no note-on: \(key) at \(event.seconds)")
                continue
            }
            let start = starts.removeFirst()
            open[key] = starts
            if event.seconds - start > longestAllowed {
                problems.append("\(key) sounded \(event.seconds - start) s")
            }
        case .controller, .jump:
            break
        }
    }
    for (key, starts) in open where !starts.isEmpty {
        problems.append("\(key) never stopped")
    }
    return problems
}

/// Drains a cursor until its events reach `seconds`, returning everything it produced.
func drain(_ cursor: inout EventCursor, until seconds: Double) -> [TimedEvent] {
    var out: [TimedEvent] = []
    while true {
        let event = cursor.next()
        out.append(event)
        if event.seconds >= seconds { break }
    }
    return out
}

/// Drains a cursor until it has made the given jump, so a long first segment does not stop the check early.
func drainUntilJump(_ cursor: inout EventCursor, from: Int, to: Int) -> [TimedEvent] {
    var out: [TimedEvent] = []
    while out.count < 2_000_000 {
        let event = cursor.next()
        out.append(event)
        if case let .jump(f, t) = event.message, f == from, t == to {
            // The controllers of the jump share its time and come after it: take them too.
            while true {
                let next = cursor.next()
                out.append(next)
                if next.seconds > event.seconds { break }
            }
            break
        }
    }
    return out
}

func jumps(in events: [TimedEvent]) -> [(seconds: Double, from: Int, to: Int)] {
    var result: [(seconds: Double, from: Int, to: Int)] = []
    for event in events {
        if case let .jump(from, to) = event.message {
            result.append((event.seconds, from, to))
        }
    }
    return result
}

@Suite struct MIDIReadingTests {
    @Test func notesTempoAndKeysAreRead() throws {
        let piece = try GeneratedPiece.piece()
        #expect(piece.notes.count == GeneratedPiece.bars * 4)
        #expect(piece.beatsPerMinute(atTick: 0) == 120)
        #expect(piece.seconds(atTick: GeneratedPiece.barTicks) == 2.0)
        #expect(piece.seconds(atTick: 2 * GeneratedPiece.barTicks) == 4.0)
        #expect(piece.keys.map(\.sharps) == [0, 1])
        #expect(piece.keys.last?.tick == 12 * GeneratedPiece.barTicks)
        #expect(piece.meters.first?.numerator == 4 && piece.meters.first?.denominator == 4)
        // The last bass note crosses into a seventeenth bar, so the music ends at tick 31,680.
        #expect(piece.endTick == 31680)
    }

    @Test func tempoChangesMoveTheClock() throws {
        var writer = MIDIWriter()
        writer.addTrack([
            (0, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]),  // 120 bpm
            (480, [0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40]), // 1,000,000 microseconds: 60 bpm from beat 1
            (480, [0x90, 60, 80]),
            (960, [0x80, 60, 0]),
        ])
        let piece = try MIDIPerformance(data: writer.data())
        #expect(piece.seconds(atTick: 480) == 0.5)
        #expect(piece.seconds(atTick: 960) == 1.5)
        #expect(piece.beatsPerMinute(atTick: 960) == 60)
    }

    @Test func sustainPedalHoldsNotesUntilItLifts() throws {
        let piece = try GeneratedPiece.piece()
        let pedalDown = GeneratedPiece.barTicks + GeneratedPiece.division
        let pedalUp = 2 * GeneratedPiece.barTicks + GeneratedPiece.division
        // A note of bar 1 is let go at the bar line before bar 2, while the pedal is down: it sounds until the pedal lifts.
        let held = piece.notes.first { $0.start == GeneratedPiece.barTicks && $0.pitch == 57 }
        #expect(held != nil)
        #expect(held?.end == 2 * GeneratedPiece.barTicks - 1)
        #expect(held?.soundingEnd == pedalUp)
        // A note let go before the pedal goes down is not held.
        let early = piece.notes.first { $0.start == 0 && $0.pitch == 60 }
        #expect(early?.soundingEnd == early?.end)
        #expect(piece.pedalValue(channel: 0, beforeTick: pedalDown) == 0)
        #expect(piece.pedalValue(channel: 0, beforeTick: pedalDown + 1) == 127)
        #expect(piece.pedalValue(channel: 0, beforeTick: pedalUp + 1) == 0)
    }

    @Test func runningStatusAndNoteOnWithZeroVelocityAreRead() throws {
        // Note on C4 at tick 0 with running status for the note-off (a note-on with velocity 0) at tick 480.
        let body: [UInt8] = [0x00, 0x90, 0x3C, 0x50, 0x83, 0x60, 0x3C, 0x00, 0x00, 0xFF, 0x2F, 0x00]
        var bytes: [UInt8] = Array("MThd".utf8) + MIDIWriter.be32(6) + MIDIWriter.be16(0) + MIDIWriter.be16(1) + MIDIWriter.be16(480)
        bytes += Array("MTrk".utf8) + MIDIWriter.be32(body.count) + body
        let piece = try MIDIPerformance(data: Data(bytes))
        #expect(piece.notes == [MIDIPerformance.Note(channel: 0, pitch: 60, velocity: 80, start: 0, end: 480, soundingEnd: 480)])
    }

    @Test(.timeLimit(.minutes(1)))
    func corruptFilesThrowInsteadOfCrashing() throws {
        let good = [UInt8](GeneratedPiece.data())
        #expect(throws: MIDILoopError.self) { try MIDIPerformance(data: Data()) }
        #expect(throws: MIDILoopError.self) { try MIDIPerformance(data: Data("not a midi file at all".utf8)) }
        #expect(throws: MIDILoopError.self) { try MIDIPerformance(data: Data(good.prefix(good.count / 2))) }
        #expect(throws: MIDILoopError.self) { try MIDIPerformance(data: Data(good.prefix(20))) }

        var smpte = good
        smpte[12] = 0xE7  // SMPTE time division
        #expect(throws: MIDILoopError.self) { try MIDIPerformance(data: Data(smpte)) }

        var longTrack = good
        longTrack.replaceSubrange(18..<22, with: MIDIWriter.be32(0x7FFF_FFFF))  // a track length far past the end of the file
        #expect(throws: MIDILoopError.self) { try MIDIPerformance(data: Data(longTrack)) }

        // A data byte with no running status before it.
        let body: [UInt8] = [0x00, 0x3C, 0x50, 0x00, 0xFF, 0x2F, 0x00]
        var bytes: [UInt8] = Array("MThd".utf8) + MIDIWriter.be32(6) + MIDIWriter.be16(0) + MIDIWriter.be16(1) + MIDIWriter.be16(480)
        bytes += Array("MTrk".utf8) + MIDIWriter.be32(body.count) + body
        #expect(throws: MIDILoopError.self) { try MIDIPerformance(data: Data(bytes)) }
    }

    @Test(.timeLimit(.minutes(1)))
    func randomBytesNeverTrap() {
        var random = SeededRandom(seed: 99)
        let good = [UInt8](GeneratedPiece.data())
        for round in 0..<400 {
            var bytes = good
            // Damage a few bytes of a valid file, and sometimes replace the whole thing.
            if round % 4 == 0 {
                bytes = (0..<Int(random.next() % 300)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            } else {
                for _ in 0..<(1 + Int(random.next() % 6)) {
                    let index = Int(random.next() % UInt64(bytes.count))
                    bytes[index] = UInt8(truncatingIfNeeded: random.next())
                }
            }
            _ = try? MIDIPerformance(data: Data(bytes))
        }
    }
}

@Suite struct SegmentTests {
    @Test func emptyBarsAtTheEndOfThePieceAreTrimmed() throws {
        // Sixteen bars were written, sound only in the first fourteen: the planner's last segment ends at bar 14.
        let piece = try MIDIPerformance(data: EndingPiece.data())
        #expect(piece.barTicks.count - 1 == 14)  // the bar table already stops at the last sounding tick
        let map = LoopAnalysis.analyze(piece, style: .balanced)
        #expect(map.segments.last?.endBar == 14)
        #expect(map.segments.last?.endTick == 14 * GeneratedPiece.barTicks)
    }

    @Test func keyChangeIsAlwaysASegmentBoundary() throws {
        let piece = try GeneratedPiece.piece()
        let map = LoopAnalysis.analyze(piece, style: .balanced)
        #expect(map.segments.contains { $0.startBar == 12 })
    }

    @Test func segmentsAreContiguousAndCoverThePiece() throws {
        let piece = try GeneratedPiece.piece()
        for style in LoopStyle.allCases {
            let map = LoopAnalysis.analyze(piece, style: style)
            #expect(map.segments.first?.startBar == 0)
            #expect(map.segments.last?.endBar == piece.barTicks.count - 1)
            for pair in zip(map.segments, map.segments.dropFirst()) {
                #expect(pair.0.endBar == pair.1.startBar)
                #expect(pair.0.endTick == pair.1.startTick)
            }
            #expect(map.segments.allSatisfy { $0.endBar > $0.startBar })
        }
    }

    @Test func boundariesKeepTheMinimumLengthExceptKeyChanges() throws {
        let piece = try GeneratedPiece.piece()
        let map = LoopAnalysis.analyze(piece, style: .conservative)
        for segment in map.segments where segment.startBar != 12 && segment.endBar != 12 && segment.endBar != GeneratedPiece.bars {
            #expect(segment.endBar - segment.startBar >= LoopStyle.conservative.minimumBars)
        }
    }

    @Test func eachSegmentEndKeepsTwoBestJumpsAndNeverSelfOrNatural() throws {
        let piece = try GeneratedPiece.piece()
        for style in LoopStyle.allCases {
            let map = LoopAnalysis.analyze(piece, style: style)
            for segment in map.segments {
                let options = map.transitions.filter { $0.from == segment.index }
                #expect(options.count <= 2)
                #expect(options.allSatisfy { $0.to != segment.index && $0.to != segment.index + 1 })
                #expect(options.map(\.score) == options.map(\.score).sorted(by: >))
            }
        }
    }

    @Test func repeatedSectionIsFoundAsARepeatJump() throws {
        let piece = try GeneratedPiece.piece()
        let map = LoopAnalysis.analyze(piece, style: .balanced)
        // Bars 8 to 11 repeat bars 0 to 3, so a cut at the end of bar 7 can go to bar 0 and carry on with the same notes.
        let endOfB = map.segments.first { $0.endBar == 8 }
        let startOfA = map.segments.first { $0.startBar == 0 }
        #expect(endOfB != nil && startOfA != nil)
        let jump = map.transitions.first { $0.from == endOfB?.index && $0.to == startOfA?.index }
        #expect(jump?.kind == TransitionKind.repeated)
        #expect((jump?.score ?? 0) >= 0.9)
    }
}

@Suite struct SidecarTests {
    static func temporaryMIDI(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bss-midiloop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try GeneratedPiece.data().write(to: url)
        return url
    }

    @Test func sidecarIsWrittenOnceThenReadBack() throws {
        let midi = try Self.temporaryMIDI("generated.mid")
        let piece = try MIDIPerformance(contentsOf: midi)
        let sidecar = LoopMap.sidecarURL(for: midi)
        #expect(sidecar.lastPathComponent == "generated.loopmap.json")

        let first = try LoopMap.load(piece, sidecar: sidecar)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(text.contains("\"format\" : \"bss-midiloop\\/1\"") || text.contains("bss-midiloop/1"))
        #expect(!text.contains("/Users/"))

        let second = try LoopMap.load(piece, sidecar: sidecar)
        #expect(first == second)
    }

    @Test func rejectedJumpsNeverPlayAndApprovedOnesAreOffered() throws {
        let piece = try GeneratedPiece.piece()
        var map = LoopAnalysis.analyze(piece, style: .balanced)
        let rejectedAll = map.transitions.map { JumpPair(from: $0.from, to: $0.to) }
        map.rejected = rejectedAll
        #expect(map.segments.allSatisfy { map.jumps(from: $0.index).isEmpty })

        map.rejected = []
        let from = map.segments[0].index
        let to = map.segments[map.segments.count - 1].index
        if to != from + 1 && to != from {
            map.approved = [JumpPair(from: from, to: to)]
            #expect(map.jumps(from: from).first?.to == to)
            #expect(map.jumps(from: from).first?.score == 1)
        }
    }

    @Test func sidecarThatIsNotLoopMapJSONThrows() throws {
        let midi = try Self.temporaryMIDI("broken.mid")
        let piece = try MIDIPerformance(contentsOf: midi)
        let sidecar = LoopMap.sidecarURL(for: midi)
        try Data("{\"hello\": true}".utf8).write(to: sidecar)
        #expect(throws: MIDILoopError.self) { try LoopMap.load(piece, sidecar: sidecar) }
    }
}

@Suite struct CursorTests {
    @Test func everyJumpRebuildsThePedalAndLeavesNoStuckNote() throws {
        let piece = try GeneratedPiece.piece()
        let map = LoopAnalysis.analyze(piece, style: .balanced)
        let channels = Set(piece.controllers.filter { $0.number == 64 }.map(\.channel))
        var checked = 0
        for transition in map.transitions where transition.to != transition.from + 1 {
            var cursor = EventCursor(piece: piece, map: map, mode: .script([transition.from, transition.to]), seed: 1)
            let events = drainUntilJump(&cursor, from: transition.from, to: transition.to)
            let found = jumps(in: events).filter { $0.from == transition.from && $0.to == transition.to }
            #expect(!found.isEmpty)
            guard let jump = found.first else { continue }
            let destination = map.segments[transition.to]
            for channel in channels {
                let expected = piece.pedalValue(channel: channel, beforeTick: destination.startTick)
                let set = events.compactMap { event -> UInt8? in
                    if case let .controller(ch, number, value) = event.message, ch == channel, number == 64, event.seconds == jump.seconds {
                        return value
                    }
                    return nil
                }
                #expect(set == [expected])
            }
            let tail = events + cursor.finish()
            let longest = piece.seconds(atTick: piece.endTick) + 2
            #expect(noteProblems(tail, longestAllowed: longest).isEmpty)
            checked += 1
        }
        #expect(checked > 0)
        print("cursor: checked \(checked) jumps for pedal and stuck notes")
    }

    @Test func endlessTwoHoursHasNoStuckNote() throws {
        let piece = try GeneratedPiece.piece()
        let map = LoopAnalysis.analyze(piece, style: .balanced)
        let simulatedSeconds = 2.0 * 60 * 60
        var cursor = EventCursor(piece: piece, map: map, mode: .endless, seed: 42)

        let started = Date()
        var events = drain(&cursor, until: simulatedSeconds)
        let elapsed = Date().timeIntervalSince(started)

        let longest = piece.seconds(atTick: piece.endTick) + 2
        // Open notes at each jump, and notes still on at the end of the run that have been on past the limit (stuck).
        var open: [String: [Double]] = [:]
        var openAtJumps: [Int] = []
        for event in events {
            switch event.message {
            case let .noteOn(channel, pitch, _): open["\(channel)-\(pitch)", default: []].append(event.seconds)
            case let .noteOff(channel, pitch):
                open["\(channel)-\(pitch)"]?.removeFirst()
            case .jump: openAtJumps.append(open.values.reduce(0) { $0 + $1.count })
            case .controller: break
            }
        }
        let stuck = open.values.flatMap { $0 }.filter { simulatedSeconds - $0 > longest }.count
        print("endless 2 h: open notes at jumps min \(openAtJumps.min() ?? 0), max \(openAtJumps.max() ?? 0); "
              + "notes on at the end \(open.values.reduce(0) { $0 + $1.count }), of which stuck \(stuck)")
        #expect(stuck == 0)
        events += cursor.finish()
        let problems = noteProblems(events, longestAllowed: longest)
        #expect(problems.isEmpty, "\(problems.prefix(5))")

        let ons = events.filter { if case .noteOn = $0.message { return true } else { return false } }.count
        let offs = events.filter { if case .noteOff = $0.message { return true } else { return false } }.count
        #expect(ons == offs)
        let jumpEvents = jumps(in: events)
        #expect(jumpEvents.count > 10)
        #expect(events.last?.seconds ?? 0 >= simulatedSeconds)
        print("endless 2 h: \(events.count) events, \(ons) note-ons, \(offs) note-offs, \(jumpEvents.count) jumps, "
              + "problems \(problems.count), simulated \(Int(simulatedSeconds)) s in \(String(format: "%.3f", elapsed)) s")
    }

    @Test func loopModePlaysTheWholePieceThenJumpsFromTheEnd() throws {
        let piece = try GeneratedPiece.piece()
        let map = LoopAnalysis.analyze(piece, style: .balanced)
        var cursor = EventCursor(piece: piece, map: map, mode: .loop, seed: 5)
        let events = drain(&cursor, until: 80)
        let first = jumps(in: events).first
        #expect(first?.from == map.segments.count - 1)
        #expect(abs((first?.seconds ?? 0) - piece.seconds(atTick: map.segments[map.segments.count - 1].endTick)) < 1e-9)
        #expect(noteProblems(events + cursor.finish(), longestAllowed: 32).isEmpty)
    }

    @Test func theSameSeedGivesTheSamePlan() throws {
        let piece = try GeneratedPiece.piece()
        let map = LoopAnalysis.analyze(piece, style: .balanced)
        var one = EventCursor(piece: piece, map: map, mode: .endless, seed: 7)
        var two = EventCursor(piece: piece, map: map, mode: .endless, seed: 7)
        var other = EventCursor(piece: piece, map: map, mode: .endless, seed: 8)
        let a = drain(&one, until: 600)
        let b = drain(&two, until: 600)
        let c = drain(&other, until: 600)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func rejectedJumpsNeverPlayInALongRun() throws {
        let piece = try GeneratedPiece.piece()
        var map = LoopAnalysis.analyze(piece, style: .balanced)
        map.rejected = map.transitions.map { JumpPair(from: $0.from, to: $0.to) }
        var cursor = EventCursor(piece: piece, map: map, mode: .endless, seed: 3)
        let events = drain(&cursor, until: 1800) + cursor.finish()
        let last = map.segments.count - 1
        for jump in jumps(in: events) {
            #expect(jump.from == last && jump.to == 0)
        }
        #expect(noteProblems(events, longestAllowed: 32).isEmpty)
    }
}
