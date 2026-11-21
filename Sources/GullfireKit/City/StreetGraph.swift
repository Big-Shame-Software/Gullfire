import Foundation

public enum StreetGraphError: Error, Equatable {
    case unsupportedFormat(Int)
}

/// One vetted stretch: an open, straight street range that is clear at the graph's altitude.
/// `points` is the centre line flattened as east, north pairs, in metres, at the graph's spacing.
public struct StreetStretch: Codable, Sendable, Equatable {
    public var id: String
    public var streetClass: String
    public var names: [String]
    /// Metres.
    public var length: Double
    public var points: [Double]
    /// Whether a loop can start with this stretch flown forward (index 0) or reversed (index 1), found when the package was
    /// built (`gullfire-pack loops`). nil when the package was never checked: every stretch is then taken to work.
    public var loops: [Bool]?

    enum CodingKeys: String, CodingKey {
        case id
        case streetClass = "class"
        case names
        case length
        case points
        case loops
    }

    public init(id: String, streetClass: String, names: [String], length: Double, points: [Double], loops: [Bool]? = nil) {
        self.loops = loops
        self.id = id
        self.streetClass = streetClass
        self.names = names
        self.length = length
        self.points = points
    }

    /// Can a loop start with this stretch in the given direction? True when the package was never checked.
    public func canStart(reversed: Bool) -> Bool {
        guard let loops, loops.count == 2 else { return true }
        return loops[reversed ? 1 : 0]
    }

    /// Can a loop start with this stretch in either direction?
    public var canStartAny: Bool { canStart(reversed: false) || canStart(reversed: true) }

    /// The centre line as (east, north) pairs in metres. A trailing unpaired value is ignored.
    public var polyline: [SIMD2<Double>] {
        stride(from: 0, to: points.count - 1, by: 2).map { SIMD2(points[$0], points[$0 + 1]) }
    }

    public var first: SIMD2<Double>? { polyline.first }
    public var last: SIMD2<Double>? { polyline.last }
}

/// `streets.json` in a city package. It is optional: a package built before it existed has no such file.
/// Only format 1 is accepted.
public struct StreetGraph: Codable, Sendable, Equatable {
    public var format: Int
    /// Metres above ground at which every stretch was checked clear.
    public var altitude: Double
    /// Metres between centre-line points.
    public var spacing: Double
    public var stretches: [StreetStretch]

    public static let fileName = "streets.json"

    public init(format: Int, altitude: Double, spacing: Double, stretches: [StreetStretch]) {
        self.format = format
        self.altitude = altitude
        self.spacing = spacing
        self.stretches = stretches
    }

    /// The graph in `directory/streets.json`, or nil when that file does not exist.
    /// Throws when the file exists but cannot be decoded, or when its format is not 1.
    public static func load(from directory: URL) throws -> StreetGraph? {
        try load(fileAt: directory.appendingPathComponent(fileName))
    }

    /// The same, from a named file (a test reads the vetted graph the 1.0 street routes were made from).
    public static func load(fileAt url: URL) throws -> StreetGraph? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        // Check the format before the rest, so a future format fails as "unsupported", not as a decoding error.
        struct Header: Decodable { var format: Int }
        let format = try JSONDecoder().decode(Header.self, from: data).format
        guard format == 1 else { throw StreetGraphError.unsupportedFormat(format) }
        return try JSONDecoder().decode(StreetGraph.self, from: data)
    }

    /// Total length of every stretch, in kilometres.
    public var totalLengthKm: Double {
        stretches.reduce(0) { $0 + $1.length } / 1000
    }
}
