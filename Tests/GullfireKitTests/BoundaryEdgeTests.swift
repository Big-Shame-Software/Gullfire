import Foundation
import Testing
@testable import GullfireKit

/// The boundary guard on a real package: an aircraft flown straight at each of the four edges, hands off, must turn back and
/// never leave the package's box. The guard takes its extent from the package manifest, so this holds for any package size.
/// Packages: Cities/Chicago, or the folders in GULLFIRE_ENGINE_DIRS (colon separated), as the route engine tests do.
@Suite("BoundaryEdge", .serialized, .enabled(if: EdgePackages.available))
struct BoundaryEdge {
    @Test(arguments: EdgePackages.dirs) func guardKeepsTheAircraftInsideAtEveryEdge(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let e = city.manifest.extentM
        let t = FlightTuning()
        let altitude = 600.0
        // (name, start east, start north, heading toward the edge in radians from north). Each starts 3 km inside the edge,
        // halfway along it, flying straight at it.
        let midE = (e.minEast + e.maxEast) / 2, midN = (e.minNorth + e.maxNorth) / 2
        let starts: [(String, Double, Double, Double)] = [
            ("east", e.maxEast - 3000, midN, .pi / 2),
            ("west", e.minEast + 3000, midN, -.pi / 2),
            ("north", midE, e.maxNorth - 3000, 0),
            ("south", midE, e.minNorth + 3000, .pi),
        ]
        for (name, east, north, heading) in starts {
            var sim = Simulation(start: FlightState(east: east, north: north, altitude: altitude, heading: heading, speed: 45), tuning: t)
            var outside = 0.0, nearestEdge = Double.infinity
            for _ in 0..<Int(400 / t.fixedStep) {
                sim.advance(by: t.fixedStep, obstacles: city, extent: e) { _, _ in ControlInput(pitch: 0, roll: 0, yaw: 0, throttle: 0.5) }
                let s = sim.current
                let inside = min(s.east - e.minEast, e.maxEast - s.east, s.north - e.minNorth, e.maxNorth - s.north)
                nearestEdge = min(nearestEdge, inside)
                if inside < 0 { outside += t.fixedStep }
            }
            print(String(format: "EDGE %@ %@ | closest to the edge %.0f m | outside %.1f s | nudges %d", dir.lastPathComponent, name, nearestEdge, outside, sim.nudges))
            #expect(outside == 0, "\(dir.lastPathComponent) \(name): \(outside) s outside the box")
        }
    }
}

enum EdgePackages {
    static let dirs: [URL] = EnginePackages.envDirs ?? [PackageTests.chicago]
    static var available: Bool { dirs.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) } }
}
