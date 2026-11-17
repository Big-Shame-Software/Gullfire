import Foundation

/// Cathedral mode: finds the track by its length, not its name. The Debussy "Engulfed Cathedral"
/// from the Escape From New York score runs 213.3 s, so any playable file of that length, in any
/// format, is the same track. The matching is pure and tested; the folder reads are in `MusicLibrary`.
public enum CathedralFinder {
    public static let targetSeconds = 213.3
    /// Encoders pad a little differently, so a file within this much counts.
    public static let toleranceSeconds = 1.5

    public struct Length: Equatable, Sendable {
        public let url: URL
        public let seconds: Double

        public init(url: URL, seconds: Double) {
            self.url = url
            self.seconds = seconds
        }
    }

    public struct Match: Equatable, Sendable {
        public let url: URL
        public let seconds: Double
        /// The file name says "engulfed" or "cathedral".
        public let nameHit: Bool

        public init(url: URL, seconds: Double, nameHit: Bool) {
            self.url = url
            self.seconds = seconds
            self.nameHit = nameHit
        }

        public var title: String { url.deletingPathExtension().lastPathComponent }
        public var format: String { url.pathExtension.uppercased() }
    }

    /// The files within `tolerance` of `target`, best first: name hits, then the closest length,
    /// then path order, so the same library always gives the same order.
    public static func rank(_ lengths: [Length], target: Double = targetSeconds,
                            tolerance: Double = toleranceSeconds) -> [Match] {
        lengths
            .filter { abs($0.seconds - target) <= tolerance }
            .map { Match(url: $0.url, seconds: $0.seconds, nameHit: isNamed($0.url)) }
            .sorted { a, b in
                if a.nameHit != b.nameHit { return a.nameHit }
                let da = abs(a.seconds - target)
                let db = abs(b.seconds - target)
                if da != db { return da < db }
                return a.url.path < b.url.path
            }
    }

    static func isNamed(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.contains("engulfed") || name.contains("cathedral")
    }

    /// m:ss, for the sheet and the notes.
    public static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
