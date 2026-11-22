import Foundation
import Testing
@testable import GullfireKit

/// The lap-seam checks on Chicago's Scenic and River routes. The waypoint files are the ones `Tools/make_routes.py`
/// and `gullfire-pack routes` write; the copies from before the seam fix are in `routes/_before_seam/`. Every test
/// skips with a message when its files are missing (Cities/ is git-ignored).
@Suite("Route seams")
struct RouteSeamTests {
    /// The plan's pitch limit as a gradient: tan(20 degrees).
    static let waypointLimit = tan(20.0 * Double.pi / 180)
    /// The 10 m samples are built by a Catmull-Rom spline that puts altitude linearly in its own parameter, so a
    /// sample gradient can exceed the waypoint gradient a little. The slack for that is 0.40.
    static let sampleLimit = 0.40
    /// The floor each route must never go below, metres.
    static let floors: [(name: String, floor: Double)] = [("river", 60), ("scenic", 70)]

    static let chicago = PackageTests.root.appendingPathComponent("Cities/Chicago", isDirectory: true)
    static let routes = chicago.appendingPathComponent("routes", isDirectory: true)
    static let beforeSeam = routes.appendingPathComponent("_before_seam", isDirectory: true)

    static func url(_ name: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(name).json")
    }
    static var routesPresent: Bool {
        floors.allSatisfy { FileManager.default.fileExists(atPath: url($0.name, in: routes).path) }
    }
    static var beforePresent: Bool {
        floors.allSatisfy { FileManager.default.fileExists(atPath: url($0.name, in: beforeSeam).path) }
    }

    static func file(_ name: String, in dir: URL) throws -> RouteFile {
        try JSONDecoder().decode(RouteFile.self, from: Data(contentsOf: url(name, in: dir)))
    }

    static func distance(_ a: (e: Double, n: Double), _ b: (e: Double, n: Double)) -> Double {
        ((a.e - b.e) * (a.e - b.e) + (a.n - b.n) * (a.n - b.n)).squareRoot()
    }

    @Test(.enabled(if: RouteSeamTests.routesPresent), arguments: RouteSeamTests.floors.map(\.name))
    func waypointGradientsStayWithinThePitchLimitAroundTheLoop(name: String) throws {
        let w = try Self.file(name, in: Self.routes).waypoints
        var worst = (g: 0.0, i: 0)
        for i in w.indices {
            let j = (i + 1) % w.count
            let d = Self.distance((w[i].east, w[i].north), (w[j].east, w[j].north))
            guard d > 0 else { continue }
            let g = abs(w[j].alt - w[i].alt) / d
            if g > worst.g { worst = (g, i) }
        }
        let j = (worst.i + 1) % w.count
        print(String(format: "SEAM %@ waypoints: max gradient %.3f between waypoint %d (%.0f m) and %d (limit %.3f)",
                     name, worst.g, worst.i, w[worst.i].alt, j, Self.waypointLimit))
        #expect(worst.g <= Self.waypointLimit + 1e-9,
                "\(name): waypoint pair \(worst.i)-\(j) changes at \(worst.g), above the pitch limit \(Self.waypointLimit)")
    }

    @Test(.enabled(if: RouteSeamTests.routesPresent), arguments: RouteSeamTests.floors.map(\.name))
    func sampleGradientsStayWithinSlackIncludingTheSeam(name: String) throws {
        let route = try Route.load(Self.url(name, in: Self.routes))
        let s = route.samples
        var worst = (g: 0.0, i: 0)
        for i in s.indices {
            let j = (i + 1) % s.count
            let d = Self.distance((s[i].east, s[i].north), (s[j].east, s[j].north))
            guard d > 0 else { continue }
            let g = abs(s[j].altitude - s[i].altitude) / d
            if g > worst.g { worst = (g, i) }
        }
        let seam = s.count - 1
        let seamGradient = abs(s[0].altitude - s[seam].altitude)
            / Self.distance((s[seam].east, s[seam].north), (s[0].east, s[0].north))
        print(String(format: "SEAM %@ samples: max gradient %.3f at sample %d of %d; the lap seam (last to first) %.3f, altitudes %.1f to %.1f m",
                     name, worst.g, worst.i, s.count, seamGradient, s[seam].altitude, s[0].altitude))
        #expect(worst.g <= Self.sampleLimit, "\(name): sample gradient \(worst.g) at \(worst.i), above \(Self.sampleLimit)")
    }

    @Test(.enabled(if: RouteSeamTests.routesPresent), arguments: RouteSeamTests.floors)
    func altitudeNeverBelowTheFloor(route: (name: String, floor: Double)) throws {
        let built = try Route.load(Self.url(route.name, in: Self.routes))
        let lowest = built.samples.map(\.altitude).min() ?? 0
        let lowestWaypoint = try Self.file(route.name, in: Self.routes).waypoints.map(\.alt).min() ?? 0
        print(String(format: "SEAM %@ lowest altitude %.2f m (floor %.0f m)", route.name, lowest, route.floor))
        #expect(lowest >= route.floor - 1e-6, "\(route.name) samples go to \(lowest), below the floor \(route.floor)")
        #expect(lowestWaypoint >= route.floor - 1e-6, "\(route.name) waypoints go to \(lowestWaypoint), below the floor \(route.floor)")
    }

    @Test(.enabled(if: RouteSeamTests.routesPresent && RouteSeamTests.beforePresent), arguments: RouteSeamTests.floors.map(\.name))
    func eastAndNorthAreUnchangedFromBeforeTheSeamFix(name: String) throws {
        let now = try Self.file(name, in: Self.routes).waypoints
        let before = try Self.file(name, in: Self.beforeSeam).waypoints
        #expect(now.count == before.count, "\(name): \(now.count) waypoints, \(before.count) before")
        var moved = 0.0
        for (a, b) in zip(now, before) {
            moved = max(moved, abs(a.east - b.east), abs(a.north - b.north))
            #expect(a.speedKt == b.speedKt, "\(name): a speed changed")
        }
        print(String(format: "SEAM %@ east/north: largest change %.9f m over %d waypoints", name, moved, now.count))
        #expect(moved <= 1e-9, "\(name): east or north moved by \(moved) m")
    }
}
