import BSSMidiLoop
import BSSMidiPlayer
import Foundation

/// bss-midiloop: `analyze` a MIDI file's segments and jumps, or `render` endless play to a WAV with checks.
/// It writes nothing but the file it was asked to render; it never writes a sidecar.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    print("""
    usage:
      bss-midiloop analyze <file.mid> [--style conservative|balanced]
      bss-midiloop render <file.mid> --minutes N -o out.wav [--seed N] [--style conservative|balanced]
    """)
    exit(2)
}

func clock(_ seconds: Double) -> String {
    let whole = Int(seconds)
    let fraction = Int(((seconds - Double(whole)) * 1000).rounded())
    return String(format: "%d:%02d.%03d", whole / 60, whole % 60, fraction)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
arguments.removeFirst()

var style = LoopStyle.balanced
var seed: UInt64 = UInt64.random(in: 1...UInt64.max)
var minutes: Double? = nil
var rmsTargetDB = -22.4
var writeSidecar = false
var output: String? = nil
var input: String? = nil
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    index += 1
    switch argument {
    case "--style":
        guard index < arguments.count, let value = LoopStyle(rawValue: arguments[index]) else { usage() }
        style = value
        index += 1
    case "--seed":
        guard index < arguments.count, let value = UInt64(arguments[index]) else { usage() }
        seed = value
        index += 1
    case "--minutes":
        guard index < arguments.count, let value = Double(arguments[index]), value > 0 else { usage() }
        minutes = value
        index += 1
    case "--sidecar":
        writeSidecar = true
    case "--rms-target":
        guard index < arguments.count, let value = Double(arguments[index]) else { usage() }
        rmsTargetDB = value
        index += 1
    case "-o":
        guard index < arguments.count else { usage() }
        output = arguments[index]
        index += 1
    default:
        if argument.hasPrefix("-") { usage() }
        input = argument
    }
}

guard let path = input else { usage() }
let piece: MIDIPerformance
do {
    piece = try MIDIPerformance(contentsOf: URL(fileURLWithPath: path))
} catch {
    fail("\(error)")
}
let map = LoopMap.analyze(piece, style: style)
if writeSidecar && command == "analyze" {
    // The loop map is saved beside the MIDI as <name>.loopmap.json; it is read back on the next run.
    do {
        let url = LoopMap.sidecarURL(for: URL(fileURLWithPath: path))
        _ = try LoopMap.load(piece, sidecar: url, style: style)
        print("wrote \(url.path)")
    } catch {
        fail("\(error)")
    }
}

switch command {
case "analyze":
    print("file \(URL(fileURLWithPath: path).lastPathComponent): \(piece.notes.count) notes, \(map.segments.count) segments, "
          + "\(String(format: "%.1f", piece.seconds(atTick: piece.endTick))) s, style \(style.rawValue)")
    for segment in map.segments {
        print("  segment \(segment.index): bars \(segment.startBar)-\(segment.endBar)")
    }
    for segment in map.segments {
        let options = map.jumps(from: segment.index)
        let text = options.map { "\($0.to) (\(String(format: "%.3f", $0.score)), \($0.kind.rawValue))" }
        print("  end of segment \(segment.index) -> \(text.isEmpty ? "no jump" : text.joined(separator: ", "))")
    }
    let usable = map.segments.filter { segment in map.jumps(from: segment.index).contains { $0.score >= 0.6 } }.count
    print("  segment ends with a usable jump (score 0.6 or more): \(usable) of \(map.segments.count)")

case "render":
    guard let minutes, let output else { usage() }
    let url = URL(fileURLWithPath: output)
    let last = map.segments.count - 1
    print("render \(URL(fileURLWithPath: path).lastPathComponent): \(minutes) min, seed \(seed), style \(style.rawValue)")

    // Pass 1: measure the level with unit gain (no file). Pass 2: the same plan with the gain that puts its RMS at the
    // target. Both pieces use the same target, so they match in loudness; their peaks land where that puts them.
    var calibration = EventCursor(piece: piece, map: map, mode: .endless, seed: seed)
    let measured: OfflineRender.Result
    do {
        measured = try OfflineRender.render(cursor: &calibration, seconds: minutes * 60)
    } catch {
        fail("\(error)")
    }
    var unitSquares = 0.0
    for value in measured.samples { unitSquares += Double(value) * Double(value) }
    let unitRMSDB = 20 * log10((unitSquares / Double(max(1, measured.samples.count))).squareRoot())
    let gainDB = rmsTargetDB - unitRMSDB
    let gain = Float(pow(10, gainDB / 20))
    print("calibration: unit-gain RMS \(String(format: "%.2f", unitRMSDB)) dBFS, peak \(String(format: "%.2f", 20 * log10(Double(measured.peak)))) dBFS; "
          + "master gain \(String(format: "%+.2f", gainDB)) dB to RMS target \(String(format: "%.1f", rmsTargetDB)) dBFS")

    var cursor = EventCursor(piece: piece, map: map, mode: .endless, seed: seed)
    let result: OfflineRender.Result
    do {
        result = try OfflineRender.render(cursor: &cursor, seconds: minutes * 60, to: url, gain: gain)
    } catch {
        fail("\(error)")
    }
    let pieceEnds = result.jumps.filter { $0.from == last }.map(\.seconds)
    let levels = LevelReport(samples: result.samples, rate: result.sampleRate, pieceEnds: pieceEnds)
    let peakDB = 20 * log10(Double(result.peak))
    let length = Double(result.frames) / result.sampleRate
    var sumSquares = 0.0
    for value in result.samples { sumSquares += Double(value) * Double(value) }
    let rmsDB = 20 * log10((sumSquares / Double(max(1, result.samples.count))).squareRoot())
    print("length \(String(format: "%.2f", length)) s (asked \(minutes * 60) s): \(abs(length - minutes * 60) < 0.01 ? "ok" : "WRONG")")
    print("peak \(String(format: "%.2f", peakDB)) dBFS (\(result.peak < 1 ? "under 0 dBFS" : "AT OR OVER 0 dBFS")); "
          + "loudness RMS \(String(format: "%.2f", rmsDB)) dBFS (whole file; not LUFS)")
    print("silences over 1 s: \(levels.longSilences.isEmpty ? "none" : levels.longSilences.map { "\(clock($0.start)) for \(String(format: "%.2f", $0.seconds)) s" }.joined(separator: "; "))")
    print("breaths (excused, at the end of the piece): \(levels.breaths.isEmpty ? "none" : levels.breaths.map { "\(clock($0.start)) for \(String(format: "%.2f", $0.seconds)) s" }.joined(separator: "; "))")
    print("gaps by the half-level count (printed, not pass or fail): \(levels.gapWindows) windows, raw quiet \(levels.rawQuietWindows)")
    print("clicks, fixed rule (step over \(LevelReport.clickLimit)): \(levels.clicks); largest step \(String(format: "%.4f", levels.largestStep))")
    print("clicks, relative rule (step over 4x the median of its 10 ms): \(levels.relativeClickCount)")
    for click in levels.worstRelativeClicks {
        print("  worst: \(clock(click.time)) step \(String(format: "%.4f", click.step)) = \(String(format: "%.1f", click.ratio))x median")
    }
    print("jumps: \(result.jumps.count) (\(pieceEnds.count) at the end of the piece)")
    for jump in result.jumps {
        let kind = jump.from == last ? "end of piece" : "jump"
        print("  \(clock(jump.seconds))  segment \(jump.from) -> \(jump.to)  (\(kind))")
    }
    print("wrote \(url.path)")

default:
    usage()
}
