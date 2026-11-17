import Foundation
import Testing
@testable import GullfireKit

/// Tests on the real Chicago package. They skip when Cities/Chicago has not been built,
/// since that data is git-ignored and comes from Tools/fetch_city.py.
@Suite("Chicago package")
struct PackageTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let chicago = root.appendingPathComponent("Cities/Chicago", isDirectory: true)
    /// Every built city that also has both cruise routes. Chicago was the first; Vienna the second.
    static let cities: [URL] = ["Chicago", "Vienna"].map { root.appendingPathComponent("Cities/\($0)", isDirectory: true) }
        .filter { dir in
            ["manifest.json", "routes/river.json", "routes/scenic.json"].allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
        }
    static var built: Bool {
        FileManager.default.fileExists(atPath: chicago.appendingPathComponent("manifest.json").path)
    }

    @Test(.enabled(if: PackageTests.built)) func lineGroupRangesAreContiguousAndSumToSegments() throws {
        let m = try CityPackage.open(directory: Self.chicago).manifest
        var next = 0
        for range in m.lineGroups {
            #expect(range.first == next)
            next = range.first + range.count
        }
        #expect(next == m.segmentCount)
    }

    @Test(.enabled(if: PackageTests.built)) func fileSizesMatchCounts() throws {
        let p = try CityPackage.open(directory: Self.chicago)
        #expect(p.solids.count == p.manifest.solidTriangleCount * 36)
        #expect(p.lines.count == p.manifest.segmentCount * 24)
        #expect(p.obstacles.count == p.manifest.obstacleGrid.cols * p.manifest.obstacleGrid.rows * 4)
    }

    @Test(.enabled(if: PackageTests.built)) func willisTowerIsAtLeast355Metres() throws {
        let landmarks = try CityPackage.open(directory: Self.chicago).landmarks()
        let willis = landmarks.first { $0.name.contains("Willis") }
        #expect(willis != nil)
        #expect((willis?.heightM ?? 0) >= 355)
    }

    /// The landmark centre is the building outline's centre. For Willis Tower the 527 m
    /// part is a small antenna about 13 m away, so the test searches a 30 m radius.
    @Test(.enabled(if: PackageTests.built)) func obstacleGridReachesLandmarkHeightNearItsCentre() throws {
        let p = try CityPackage.open(directory: Self.chicago)
        let t = try #require(try p.landmarks().first)
        var highest: Float = 0
        for dx in stride(from: -30.0, through: 30.0, by: 4.0) {
            for dy in stride(from: -30.0, through: 30.0, by: 4.0) where dx * dx + dy * dy <= 900 {
                highest = max(highest, p.obstacleHeight(east: t.east + dx, north: t.north + dy))
            }
        }
        #expect(highest >= Float(t.heightM) * 0.99)
    }

    /// A cell in the lake is 0. The point is checked to lie inside a
    /// clipped lake polygon before the height is asserted, so the test cannot pass vacuously.
    @Test(.enabled(if: PackageTests.built)) func cellInTheClippedLakeIsZero() throws {
        let p = try CityPackage.open(directory: Self.chicago)
        let origin = p.manifest.origin
        let frame = LocalFrame(lon0: origin.lon, lat0: origin.lat)
        let point = SIMD2<Double>(2500, 0)   // east of the shoreline, metres
        var inLake = false
        try GeoJSONLines.forEachFeature(at: Self.chicago.appendingPathComponent("raw/water_clipped.geojsonl")) { feature in
            guard let props = feature["properties"] as? [String: Any],
                  props["subtype"] as? String == "lake",
                  let geometry = feature["geometry"] as? [String: Any] else { return }
            for polygon in PackageWriter.polygons(geometry, frame) {
                guard let outer = polygon.first, ObstacleGrid.contains(outer, point.x, point.y) else { continue }
                let inHole = polygon.dropFirst().contains { ObstacleGrid.contains($0, point.x, point.y) }
                if !inHole { inLake = true }
            }
        }
        #expect(inLake, "the test point must lie inside the clipped lake")
        #expect(p.obstacleHeight(east: point.x, north: point.y) == 0)
    }

    /// Clipping to the box must not leave water edges along the box boundary.
    /// Both endpoints of a water segment are checked in metres; 0.05 m is far below the 1e-7 degree
    /// tolerance the pack tool uses (about 0.01 m).
    @Test(.enabled(if: PackageTests.built)) func noWaterSegmentRunsAlongTheBoxBoundary() throws {
        let p = try CityPackage.open(directory: Self.chicago)
        let range = p.lineRange(.water)
        #expect(range.count > 5000)
        let e = p.manifest.extentM
        let tol = 0.05
        let floats = p.lines.withUnsafeBytes { raw -> [Float] in
            Array(raw.bindMemory(to: Float.self))
        }
        func onEdge(_ x: Float, _ lo: Double, _ hi: Double) -> Bool {
            abs(Double(x) - lo) < tol || abs(Double(x) - hi) < tol
        }
        var bad = 0
        for seg in range {
            let i = seg * 6
            let ax = Double(floats[i]), az = -Double(floats[i + 2])     // render z = -north
            let bx = Double(floats[i + 3]), bz = -Double(floats[i + 5])
            let sameEast = abs(ax - e.minEast) < tol && abs(bx - e.minEast) < tol
            let sameWest = abs(ax - e.maxEast) < tol && abs(bx - e.maxEast) < tol
            let sameSouth = abs(az - e.minNorth) < tol && abs(bz - e.minNorth) < tol
            let sameNorth = abs(az - e.maxNorth) < tol && abs(bz - e.maxNorth) < tol
            if sameEast || sameWest || sameSouth || sameNorth { bad += 1 }
        }
        #expect(bad == 0, "water segments on the box boundary: \(bad)")
    }

    @Test(.enabled(if: PackageTests.built)) func manifestHasNoAbsolutePaths() throws {
        let text = try String(contentsOf: Self.chicago.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(!text.contains(NSHomeDirectory()))
    }
}
