import Foundation
import Testing
@testable import GullfireKit

/// Packages for the real-file parser tests: the colon-separated GULLFIRE_ENGINE_DIRS, or else the main checkout's Chicago
/// package when it has a streets.json. Only folders with a streets.json are used.
enum GraphParserPackages {
    static var envSet: Bool { ProcessInfo.processInfo.environment["GULLFIRE_ENGINE_DIRS"] != nil }
    static var dirs: [URL] {
        let names: [URL]
        if let env = ProcessInfo.processInfo.environment["GULLFIRE_ENGINE_DIRS"] {
            names = env.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        } else {
            names = [PackageTests.root.appendingPathComponent("Cities/Chicago", isDirectory: true)]
        }
        return names.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(StreetGraph.fileName).path) }
    }
}

/// The first place two graphs differ at the bit level (Doubles compared by bit pattern, strings by UTF-8), or nil when they are identical.
func graphDifference(_ a: StreetGraph, _ b: StreetGraph) -> String? {
    if a.format != b.format { return "format" }
    if a.altitude.bitPattern != b.altitude.bitPattern { return "altitude" }
    if a.spacing.bitPattern != b.spacing.bitPattern { return "spacing" }
    guard a.stretches.count == b.stretches.count else { return "stretch count \(a.stretches.count) vs \(b.stretches.count)" }
    for (x, y) in zip(a.stretches, b.stretches) {
        if Array(x.id.utf8) != Array(y.id.utf8) || Array(x.streetClass.utf8) != Array(y.streetClass.utf8) { return "id or class of \(x.id)" }
        if x.names.map({ Array($0.utf8) }) != y.names.map({ Array($0.utf8) }) { return "names of \(x.id)" }
        if x.length.bitPattern != y.length.bitPattern { return "length of \(x.id)" }
        if x.loops != y.loops { return "loops of \(x.id)" }
        guard x.points.count == y.points.count else { return "point count of \(x.id)" }
        for k in x.points.indices where x.points[k].bitPattern != y.points[k].bitPattern {
            return "point \(k) of \(x.id): \(x.points[k]) vs \(y.points[k])"
        }
    }
    return nil
}

@Suite("Street graph parser", .serialized)
struct StreetGraphParserTests {
    /// Every JSON feature the parser handles: loops absent, present and null, empty names, é and escapes, a surrogate pair,
    /// integers, negatives, exponents, whitespace, keys out of order and an unknown key holding nested values.
    static let edgeCases = #"""

	{
	  "unknown": {"deep": [1, 2.5e-3, {"x": null, "y": true, "z": false}, "s\"t"], "empty": {}, "e2": []},
	  "stretches" : [
	    {"loops": [true, false], "id": "a", "class": "primary", "names": [], "length": 1.5e3,
	     "points": [0, 0, -1.25, 2e-3, 1E2, -0.0, 3.0000000000000004, 123456789.123456789]},
	    {"id": "b\"qé😀", "class": "x\\y\/z", "names": ["Café", "Lee Street \/ Mannheim \"Road\"", "Tab\there"],
	     "length": 580, "points": [0,0,10,0,20,0], "loops": null, "extra": [ {"a": []} ]},
	    {"names": ["AA"], "id": "c", "class": "", "length": -12.75, "points": [1.0000000000000002, -3.3, 0.1, 1e-300, 1e300, 4.9e-324]},
	    {"id": "d", "class": "residential", "names": ["Ü"], "length": 0.5, "points": [], "loops": [false, false]}
	  ],
	  "spacing": 10,
	  "altitude": 15.0,
	  "format": 1
	}

	"""#

    static func parse(_ data: Data) throws -> StreetGraph {
        try data.withUnsafeBytes { try StreetGraphParser.parse($0) }
    }

    @Test func edgeCasesEqualJSONDecoder() throws {
        let data = Data(Self.edgeCases.utf8)
        let parsed = try Self.parse(data)
        let decoded = try JSONDecoder().decode(StreetGraph.self, from: data)
        #expect(parsed == decoded)
        #expect(graphDifference(parsed, decoded) == nil)
        #expect(parsed.stretches.count == 4)
        #expect(parsed.stretches[0].loops == [true, false])
        #expect(parsed.stretches[1].loops == nil)
        #expect(parsed.stretches[1].names[0] == "Café")
        #expect(parsed.stretches[1].id == "b\"q\u{e9}\u{1F600}")
        #expect(parsed.stretches[1].streetClass == "x\\y/z")
        #expect(parsed.stretches[2].loops == nil)
    }

    @Test func edgeCasesThroughLoadEqualJSONDecoder() throws {
        try StreetGraphFileTests.withDirectory { dir in
            let url = dir.appendingPathComponent(StreetGraph.fileName)
            try Data(Self.edgeCases.utf8).write(to: url)
            let loaded = try #require(try StreetGraph.load(fileAt: url))
            let decoded = try JSONDecoder().decode(StreetGraph.self, from: Data(Self.edgeCases.utf8))
            #expect(graphDifference(loaded, decoded) == nil)
        }
    }

    @Test func truncatedFileThrowsInParserAndLoad() throws {
        let full = Data(Self.edgeCases.utf8)
        // The literal ends in whitespace after the closing brace, so cuts of 1 or 2 bytes would leave valid JSON: cut from the brace on.
        for cut in [5, 10, full.count / 2] {
            let truncated = full.prefix(full.count - cut)
            #expect(throws: (any Error).self) { try Self.parse(Data(truncated)) }
        }
        try StreetGraphFileTests.withDirectory { dir in
            let url = dir.appendingPathComponent(StreetGraph.fileName)
            try Data(full.prefix(full.count / 2)).write(to: url)
            #expect(throws: (any Error).self) { try StreetGraph.load(fileAt: url) }
        }
    }

    /// Numbers and strings outside the JSON grammar must fail in the parser, so the fallback decides.
    @Test func malformedScalarsFailInTheParser() throws {
        for bad in ["01", "+1", "1.", ".5", "1e", "NaN", "--1", "1e400"] {
            let text = #"{"format":1,"altitude":\#(bad),"spacing":10,"stretches":[]}"#
            #expect(throws: (any Error).self, "altitude \(bad)") { try Self.parse(Data(text.utf8)) }
        }
        let rawControl = "{\"format\":1,\"altitude\":1,\"spacing\":10,\"stretches\":[{\"id\":\"a\u{01}\",\"class\":\"\",\"names\":[],\"length\":1,\"points\":[]}]}"
        #expect(throws: (any Error).self) { try Self.parse(Data(rawControl.utf8)) }
        let loneSurrogate = #"{"format":1,"altitude":1,"spacing":10,"stretches":[{"id":"\ud800","class":"","names":[],"length":1,"points":[]}]}"#
        #expect(throws: (any Error).self) { try Self.parse(Data(loneSurrogate.utf8)) }
    }

    @Test func wrongFormatThrowsUnsupportedFormat() throws {
        try StreetGraphFileTests.withDirectory { dir in
            let url = dir.appendingPathComponent(StreetGraph.fileName)
            try Data(#"{"format": 2, "altitude": 15.0, "spacing": 10.0, "stretches": []}"#.utf8).write(to: url)
            #expect(throws: StreetGraphError.unsupportedFormat(2)) { try StreetGraph.load(fileAt: url) }
        }
    }

    /// A future format may change the schema. The parser fails on it, and the fallback must still say "unsupported", not a decode error.
    @Test func futureFormatWithAnotherSchemaStillThrowsUnsupportedFormat() throws {
        try StreetGraphFileTests.withDirectory { dir in
            let url = dir.appendingPathComponent(StreetGraph.fileName)
            try Data(#"{"format": 2, "stretches": "future", "spacing": 10}"#.utf8).write(to: url)
            #expect(throws: StreetGraphError.unsupportedFormat(2)) { try StreetGraph.load(fileAt: url) }
        }
    }

    @Test func missingFormatIsAnError() throws {
        try StreetGraphFileTests.withDirectory { dir in
            let url = dir.appendingPathComponent(StreetGraph.fileName)
            try Data(#"{"altitude": 15.0, "spacing": 10.0, "stretches": []}"#.utf8).write(to: url)
            #expect(throws: (any Error).self) { try StreetGraph.load(fileAt: url) }
        }
    }

    @Test func emptyStretchesParse() throws {
        let text = #"{"format":1,"altitude":15,"spacing":10,"stretches":[]}"#
        let parsed = try Self.parse(Data(text.utf8))
        #expect(parsed == StreetGraph(format: 1, altitude: 15, spacing: 10, stretches: []))
    }

    /// The real packages: every stretch and every Double must match JSONDecoder exactly.
    @Test(.enabled(if: !GraphParserPackages.dirs.isEmpty), arguments: GraphParserPackages.dirs)
    func realFileEqualsJSONDecoder(dir: URL) throws {
        let data = try Data(contentsOf: dir.appendingPathComponent(StreetGraph.fileName), options: .alwaysMapped)
        let parsed = try Self.parse(data)
        let decoded = try JSONDecoder().decode(StreetGraph.self, from: data)
        #expect(graphDifference(parsed, decoded) == nil, "\(dir.lastPathComponent): \(graphDifference(parsed, decoded) ?? "")")
        #expect(parsed == decoded)
        print("GRAPHPARSE \(dir.lastPathComponent) | stretches \(parsed.stretches.count) | points \(parsed.stretches.reduce(0) { $0 + $1.points.count })")
    }

    /// Resident memory around StreetGraph.load, as the app sees it. Off unless GULLFIRE_ENGINE_DIRS is set.
    @Test(.enabled(if: GraphParserPackages.envSet), arguments: GraphParserPackages.dirs)
    func loadLeavesOnlyTheDataResident(dir: URL) throws {
        let file = dir.appendingPathComponent(StreetGraph.fileName)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let fileMB = Double(size) / 1_048_576
        let before = RouteSoak.residentMB()
        let graph = try #require(try StreetGraph.load(fileAt: file))
        malloc_zone_pressure_relief(nil, 0)
        let after = RouteSoak.residentMB()
        let delta = after - before
        print(String(format: "GRAPHMEM %@ | file %.1f MB | RSS delta %.1f MB", dir.lastPathComponent, fileMB, delta))
        #expect(graph.stretches.count > 0)
        #expect(delta <= 1.6 * fileMB + 25, "RSS grew \(delta) MB for a \(fileMB) MB file")
    }
}
