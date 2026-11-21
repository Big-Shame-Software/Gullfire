import Foundation
import Testing
@testable import GullfireKit

/// Route engine, step 2: the Swift join builder must agree with the generator's `make_join` (Tools/make_street_routes.py).
/// The fixtures are written by `Spikes/engine/export_join_fixtures.py` into `Cities/<city>/spike/` (private; the suite skips
/// when they are absent). Each case is a pair of stretch ends the generator tried: feasible ones carry its path and altitude
/// profile, infeasible ones must come back nil.
enum JoinFixtures {
    struct Case: Decodable {
        let aEnd: [Double], aDir: [Double], bStart: [Double], bDir: [Double]
        let feasible: Bool
        let path: [[Double]]?
        let alt: [Double]?
        let startAlt: Double?, endAlt: Double?, length: Double?
    }
    struct File: Decodable {
        struct Args: Decodable { let alt, joinSpeed, maxJoin, maxClimb, maxTop: Double }
        let cellSizeM: Double
        let edge: [Double]
        let args: Args
        let cases: [Case]
    }
    /// Every package that has fixtures (Chicago; the engine never names a city).
    static let packages: [URL] = ["Chicago"].map { PackageTests.root.appendingPathComponent("Cities/\($0)", isDirectory: true) }
        .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("spike/join-fixtures.json").path) }
    static var available: Bool { !packages.isEmpty && PackageTests.built }
    static func load(_ dir: URL) throws -> File { try JSONDecoder().decode(File.self, from: Data(contentsOf: dir.appendingPathComponent("spike/join-fixtures.json"))) }

    static func settings(_ f: File) -> JoinSettings {
        JoinSettings(altitude: f.args.alt, joinSpeedKt: f.args.joinSpeed, maxJoin: f.args.maxJoin, maxClimb: f.args.maxClimb,
                     maxTop: f.args.maxTop, cellSize: f.cellSizeM,
                     minEast: f.edge[0], maxEast: f.edge[1], minNorth: f.edge[2], maxNorth: f.edge[3])
    }
}

@Suite("Join builder", .enabled(if: JoinFixtures.available))
struct JoinBuilderTests {
    /// Stated tolerances: the generator works in float64 on a float32 grid, as the Swift does, so the paths agree to well under a
    /// metre. A feasibility difference is a failure, not a tolerance.
    static let pathTolerance = 0.05      // metres, per path point
    static let altTolerance = 0.05       // metres, per profile point

    @Test(arguments: JoinFixtures.packages) func feasibilityMatchesTheGeneratorOnEveryCase(dir: URL) throws {
        let f = try JoinFixtures.load(dir)
        let city = try CityPackage.open(directory: dir)
        let s = JoinFixtures.settings(f)
        var wrong: [Int] = []
        for (i, c) in f.cases.enumerated() {
            let j = JoinBuilder.build(from: SIMD2(c.aEnd[0], c.aEnd[1]), heading: SIMD2(c.aDir[0], c.aDir[1]),
                                      to: SIMD2(c.bStart[0], c.bStart[1]), heading: SIMD2(c.bDir[0], c.bDir[1]),
                                      obstacles: city, settings: s)
            if (j != nil) != c.feasible { wrong.append(i) }
        }
        #expect(wrong.isEmpty, "feasibility differs from the generator on cases \(wrong)")
    }

    @Test(arguments: JoinFixtures.packages) func pathAndProfileMatchOnFeasibleCases(dir: URL) throws {
        let f = try JoinFixtures.load(dir)
        let city = try CityPackage.open(directory: dir)
        let s = JoinFixtures.settings(f)
        var worstPath = 0.0, worstAlt = 0.0, checked = 0
        for (i, c) in f.cases.enumerated() where c.feasible {
            guard let j = JoinBuilder.build(from: SIMD2(c.aEnd[0], c.aEnd[1]), heading: SIMD2(c.aDir[0], c.aDir[1]),
                                            to: SIMD2(c.bStart[0], c.bStart[1]), heading: SIMD2(c.bDir[0], c.bDir[1]),
                                            obstacles: city, settings: s),
                  let path = c.path, let alt = c.alt else { Issue.record("case \(i) did not build"); continue }
            #expect(j.path.count == path.count, "case \(i): \(j.path.count) path points, generator \(path.count)")
            guard j.path.count == path.count, j.alt.count == alt.count else { continue }
            for k in path.indices {
                worstPath = max(worstPath, ((j.path[k].x - path[k][0]) * (j.path[k].x - path[k][0]) + (j.path[k].y - path[k][1]) * (j.path[k].y - path[k][1])).squareRoot())
                worstAlt = max(worstAlt, abs(j.alt[k] - alt[k]))
            }
            #expect(abs(j.length - (c.length ?? 0)) < 0.5, "case \(i): length \(j.length), generator \(c.length ?? 0)")
            checked += 1
        }
        print(String(format: "JOIN PARITY \(dir.lastPathComponent): %d feasible cases, worst path difference %.4f m, worst altitude difference %.4f m", checked, worstPath, worstAlt))
        #expect(checked >= 20)
        #expect(worstPath < Self.pathTolerance)
        #expect(worstAlt < Self.altTolerance)
    }

    @Test(arguments: JoinFixtures.packages) func aJoinOutsideTheDistanceLimitsIsNil(dir: URL) throws {
        let f = try JoinFixtures.load(dir)
        let city = try CityPackage.open(directory: dir)
        let s = JoinFixtures.settings(f)
        let near = JoinBuilder.build(from: SIMD2(0, 0), heading: SIMD2(0, 1), to: SIMD2(0, 100), heading: SIMD2(0, 1), obstacles: city, settings: s)
        let far = JoinBuilder.build(from: SIMD2(0, 0), heading: SIMD2(0, 1), to: SIMD2(0, 2600), heading: SIMD2(0, 1), obstacles: city, settings: s)
        #expect(near == nil)
        #expect(far == nil)
    }
}
