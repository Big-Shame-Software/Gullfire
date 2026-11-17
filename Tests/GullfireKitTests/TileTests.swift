import Foundation
import Testing
@testable import GullfireKit

/// Tile index tests on the real packages. They skip when a city is not built,
/// as `PackageTests` does.
@Suite("Tile index")
struct TileTests {
    static let cityNames = ["Chicago", "Vienna"]

    static func directory(_ name: String) -> URL {
        PackageTests.root.appendingPathComponent("Cities/\(name)", isDirectory: true)
    }

    static var built: Bool {
        cityNames.allSatisfy {
            FileManager.default.fileExists(atPath: directory($0).appendingPathComponent("manifest.json").path)
        }
    }

    static func open(_ name: String) throws -> (package: CityPackage, tiles: TileIndex) {
        let package = try CityPackage.open(directory: directory(name))
        return (package, try #require(package.manifest.tiles))
    }

    @Test(.enabled(if: TileTests.built), arguments: ["Chicago", "Vienna"])
    func tilesArePresentAndOnTheGrid(name: String) throws {
        let (package, t) = try Self.open(name)
        #expect(package.manifest.formatVersion == 1)
        #expect(t.sizeM == PackageWriter.tileSizeM)
        #expect(t.cols > 0 && t.rows > 0)
        #expect(!t.entries.isEmpty && t.entries.count <= t.cols * t.rows)
        #expect(t.always.solidCount == 6, "the ground quad is two triangles")
        for e in t.entries {
            #expect(e.col >= 0 && e.col < t.cols && e.row >= 0 && e.row < t.rows)
        }
    }

    /// Each group's ranges, in entry (tile) order, are contiguous and cover exactly the group's range.
    @Test(.enabled(if: TileTests.built), arguments: ["Chicago", "Vienna"])
    func lineRangesPartEachGroup(name: String) throws {
        let (package, t) = try Self.open(name)
        for (g, group) in package.manifest.lineGroups.enumerated() {
            var next = group.first
            for e in t.entries {
                let r = e.lines[g]
                #expect(r.first == next, "group \(group.name), tile \(e.col),\(e.row)")
                #expect(r.farCount >= 0 && r.farCount <= r.count)
                next = r.first + r.count
            }
            #expect(next == group.first + group.count, "group \(group.name) is covered to its end")
        }
    }

    /// Entry solid ranges plus the ground quad cover every vertex exactly once.
    @Test(.enabled(if: TileTests.built), arguments: ["Chicago", "Vienna"])
    func solidRangesPartTheTriangles(name: String) throws {
        let (package, t) = try Self.open(name)
        var spans = t.entries.map { ($0.solidFirst, $0.solidCount) }
        spans.append((t.always.solidFirst, t.always.solidCount))
        spans = spans.filter { $0.1 > 0 }
        spans.sort { $0.0 < $1.0 }
        var next = 0
        for (first, count) in spans {
            #expect(count % 3 == 0)
            #expect(first == next, "solid range starts at \(first), expected \(next)")
            next = first + count
        }
        #expect(next == package.manifest.solidTriangleCount * 3)
    }

    /// Every point of every segment and triangle lies inside its tile's box (1e-3 m). The ground quad is exempt.
    @Test(.enabled(if: TileTests.built), arguments: ["Chicago", "Vienna"])
    func everyPointLiesInsideItsTileBox(name: String) throws {
        let (package, t) = try Self.open(name)
        let lines = package.lines.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let solids = package.solids.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let tol = 1e-3
        var outside = 0
        for e in t.entries {
            // Render space: x = east, y = up, z = -north.
            func inside(_ x: Float, _ y: Float, _ z: Float) -> Bool {
                let east = Double(x), up = Double(y), north = -Double(z)
                return east >= e.min[0] - tol && east <= e.max[0] + tol
                    && north >= e.min[1] - tol && north <= e.max[1] + tol
                    && up >= e.min[2] - tol && up <= e.max[2] + tol
            }
            for r in e.lines {
                for s in r.first..<(r.first + r.count) {
                    let i = s * 6
                    if !inside(lines[i], lines[i + 1], lines[i + 2]) || !inside(lines[i + 3], lines[i + 4], lines[i + 5]) {
                        outside += 1
                    }
                }
            }
            for v in e.solidFirst..<(e.solidFirst + e.solidCount) {
                let i = v * 3
                if !inside(solids[i], solids[i + 1], solids[i + 2]) { outside += 1 }
            }
        }
        #expect(outside == 0, "points outside their tile box: \(outside)")
    }

    /// In the three building groups, the edges past `farCount` are base edges: horizontal.
    @Test(.enabled(if: TileTests.built), arguments: ["Chicago", "Vienna"])
    func buildingBaseEdgesAreTheTailAndHorizontal(name: String) throws {
        let (package, t) = try Self.open(name)
        let lines = package.lines.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var checked = 0
        var notHorizontal = 0
        for e in t.entries {
            for g in 0...2 {
                let r = e.lines[g]
                for s in (r.first + r.farCount)..<(r.first + r.count) {
                    let i = s * 6
                    checked += 1
                    if abs(lines[i + 1] - lines[i + 4]) > 1e-4 { notHorizontal += 1 }
                }
            }
        }
        #expect(checked > 0)
        #expect(notHorizontal == 0, "base edges that are not horizontal: \(notHorizontal) of \(checked)")
    }

    /// Brief T4b: in each building group, `tallCounts[i]` leading non-base segments reach `heightCutsM[i]`,
    /// the non-base segments are sorted tallest first, and the counts are non-increasing and at most `farCount`.
    /// Water and roads carry no counts. Tolerance 1e-3 m.
    @Test(.enabled(if: TileTests.built), arguments: ["Chicago", "Vienna"])
    func tallCountsAreHeightPrefixes(name: String) throws {
        let (package, t) = try Self.open(name)
        let cuts = try #require(t.heightCutsM)
        #expect(cuts == [8, 15, 30, 60, 120])
        let lines = package.lines.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        func top(_ s: Int) -> Double { Double(max(lines[s * 6 + 1], lines[s * 6 + 4])) }
        let tol = 1e-3
        var checked = 0
        var badCounts = 0, badPrefix = 0, badRest = 0, unsorted = 0
        for e in t.entries {
            for g in 0...2 {
                let r = e.lines[g]
                let tall = try #require(r.tallCounts)
                #expect(tall.count == cuts.count)
                for i in 0..<tall.count {
                    if i > 0 && tall[i] > tall[i - 1] { badCounts += 1 }
                    if tall[i] > r.farCount || tall[i] < 0 { badCounts += 1 }
                    for s in r.first..<(r.first + tall[i]) {
                        checked += 1
                        if top(s) < cuts[i] - tol { badPrefix += 1 }
                    }
                    for s in (r.first + tall[i])..<(r.first + r.farCount) where top(s) > cuts[i] + tol {
                        badRest += 1
                    }
                }
                if r.farCount > 1 {
                    for s in r.first..<(r.first + r.farCount - 1) where top(s) < top(s + 1) { unsorted += 1 }
                }
            }
            #expect(e.lines[3].tallCounts == nil && e.lines[4].tallCounts == nil)
        }
        #expect(checked > 0)
        #expect(badCounts == 0, "counts not non-increasing or above farCount: \(badCounts)")
        #expect(badPrefix == 0, "prefix segments below their cut: \(badPrefix)")
        #expect(badRest == 0, "segments past a prefix at or above its cut: \(badRest)")
        #expect(unsorted == 0, "non-base segments not tallest first: \(unsorted)")
    }

    /// A manifest without `tiles` decodes with `tiles == nil`, and one with it decodes with it.
    @Test func manifestWithoutTilesDecodesWithNil() throws {
        let index = TileIndex(sizeM: 500, cols: 1, rows: 1,
                              always: .init(solidFirst: 0, solidCount: 6),
                              entries: [])
        let manifest = Manifest(
            formatVersion: 1, name: "Test", origin: .init(lon: 0, lat: 0),
            bbox: .init(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1),
            extentM: .init(minEast: 0, maxEast: 1, minNorth: 0, maxNorth: 1),
            overtureRelease: "test", attribution: "test", licences: [], files: [],
            solidCount: 0, solidTriangleCount: 0, segmentCount: 0, lineGroups: [],
            obstacleGrid: .init(cols: 1, rows: 1, cellSizeM: 4, minEast: 0, minNorth: 0),
            heights: .init(measured: 0, floors: 0, defaulted: 0),
            tiles: index)
        let full = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(Manifest.self, from: full).tiles == index)

        var object = try #require(try JSONSerialization.jsonObject(with: full) as? [String: Any])
        object.removeValue(forKey: "tiles")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let old = try JSONDecoder().decode(Manifest.self, from: stripped)
        #expect(old.tiles == nil)
        #expect(old.name == "Test")
    }

    /// The backed-up pre-tiles packages (made before this change) still open. Skipped when absent.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: TileTests.directory("Chicago").appendingPathComponent("pre-tiles/manifest.json").path)))
    func oldPackageWithoutTilesStillOpens() throws {
        let p = try CityPackage.open(directory: Self.directory("Chicago").appendingPathComponent("pre-tiles"))
        #expect(p.manifest.tiles == nil)
        #expect(p.manifest.segmentCount == 563689)
    }
}

/// The out-of-core packer (`TileSpill`) writes the same bytes as the in-memory one.
@Suite("Out-of-core pack", .serialized)
struct OutOfCorePackTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: TileTests.directory("Chicago").appendingPathComponent("raw/source.json").path)))
    func sameBytesAsInMemory() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ooc-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        var outputs: [[String: Data]] = []
        for outOfCore in [false, true] {
            let dir = base.appendingPathComponent(outOfCore ? "ooc" : "mem", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: dir.appendingPathComponent("raw"),
                                      withDestinationURL: TileTests.directory("Chicago").appendingPathComponent("raw"))
            try PackageWriter.write(cityDirectory: dir, outOfCore: outOfCore)
            #expect(!fm.fileExists(atPath: dir.appendingPathComponent("spill").path), "the spill folder is removed")
            var files: [String: Data] = [:]
            for name in ["solids.bin", "lines.bin", "obstacles.bin", "manifest.json", "landmarks.json"] {
                files[name] = try Data(contentsOf: dir.appendingPathComponent(name), options: .mappedIfSafe)
            }
            outputs.append(files)
        }
        for name in outputs[0].keys {
            #expect(outputs[0][name] == outputs[1][name], "\(name) is identical")
        }
    }
}
