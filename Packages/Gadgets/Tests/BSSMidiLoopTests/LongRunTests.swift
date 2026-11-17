import Testing
import Foundation
@testable import BSSMidiLoop

/// What a long endless run found: notes still sounding at each jump, the pedal at each jump, and notes that never stopped.
struct LongRunReport {
    var events = 0
    var jumps = 0
    var pedalChecks = 0
    var pedalMismatches = 0
    var openAtJumpsMin = Int.max
    var openAtJumpsMax = 0
    var openMax = 0
    var stuckBeforeFinish = 0
    var problems: [String] = []
    var seconds = 0.0
}

/// Runs an endless plan for `simulatedSeconds` and checks the cursor's state rebuild at every jump.
func longEndlessRun(_ piece: MIDIPerformance, _ map: LoopMap, seed: UInt64, simulatedSeconds: Double) -> LongRunReport {
    var report = LongRunReport()
    var cursor = EventCursor(piece: piece, map: map, mode: .endless, seed: seed)
    let longest = piece.seconds(atTick: piece.endTick) + 2
    let channels = Set(piece.controllers.filter { $0.number == 64 }.map(\.channel))

    var events: [TimedEvent] = []
    var open: [String: [Double]] = [:]
    var openCount = 0
    var pendingJump: (seconds: Double, to: Int)? = nil
    var rebuiltPedal: [UInt8: UInt8] = [:]

    let started = Date()
    while true {
        let event = cursor.next()
        events.append(event)
        if event.seconds >= simulatedSeconds { break }
        switch event.message {
        case let .noteOn(channel, pitch, _):
            open["\(channel)-\(pitch)", default: []].append(event.seconds)
            openCount += 1
            report.openMax = max(report.openMax, openCount)
        case let .noteOff(channel, pitch):
            let key = "\(channel)-\(pitch)"
            if var starts = open[key], !starts.isEmpty {
                starts.removeFirst()
                open[key] = starts
                openCount -= 1
            }
        case let .controller(channel, number, value):
            if number == 64, let jump = pendingJump, event.seconds == jump.seconds {
                rebuiltPedal[channel] = value
            }
        case let .jump(_, to):
            report.jumps += 1
            report.openAtJumpsMin = min(report.openAtJumpsMin, openCount)
            report.openAtJumpsMax = max(report.openAtJumpsMax, openCount)
            pendingJump = (event.seconds, to)
            rebuiltPedal = [:]
        }
        // Once the rebuild for a jump has been emitted (its controllers follow the jump at the same time), check it.
        if let jump = pendingJump, event.seconds > jump.seconds {
            let start = piece.barTicks.isEmpty ? 0 : map.segments[jump.to].startTick
            for channel in channels {
                report.pedalChecks += 1
                let expected = piece.pedalValue(channel: channel, beforeTick: start)
                if rebuiltPedal[channel] != expected { report.pedalMismatches += 1 }
            }
            pendingJump = nil
        }
    }
    // Notes still on before the stream is finished, that have been on longer than the piece allows: these are stuck.
    report.stuckBeforeFinish = open.values.reduce(0) { total, starts in
        total + starts.filter { simulatedSeconds - $0 > longest }.count
    }
    let finished = cursor.finish()
    events += finished
    report.events = events.count
    report.problems = noteProblems(events, longestAllowed: longest)
    report.seconds = Date().timeIntervalSince(started)
    return report
}

func printLongRun(_ label: String, _ r: LongRunReport) {
    print("\(label): \(r.events) events, \(r.jumps) jumps; notes on at each jump min \(r.openAtJumpsMin) max \(r.openAtJumpsMax); "
          + "most notes on at once \(r.openMax); pedal checks \(r.pedalChecks), mismatches \(r.pedalMismatches); "
          + "stuck before finish \(r.stuckBeforeFinish); problems \(r.problems.count); \(String(format: "%.3f", r.seconds)) s")
}

@Suite struct StressRunTests {
    @Test func stressPieceTwoHoursHasNoStuckNoteAndRebuildsThePedal() throws {
        let piece = try MIDIPerformance(data: StressPiece.data())
        let map = LoopAnalysis.analyze(piece, style: .balanced)
        #expect(piece.keys.map(\.sharps).contains(3))
        #expect(piece.tempo.count >= 2)
        let report = longEndlessRun(piece, map, seed: 11, simulatedSeconds: 7200)
        printLongRun("stress 2 h", report)
        #expect(report.problems.isEmpty, "\(report.problems.prefix(5))")
        #expect(report.stuckBeforeFinish == 0)
        #expect(report.pedalMismatches == 0)
        #expect(report.jumps > 100)
        #expect(report.openMax > 32)
    }
}
