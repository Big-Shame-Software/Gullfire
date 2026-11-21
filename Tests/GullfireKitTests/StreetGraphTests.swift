import Foundation
import Testing
@testable import GullfireKit

/// Tests on the real Chicago street graph. They skip when Cities/Chicago/streets.json has not been made
/// by Tools/make_street_graph.py, since that data is git-ignored.
@Suite("Street graph, Chicago")
struct StreetGraphChicagoTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let chicago = root.appendingPathComponent("Cities/Chicago", isDirectory: true)
    static var built: Bool {
        FileManager.default.fileExists(atPath: chicago.appendingPathComponent(StreetGraph.fileName).path)
    }

    @Test(.enabled(if: StreetGraphChicagoTests.built)) func chicagoHasAboutTwoHundredAndSeventyStretchesAndOneHundredFiftyKm() throws {
        let graph = try #require(try StreetGraph.load(from: Self.chicago))
        #expect(graph.format == 1)
        #expect(graph.stretches.count >= 250 && graph.stretches.count <= 300)
        #expect(graph.totalLengthKm >= 140 && graph.totalLengthKm <= 160)
    }

    /// The generator samples by arc length, so a gap is exactly 10 m along the street and a straight-line
    /// gap can be a little shorter where the street bends. Measured on Chicago, 3 of 6468 gaps (all at bends,
    /// 9.3 to 9.5 m) miss the 0.5 m band; the test allows that and checks nothing else is off.
    @Test(.enabled(if: StreetGraphChicagoTests.built)) func everyStretchIsLongEnoughAndEvenlySpaced() throws {
        let graph = try #require(try StreetGraph.load(from: Self.chicago))
        var gaps = 0
        var outside = 0
        for stretch in graph.stretches {
            #expect(stretch.points.count % 2 == 0, "\(stretch.id) has an unpaired coordinate")
            #expect(stretch.polyline.count >= 3, "\(stretch.id) has fewer than 3 points")
            #expect(stretch.length >= 300, "\(stretch.id) is \(stretch.length) m")
            let line = stretch.polyline
            for i in 1..<line.count {
                let step = line[i] - line[i - 1]
                let gap = (step.x * step.x + step.y * step.y).squareRoot()
                // The last gap can be shorter than the spacing where the stretch ends.
                if i < line.count - 1 {
                    gaps += 1
                    if abs(gap - graph.spacing) > 0.5 { outside += 1 }
                    #expect(gap <= graph.spacing + 0.2, "\(stretch.id) gap \(i) is \(gap) m")
                    #expect(gap >= graph.spacing - 1.0, "\(stretch.id) gap \(i) is \(gap) m")
                }
            }
        }
        #expect(Double(outside) < Double(gaps) * 0.001, "\(outside) of \(gaps) gaps are more than 0.5 m from 10 m")
    }

    @Test(.enabled(if: StreetGraphChicagoTests.built)) func mostStretchesHaveAStreetName() throws {
        let graph = try #require(try StreetGraph.load(from: Self.chicago))
        let named = graph.stretches.filter { !$0.names.isEmpty && $0.names.allSatisfy { !$0.isEmpty } }
        #expect(named.count * 2 > graph.stretches.count)
    }
}

@Suite("Street graph file")
struct StreetGraphFileTests {
    /// A fresh temporary directory, removed when the test ends.
    static func withDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StreetGraphTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    static let tiny = """
    {"format": 1, "altitude": 15.0, "spacing": 10.0, "stretches": [
      {"id": "0_0_0_20", "class": "primary", "names": ["Test Street"], "length": 620.0, "points": [0, 0, 0, 10, 0, 20]}
    ]}
    """

    @Test func missingFileIsNilNotAnError() throws {
        try Self.withDirectory { dir in
            let graph = try StreetGraph.load(from: dir)
            #expect(graph == nil)
        }
    }

    @Test func formatTwoThrows() throws {
        try Self.withDirectory { dir in
            let json = Self.tiny.replacingOccurrences(of: "\"format\": 1", with: "\"format\": 2")
            try json.write(to: dir.appendingPathComponent(StreetGraph.fileName), atomically: true, encoding: .utf8)
            #expect(throws: StreetGraphError.unsupportedFormat(2)) {
                try StreetGraph.load(from: dir)
            }
        }
    }

    @Test func badJSONThrows() throws {
        try Self.withDirectory { dir in
            try "{not json".write(to: dir.appendingPathComponent(StreetGraph.fileName), atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) {
                try StreetGraph.load(from: dir)
            }
        }
    }

    @Test func tinyFileDecodes() throws {
        try Self.withDirectory { dir in
            try Self.tiny.write(to: dir.appendingPathComponent(StreetGraph.fileName), atomically: true, encoding: .utf8)
            let graph = try #require(try StreetGraph.load(from: dir))
            #expect(graph.altitude == 15 && graph.spacing == 10)
            let s = try #require(graph.stretches.first)
            #expect(s.id == "0_0_0_20")
            #expect(s.streetClass == "primary")
            #expect(s.names == ["Test Street"])
            #expect(s.length == 620)
            #expect(s.polyline == [SIMD2(0, 0), SIMD2(0, 10), SIMD2(0, 20)])
            #expect(s.first == SIMD2(0, 0))
            #expect(s.last == SIMD2(0, 20))
            #expect(abs(graph.totalLengthKm - 0.62) < 1e-9)
        }
    }
}
