import Foundation

/// The optional tile index in `manifest.json`. Within format 1, `tiles` is an
/// additive field: a reader that ignores it draws the same picture, because tiles only re-order the
/// geometry, they do not change which segments or triangles exist.
public struct TileIndex: Codable, Sendable, Equatable {
    public struct Range: Codable, Sendable, Equatable {
        /// Absolute segment index into `lines.bin`.
        public var first: Int
        public var count: Int
        /// Leading segments of the range that are not base edges (the reduced version).
        public var farCount: Int
        /// Building groups only: `tallCounts[i]` is how many of the range's leading
        /// segments come from buildings with top >= `heightCutsM[i]`. Nil for water and roads.
        public var tallCounts: [Int]? = nil
    }
    public struct Entry: Codable, Sendable, Equatable {
        public var col: Int
        public var row: Int
        /// East, north, up, in metres, over every point of the tile's segments and triangles.
        public var min: [Double]
        public var max: [Double]
        /// Absolute vertex index into `solids.bin` (3 vertices per triangle), and a vertex count.
        public var solidFirst: Int
        public var solidCount: Int
        /// In `LineGroup` order.
        public var lines: [Range]
    }
    public struct Always: Codable, Sendable, Equatable {
        public var solidFirst: Int
        public var solidCount: Int
    }

    public var sizeM: Double
    public var cols: Int
    public var rows: Int
    /// The ground quad, drawn whatever the camera sees.
    public var always: Always
    /// Non-empty tiles only, in ascending tile index (`row * cols + col`).
    public var entries: [Entry]
    /// Building heights in metres at which `Range.tallCounts` is counted, ascending. Optional and
    /// additive; absent in packages made before it.
    public var heightCutsM: [Double]? = nil
}

/// `manifest.json` in a city package. `formatVersion` 1 is a public promise.
/// `tiles` is an optional addition within format 1; absent in older packages.
public struct Manifest: Codable, Sendable, Equatable {
    public struct Origin: Codable, Sendable, Equatable {
        public var lon: Double
        public var lat: Double
    }
    public struct BBox: Codable, Sendable, Equatable {
        public var minLon: Double
        public var minLat: Double
        public var maxLon: Double
        public var maxLat: Double
    }
    public struct Extent: Codable, Sendable, Equatable {
        public var minEast: Double
        public var maxEast: Double
        public var minNorth: Double
        public var maxNorth: Double
    }
    public struct Licence: Codable, Sendable, Equatable {
        public var dataset: String
        public var license: String
        public var count: Int
    }
    public struct FileEntry: Codable, Sendable, Equatable {
        public var name: String
        public var bytes: Int
        /// Vertices for solids, segments for lines, cells for the obstacle grid.
        public var count: Int
    }
    public struct LineGroupRange: Codable, Sendable, Equatable {
        public var name: String
        public var first: Int
        public var count: Int
    }
    public struct ObstacleGridInfo: Codable, Sendable, Equatable {
        public var cols: Int
        public var rows: Int
        public var cellSizeM: Double
        public var minEast: Double
        public var minNorth: Double
    }
    public struct HeightCounts: Codable, Sendable, Equatable {
        public var measured: Int
        public var floors: Int
        public var defaulted: Int

        enum CodingKeys: String, CodingKey {
            case measured, floors
            case defaulted = "default"
        }
    }

    public var formatVersion: Int
    public var name: String
    public var origin: Origin
    public var bbox: BBox
    public var extentM: Extent
    public var overtureRelease: String
    public var attribution: String
    public var licences: [Licence]
    public var files: [FileEntry]
    public var solidCount: Int
    public var solidTriangleCount: Int
    public var segmentCount: Int
    /// In `LineGroup` order: buildings measured, floors, default, water, roads.
    public var lineGroups: [LineGroupRange]
    public var obstacleGrid: ObstacleGridInfo
    public var heights: HeightCounts
    public var tiles: TileIndex? = nil
}
