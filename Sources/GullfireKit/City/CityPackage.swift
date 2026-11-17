import Foundation

public enum PackageError: Error, Equatable {
    case unsupportedFormat(Int)
    case sizeMismatch(file: String, expected: Int, actual: Int)
}

/// A city package opened read-only. The binary files are memory-mapped, so the system can
/// drop their pages under pressure without any copy.
public struct CityPackage: Sendable {
    public let directory: URL
    public let manifest: Manifest
    public let solids: Data
    public let lines: Data
    public let obstacles: Data

    public static func open(directory: URL) throws -> CityPackage {
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.formatVersion == 1 else { throw PackageError.unsupportedFormat(manifest.formatVersion) }
        let solids = try Data(contentsOf: directory.appendingPathComponent("solids.bin"), options: .alwaysMapped)
        let lines = try Data(contentsOf: directory.appendingPathComponent("lines.bin"), options: .alwaysMapped)
        let obstacles = try Data(contentsOf: directory.appendingPathComponent("obstacles.bin"), options: .alwaysMapped)

        let expectedSolids = manifest.solidTriangleCount * 3 * 12
        guard solids.count == expectedSolids else {
            throw PackageError.sizeMismatch(file: "solids.bin", expected: expectedSolids, actual: solids.count)
        }
        let expectedLines = manifest.segmentCount * 24
        guard lines.count == expectedLines else {
            throw PackageError.sizeMismatch(file: "lines.bin", expected: expectedLines, actual: lines.count)
        }
        let expectedObstacles = manifest.obstacleGrid.cols * manifest.obstacleGrid.rows * 4
        guard obstacles.count == expectedObstacles else {
            throw PackageError.sizeMismatch(file: "obstacles.bin", expected: expectedObstacles, actual: obstacles.count)
        }
        return CityPackage(directory: directory, manifest: manifest,
                           solids: solids, lines: lines, obstacles: obstacles)
    }

    /// Segment indices for one line group.
    public func lineRange(_ group: LineGroup) -> Range<Int> {
        let range = manifest.lineGroups[group.rawValue]
        return range.first..<(range.first + range.count)
    }

    /// Tallest building height at a point, in metres (0 where nothing stands or outside the grid).
    public func obstacleHeight(east: Double, north: Double) -> Float {
        let g = manifest.obstacleGrid
        guard let index = ObstacleGrid.index(east: east, north: north, minEast: g.minEast, minNorth: g.minNorth,
                                             cellSize: g.cellSizeM, cols: g.cols, rows: g.rows) else { return 0 }
        return obstacles.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 4, as: Float.self) }
    }

    /// Landmarks written beside the package.
    public func landmarks() throws -> [Landmark] {
        struct File: Decodable { let landmarks: [Landmark] }
        let data = try Data(contentsOf: directory.appendingPathComponent("landmarks.json"))
        return try JSONDecoder().decode(File.self, from: data).landmarks
    }
}
