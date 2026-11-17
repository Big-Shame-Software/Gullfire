import Foundation

/// How cautious the analysis is. Conservative wants longer segments and so has fewer, safer places to jump.
public enum LoopStyle: String, Sendable, Codable, CaseIterable {
    case conservative
    case balanced

    /// The shortest segment, in bars. Key changes are the only boundaries allowed inside this length.
    public var minimumBars: Int {
        switch self {
        case .conservative: return 8
        case .balanced: return 4
        }
    }
}

/// A stretch of bars that plays as one unit. Segments are contiguous: each one starts where the last one ends.
public struct LoopSegment: Sendable, Codable, Equatable {
    public let index: Int
    public let startBar: Int
    public let endBar: Int
    public let startTick: Int
    public let endTick: Int
}

public enum TransitionKind: String, Sendable, Codable, Equatable {
    /// The two passages are almost the same notes.
    case repeated = "repeat"
    /// Different notes, but they lead into each other well.
    case compatible
    /// Nothing fits well; the planner should ring out and rest before the new passage.
    case bridge
}

/// A jump from the end of one segment to the start of another.
public struct Transition: Sendable, Codable, Equatable {
    public let from: Int
    public let to: Int
    public let score: Double
    public let kind: TransitionKind
}

/// A pair of segment indices, used for the owner's approved and rejected jumps.
public struct JumpPair: Sendable, Codable, Equatable, Hashable {
    public let from: Int
    public let to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// The analysis of one MIDI piece: its segments, the best jumps between them, and the owner's approvals and rejections.
/// It is saved beside the MIDI file as `<name>.loopmap.json` (format `bss-midiloop/1`), so the analysis runs once.
public struct LoopMap: Sendable, Codable, Equatable {
    public static let format = "bss-midiloop/1"
    /// Bumped when the analysis changes, so an old sidecar is re-analysed rather than read back.
    public static let analyzerVersion = 2

    public let format: String
    public let analyzer: Int
    public let fingerprint: String
    public let style: LoopStyle
    public let segments: [LoopSegment]
    /// The two best jumps from each segment's end, in segment order. The natural next segment is not listed.
    public let transitions: [Transition]
    /// Jumps that must never play. The owner's veto.
    public var rejected: [JumpPair]
    /// Jumps the owner wants. They are always offered, with the top score.
    public var approved: [JumpPair]

    public init(fingerprint: String, style: LoopStyle, segments: [LoopSegment], transitions: [Transition],
                rejected: [JumpPair] = [], approved: [JumpPair] = []) {
        self.format = LoopMap.format
        self.analyzer = LoopMap.analyzerVersion
        self.fingerprint = fingerprint
        self.style = style
        self.segments = segments
        self.transitions = transitions
        self.rejected = rejected
        self.approved = approved
    }

    /// The jumps that may play from a segment's end, best first. Rejected jumps are gone; approved ones are added at score 1.
    public func jumps(from segment: Int) -> [Transition] {
        var result = transitions.filter { $0.from == segment && !rejected.contains(JumpPair(from: $0.from, to: $0.to)) }
        for pair in approved where pair.from == segment && pair.to >= 0 && pair.to < segments.count && pair.to != segment {
            guard !rejected.contains(pair) else { continue }
            if let i = result.firstIndex(where: { $0.to == pair.to }) {
                result[i] = Transition(from: pair.from, to: pair.to, score: 1, kind: result[i].kind)
            } else {
                result.append(Transition(from: pair.from, to: pair.to, score: 1, kind: .compatible))
            }
        }
        return result.sorted { $0.score != $1.score ? $0.score > $1.score : $0.to < $1.to }
    }

    /// The sidecar path for a MIDI file: `Song.mid` gives `Song.loopmap.json`.
    public static func sidecarURL(for midi: URL) -> URL {
        return midi.deletingPathExtension().appendingPathExtension("loopmap.json")
    }

    /// Reads the sidecar when it belongs to this piece and style. Otherwise analyses the piece and writes the sidecar,
    /// keeping the owner's approvals and rejections when the segment count still matches.
    /// A sidecar that is not valid `bss-midiloop/1` throws; delete it to have it re-analysed.
    public static func load(_ piece: MIDIPerformance, sidecar url: URL, style: LoopStyle = .balanced) throws -> LoopMap {
        var previous: LoopMap? = nil
        if FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw MIDILoopError.invalidSidecar("cannot read \(url.lastPathComponent)")
            }
            let stored: LoopMap
            do {
                stored = try JSONDecoder().decode(LoopMap.self, from: data)
            } catch {
                throw MIDILoopError.invalidSidecar("\(url.lastPathComponent) is not a bss-midiloop/1 file")
            }
            guard stored.format == LoopMap.format else {
                throw MIDILoopError.invalidSidecar("format \(stored.format) is not \(LoopMap.format)")
            }
            guard !stored.segments.isEmpty else { throw MIDILoopError.invalidSidecar("no segments") }
            if stored.fingerprint == piece.fingerprint && stored.style == style && stored.analyzer == LoopMap.analyzerVersion {
                return stored
            }
            previous = stored
        }

        var map = LoopAnalysis.analyze(piece, style: style)
        if let old = previous, old.segments.count == map.segments.count {
            map.rejected = old.rejected
            map.approved = old.approved
        }
        try map.write(to: url)
        return map
    }

    /// Writes the sidecar as readable JSON. It holds only the MIDI's fingerprint and the analysis: no paths, no names.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            throw MIDILoopError.sidecarWriteFailed(url.lastPathComponent)
        }
    }
}

extension LoopMap {
    /// Analyses a piece without reading or writing a sidecar: for checks and the command line.
    public static func analyze(_ piece: MIDIPerformance, style: LoopStyle = .balanced) -> LoopMap {
        return LoopAnalysis.analyze(piece, style: style)
    }
}
