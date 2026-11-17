import Foundation
import Testing
@testable import GullfireKit

/// The street-run routes, flown by the real autopilot.
/// A city with no street routes is skipped, so a clean checkout passes. The seeds are fixed: one seed, one route.
enum StreetRouteFiles {
    static var haveFootprints: Bool {
        FileManager.default.fileExists(atPath: chicago.appendingPathComponent("raw/building.geojsonl").path)
    }
    static let seeds = [1, 2, 3]
    /// `GULLFIRE_STREET_CITY=ChicagoCity` runs the same suite on another package that has its own street routes.
    static let chicago = PackageTests.root.appendingPathComponent("Cities/\(ProcessInfo.processInfo.environment["GULLFIRE_STREET_CITY"] ?? "Chicago")", isDirectory: true)
    static var available: Bool {
        seeds.allSatisfy { FileManager.default.fileExists(atPath: chicago.appendingPathComponent("routes/street-\($0).json").path) }
    }
    static func route(_ seed: Int) throws -> Route { try Route.load(chicago.appendingPathComponent("routes/street-\(seed).json")) }
}

@Suite("Street routes", .enabled(if: StreetRouteFiles.available))
struct StreetRouteTests {
    static let seeds = StreetRouteFiles.seeds
    static let chicago = StreetRouteFiles.chicago
    static func route(_ seed: Int) throws -> Route { try StreetRouteFiles.route(seed) }

    @Test(arguments: StreetRouteTests.seeds) func autopilotFliesTheRouteFor600Seconds(seed: Int) throws {
        let city = try CityPackage.open(directory: Self.chicago)
        let route = try Self.route(seed)
        let f = RouteFlightTests.flyAutopilot(route, city: city, seconds: 600)
        print(String(format: "STREET %d: min alt %.1f m, min clearance %.1f m, max bank %.1f deg, outside %.1f s, distance %.0f m, nudges %d, avoidance %.1f s",
                     seed, f.minAltitude, f.minClearance, f.maxBank, f.outsideSeconds, f.lapDistance, f.nudges, f.warnings))
        #expect(f.minAltitude >= FlightTuning().floor)
        #expect(f.outsideSeconds == 0)
        #expect(f.minClearance > 0)
        #expect(f.maxBank <= 46)
        #expect(f.nudges == 0, "a street route must fly with zero collision nudges (\(f.nudges))")
    }
}

/// The corridor proof, checked again in Swift on the written route, independently of the generator's own check
/// (Python and shapely). It builds the `Route` the app builds, samples it every 10 m, and tests the rule against
/// the obstacle grid and against the building footprints in `raw/building.geojsonl` (skipped when that is absent).
@Suite("Street route corridor", .enabled(if: StreetRouteFiles.available && StreetRouteFiles.haveFootprints))
struct StreetCorridorTests {
    struct Footprint { var ring: [SIMD2<Double>]; var height: Double; var minX: Double, maxX: Double, minY: Double, maxY: Double }

    static func footprints(frame: LocalFrame) throws -> [Footprint] {
        let data = try Data(contentsOf: StreetRouteFiles.chicago.appendingPathComponent("raw/building.geojsonl"))
        var out: [Footprint] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let geom = obj["geometry"] as? [String: Any], let type = geom["type"] as? String,
                  let props = obj["properties"] as? [String: Any] else { continue }
            var height = 6.0
            if let h = props["height"] as? Double { height = h } else if let f = props["num_floors"] as? Double { height = f * 3.4 }
            var rings: [[Any]] = []
            if type == "Polygon", let c = geom["coordinates"] as? [[Any]], let first = c.first { rings = [first] }
            if type == "MultiPolygon", let c = geom["coordinates"] as? [[[Any]]] { rings = c.compactMap { $0.first } }
            for r in rings {
                let ring: [SIMD2<Double>] = r.compactMap { pt in
                    guard let a = pt as? [Double], a.count >= 2 else { return nil }
                    return frame.metres(lon: a[0], lat: a[1])
                }
                guard ring.count >= 4 else { continue }
                out.append(Footprint(ring: ring, height: height, minX: ring.map(\.x).min()!, maxX: ring.map(\.x).max()!,
                                     minY: ring.map(\.y).min()!, maxY: ring.map(\.y).max()!))
            }
        }
        return out
    }

    /// Distance from a point to a polygon: 0 inside, else to the nearest edge.
    static func distance(_ p: SIMD2<Double>, to ring: [SIMD2<Double>]) -> Double {
        var inside = false
        var best = Double.infinity
        for i in 0..<(ring.count - 1) {
            let a = ring[i], b = ring[i + 1]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            let ab = b - a
            let len2 = ab.x * ab.x + ab.y * ab.y
            let u = len2 > 0 ? max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2)) : 0
            let c = a + ab * u
            best = min(best, ((p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y)).squareRoot())
        }
        return inside ? 0 : best
    }

    struct Counts { var street = 0, join = 0, badGrid = 0, badFootprint = 0, badRiver = 0, worst = -Double.infinity }

    struct Report: Decodable { struct S: Decodable { var line: [[Double]] }; var stretches: [S] }

    static func report(_ seed: Int) throws -> Report {
        try JSONDecoder().decode(Report.self, from: Data(contentsOf: StreetRouteFiles.chicago.appendingPathComponent("routes/street-\(seed).report.json")))
    }

    /// The rule on every sample of `route`: in a street (within 3 m of a stretch's centre line) no obstacle taller than
    /// altitude minus 10 m within 6 m, by the grid and by the footprints; elsewhere the River rule, altitude at least the
    /// tallest obstacle within 20 m plus 30 m (1.5 m of slack).
    static func evaluate(_ route: Route, report: Report, city: CityPackage, fps: [Footprint]) -> Counts {
        func nearLine(_ e: Double, _ n: Double) -> Bool {
            for s in report.stretches {
                for i in 0..<(s.line.count - 1) {
                    let a = s.line[i], b = s.line[i + 1]
                    let dx = b[0] - a[0], dy = b[1] - a[1]
                    let len2 = dx * dx + dy * dy
                    let u = len2 > 0 ? max(0, min(1, ((e - a[0]) * dx + (n - a[1]) * dy) / len2)) : 0
                    let cx = a[0] + dx * u, cy = a[1] + dy * u
                    if ((e - cx) * (e - cx) + (n - cy) * (n - cy)).squareRoot() <= 3 { return true }
                }
            }
            return false
        }
        var c = Counts()
        for s in route.samples {
            let limit = s.altitude - 10
            if nearLine(s.east, s.north) {
                c.street += 1
                var tall = 0.0
                for dx in stride(from: -6.0, through: 6.0, by: 2) {
                    for dy in stride(from: -6.0, through: 6.0, by: 2) where dx * dx + dy * dy <= 36 {
                        tall = max(tall, Double(city.obstacleHeight(east: s.east + dx, north: s.north + dy)))
                    }
                }
                if tall > limit { c.badGrid += 1 }
                let p = SIMD2(s.east, s.north)
                for f in fps where f.height > limit && p.x > f.minX - 6 && p.x < f.maxX + 6 && p.y > f.minY - 6 && p.y < f.maxY + 6 {
                    if distance(p, to: f.ring) <= 6 { c.badFootprint += 1; break }
                }
            } else {
                c.join += 1
                var tall = 0.0
                for dx in stride(from: -20.0, through: 20.0, by: 5) {
                    for dy in stride(from: -20.0, through: 20.0, by: 5) where dx * dx + dy * dy <= 400 {
                        tall = max(tall, Double(city.obstacleHeight(east: s.east + dx, north: s.north + dy)))
                    }
                }
                c.worst = max(c.worst, tall + 30 - s.altitude)
                if s.altitude < tall + 30 - 1.5 { c.badRiver += 1 }
            }
        }
        return c
    }

    @Test(arguments: StreetRouteFiles.seeds) func noBuildingWithinTheCorridorAndTheRiverRuleOnJoins(seed: Int) throws {
        let city = try CityPackage.open(directory: StreetRouteFiles.chicago)
        let fps = try Self.footprints(frame: LocalFrame(lon0: city.manifest.origin.lon, lat0: city.manifest.origin.lat))
        let c = Self.evaluate(try StreetRouteFiles.route(seed), report: try Self.report(seed), city: city, fps: fps)
        print("STREET corridor \(seed): \(c.street) street samples (grid \(c.badGrid) bad, footprints \(c.badFootprint) bad), \(c.join) join samples (River rule \(c.badRiver) bad, worst shortfall \(String(format: "%.1f", c.worst)) m)")
        #expect(c.street > 0 && c.join > 0)
        #expect(c.badGrid == 0)
        #expect(c.badFootprint == 0)
        #expect(c.badRiver == 0)
    }

    /// The check has to be able to fail: the same route with every waypoint moved 9 m sideways and 20 m lower on its joins
    /// must be caught (the first by the corridor rule, the second by the River rule).
    @Test func theCheckCatchesARouteThatIsMovedOrFlownTooLow() throws {
        let city = try CityPackage.open(directory: StreetRouteFiles.chicago)
        let fps = try Self.footprints(frame: LocalFrame(lon0: city.manifest.origin.lon, lat0: city.manifest.origin.lat))
        let seed = 1
        let report = try Self.report(seed)
        let data = try Data(contentsOf: StreetRouteFiles.chicago.appendingPathComponent("routes/street-\(seed).json"))
        let file = try JSONDecoder().decode(RouteFile.self, from: data)
        // The 9 m sub-case moves only the low-leg waypoints that have a building taller than their altitude minus 10 m
        // within 15 m: a shift only tests the check where a building can be reached. A seed on open ground has none,
        // and that sub-case is skipped rather than failed.
        func tallWithin15(_ e: Double, _ n: Double) -> Double {
            var tall = 0.0
            for dx in stride(from: -15.0, through: 15.0, by: 5) {
                for dy in stride(from: -15.0, through: 15.0, by: 5) where dx * dx + dy * dy <= 225 {
                    tall = max(tall, Double(city.obstacleHeight(east: e + dx, north: n + dy)))
                }
            }
            return tall
        }
        let near = file.waypoints.indices.filter { i in
            let w = file.waypoints[i]
            return w.alt <= 25 && tallWithin15(w.east, w.north) > w.alt - 10
        }
        if near.isEmpty {
            print("STREET check sensitivity \(seed): no building in reach (no low-leg waypoint within 15 m of a building taller than altitude minus 10 m); 9 m sub-case skipped")
        } else {
            // Each selected waypoint moves 9 m PERPENDICULAR to the route there (the direction from waypoint i-1 to i+1,
            // wrapping, since the route is closed), toward the side with the taller obstacle within 15 m. A shift along the
            // street would leave every sample inside its 3 m street band, so it could not test anything. A moved sample
            // leaves that band and is then judged by the River rule instead; either rule catching it counts.
            let n = file.waypoints.count
            var moved = file
            var shifts: [(i: Int, dx: Double, dy: Double)] = []
            for i in near {
                let a = file.waypoints[(i - 1 + n) % n], b = file.waypoints[(i + 1) % n]
                let dx = b.east - a.east, dy = b.north - a.north
                let len = (dx * dx + dy * dy).squareRoot()
                let nx = len > 0 ? -dy / len : 0, ny = len > 0 ? dx / len : 1      // unit normal to the route
                let w = file.waypoints[i]
                let side: Double = tallWithin15(w.east + 9 * nx, w.north + 9 * ny) >= tallWithin15(w.east - 9 * nx, w.north - 9 * ny) ? 1 : -1
                let sx = side * 9 * nx, sy = side * 9 * ny
                moved.waypoints[i].east = w.east + sx
                moved.waypoints[i].north = w.north + sy
                shifts.append((i, sx, sy))
            }
            let c1 = Self.evaluate(Route(file: moved), report: report, city: city, fps: fps)
            print("STREET check sensitivity \(seed): moved 9 m at \(near.count) low-leg waypoints: street \(c1.street) grid \(c1.badGrid) footprints \(c1.badFootprint) river \(c1.badRiver)")
            #expect(c1.badGrid + c1.badFootprint + c1.badRiver > 0)

            // The corridor sub-case: the same waypoint shifts, and every stretch line point moves by the offset of its nearest
            // shifted waypoint (within 30 m). The moved samples then stay in their stretch's 3 m band, so they are judged by the
            // grid and the footprints themselves, not by the River rule. Expect badGrid + badFootprint > 0.
            var sameBand = report
            for s in 0..<sameBand.stretches.count {
                for k in 0..<sameBand.stretches[s].line.count {
                    let p = sameBand.stretches[s].line[k]
                    var best: (d: Double, sx: Double, sy: Double)? = nil
                    for sh in shifts {
                        let w = file.waypoints[sh.i]
                        let d = ((p[0] - w.east) * (p[0] - w.east) + (p[1] - w.north) * (p[1] - w.north)).squareRoot()
                        if d <= 30, best == nil || d < best!.d { best = (d, sh.dx, sh.dy) }
                    }
                    if let b = best { sameBand.stretches[s].line[k] = [p[0] + b.sx, p[1] + b.sy] }
                }
            }
            let c3 = Self.evaluate(Route(file: moved), report: sameBand, city: city, fps: fps)
            print("STREET check sensitivity \(seed): moved 9 m with the stretch lines moved alike: street \(c3.street) grid \(c3.badGrid) footprints \(c3.badFootprint) river \(c3.badRiver)")
            #expect(c3.badGrid + c3.badFootprint > 0)
        }
        var low = file
        for i in low.waypoints.indices where low.waypoints[i].alt > 25 { low.waypoints[i].alt = max(15, low.waypoints[i].alt - 20) }
        let c2 = Self.evaluate(Route(file: low), report: report, city: city, fps: fps)
        print("STREET check sensitivity \(seed): 20 m lower: river \(c2.badRiver)")
        #expect(c2.badRiver > 0)
    }
}

/// Hand-back below the roofs: the aircraft is in a street at 15 m, off the route, and the
/// autopilot takes over. Starts are in the streets of the earlier measurements (Madison through the Loop, Taylor,
/// Roosevelt). Today's plain chase cut over 1,100 m of buildings and needed 349 collision nudges from the first.
@Suite("Street hand-back", .enabled(if: StreetRouteFiles.available && ProcessInfo.processInfo.environment["GULLFIRE_STREET_CITY"] == nil))   // its start points are on Chicago's Loop streets
struct StreetHandBackTests {
    struct Outcome { var nudges = 0, handBackSeconds = 0.0, minAboveRoof = Double.infinity, minDistToLowLeg = Double.infinity, maxAlt = 0.0 }

    static func fly(from start: FlightState, route: Route, city: CityPackage, seconds: Double, useHandBack: Bool) -> Outcome {
        let t = FlightTuning()
        var sim = Simulation(start: start, tuning: t)
        var hb: HandBack? = useHandBack ? Autopilot.startHandBack(start, obstacles: city) : nil
        var hint: Int? = nil
        var o = Outcome()
        let low = route.samples.filter { $0.altitude <= 20 }
        for _ in 0..<Int(seconds / t.fixedStep) {
            sim.advance(by: t.fixedStep, obstacles: city, extent: city.manifest.extentM) { s, _ in
                if hb != nil, let r = Autopilot.handBackControl(for: s, route: route, obstacles: city, state: &hb, tuning: t) {
                    hint = r.index
                    o.handBackSeconds += t.fixedStep
                    return r.control
                }
                let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t)
                hint = r.index
                return r.control
            }
            let s = sim.current
            o.minAboveRoof = min(o.minAboveRoof, s.altitude - Double(city.obstacleHeight(east: s.east, north: s.north)))
            o.maxAlt = max(o.maxAlt, s.altitude)
            if o.handBackSeconds > 0 && hb == nil {
                for q in low where abs(q.east - s.east) < 40 && abs(q.north - s.north) < 40 {
                    o.minDistToLowLeg = min(o.minDistToLowLeg, ((q.east - s.east) * (q.east - s.east) + (q.north - s.north) * (q.north - s.north)).squareRoot())
                }
            }
        }
        o.nudges = sim.nudges
        return o
    }

    /// (east, north, heading in degrees, knots): Madison west of the Loop, Taylor, Roosevelt, then Madison 250 m short of the Loop, heading into the towers (the plain chase needs a collision nudge there).
    static let starts: [(Double, Double, Double, Double)] = [(-2489, -388, 88.8, 45), (-2268, -1733, 88.6, 45), (-2037, -1999, 89.0, 45), (-1160, -359, 88.8, 45)]

    @Test(arguments: StreetHandBackTests.starts.indices) func handBackFromInsideAStreetClearsTheRoofs(index: Int) throws {
        let city = try CityPackage.open(directory: StreetRouteFiles.chicago)
        let route = try StreetRouteFiles.route(1)
        let s0 = Self.starts[index]
        let start = FlightState(east: s0.0, north: s0.1, altitude: 15, heading: s0.2 * .pi / 180, speed: s0.3 * 0.514444)
        let plain = Self.fly(from: start, route: route, city: city, seconds: 300, useHandBack: false)
        let rule = Self.fly(from: start, route: route, city: city, seconds: 700, useHandBack: true)
        print(String(format: "HANDBACK %d: plain chase nudges %d, min above roof %.1f m; with the rule nudges %d, min above roof %.1f m, hand-back %.1f s, peak %.0f m, closest to a low leg %.1f m",
                     index, plain.nudges, plain.minAboveRoof, rule.nudges, rule.minAboveRoof, rule.handBackSeconds, rule.maxAlt, rule.minDistToLowLeg))
        #expect(rule.nudges == 0)
        #expect(rule.minAboveRoof > 2)
        #expect(rule.handBackSeconds < 120, "the hand-back should be over in two minutes")
        #expect(rule.minDistToLowLeg < 3, "the aircraft should join a street run of the route")
    }

    /// Above the roofs nothing changes: the rule does not start, so Scenic and River flights are untouched.
    @Test func noHandBackAboveTheRoofs() throws {
        let city = try CityPackage.open(directory: StreetRouteFiles.chicago)
        let high = FlightState(east: 0, north: 0, altitude: 400, heading: 0, speed: 40)
        #expect(Autopilot.startHandBack(high, obstacles: city) == nil)
    }
}
