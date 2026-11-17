import Foundation
import Testing
@testable import GullfireKit

/// Cruise tests on the real routes of every built city. A city whose package or routes are missing is
/// not listed, so a clean checkout skips them.
@Suite("Cruise routes", .enabled(if: PackageTests.built))
struct RouteFlightTests {
    struct Flown {
        var minClearance = Double.infinity
        var minAltitude = Double.infinity
        var maxBank = 0.0
        var outsideSeconds = 0.0
        var lapDistance = 0.0
        var nudges = 0
        var warnings = 0.0
    }

    static func route(_ name: String, in dir: URL) throws -> Route {
        try Route.load(dir.appendingPathComponent("routes/\(name).json"))
    }

    /// Flies `seconds` on autopilot from the route's first sample.
    static func flyAutopilot(_ route: Route, city: CityPackage, seconds: Double) -> Flown {
        let t = FlightTuning()
        let a = route.samples[0], b = route.samples[1]
        let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north),
                                speed: a.speed)
        var sim = Simulation(start: start, tuning: t)
        var hint: Int? = 0
        var flown = Flown()
        let extent = city.manifest.extentM
        var last = (e: start.east, n: start.north)
        for _ in 0..<Int(seconds / t.fixedStep) {
            sim.advance(by: t.fixedStep, obstacles: city, extent: extent) { s, _ in
                let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t)
                hint = r.index
                return r.control
            }
            let s = sim.current
            flown.minAltitude = min(flown.minAltitude, s.altitude)
            flown.minClearance = min(flown.minClearance, s.altitude - Double(city.obstacleHeight(east: s.east, north: s.north)))
            flown.maxBank = max(flown.maxBank, abs(s.bank) * 180 / .pi)
            if s.east < extent.minEast || s.east > extent.maxEast || s.north < extent.minNorth || s.north > extent.maxNorth {
                flown.outsideSeconds += t.fixedStep
            }
            flown.lapDistance += ((s.east - last.e) * (s.east - last.e) + (s.north - last.n) * (s.north - last.n)).squareRoot()
            last = (s.east, s.north)
            if sim.proximityWarning { flown.warnings += t.fixedStep }
        }
        flown.nudges = sim.nudges
        return flown
    }

    /// Diagnostic: where the collision nudges happen, and how far the aircraft is from the route there.
    static func nudgeReport(_ route: Route, city: CityPackage, seconds: Double) {
        let t = FlightTuning()
        let a = route.samples[0], b = route.samples[1]
        let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
        var sim = Simulation(start: start, tuning: t)
        var hint: Int? = 0
        var lastNudges = 0
        for k in 0..<Int(seconds / t.fixedStep) {
            sim.advance(by: t.fixedStep, obstacles: city, extent: city.manifest.extentM) { s, _ in
                let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t)
                hint = r.index
                return r.control
            }
            if sim.nudges > lastNudges {
                lastNudges = sim.nudges
                let s = sim.current
                let i = route.nearestIndex(east: s.east, north: s.north)
                let c = route.samples[i]
                let cross = ((s.east - c.east) * (s.east - c.east) + (s.north - c.north) * (s.north - c.north)).squareRoot()
                print(String(format: "NUDGE t=%.1f s at E %.0f N %.0f alt %.0f ground %.0f, %.1f m from centreline, route alt %.0f, bank %.1f deg, speed %.1f",
                             Double(k) * t.fixedStep, s.east, s.north, s.altitude, Double(city.obstacleHeight(east: s.east, north: s.north)), cross, c.altitude, s.bank * 180 / .pi, s.speed))
            }
        }
    }

    @Test(arguments: PackageTests.cities) func riverNudgeLocations(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        Self.nudgeReport(try Self.route("river", in: dir), city: city, seconds: 600)
    }

    @Test(arguments: PackageTests.cities) func autopilotOnTheRiverRouteFor600Seconds(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let f = Self.flyAutopilot(try Self.route("river", in: dir), city: city, seconds: 600)
        print(String(format: "ROUTE river: min alt %.1f m, min clearance %.1f m, max bank %.1f deg, outside %.1f s, distance %.0f m, nudges %d, avoidance %.1f s",
                     f.minAltitude, f.minClearance, f.maxBank, f.outsideSeconds, f.lapDistance, f.nudges, f.warnings))
        #expect(f.minAltitude >= FlightTuning().floor)
        #expect(f.outsideSeconds == 0)
        #expect(f.minClearance > 0)
        #expect(f.maxBank <= 46)
        #expect(f.nudges == 0, "River must fly with zero collision nudges, the same bar as Scenic (\(f.nudges))")
        #expect(f.lapDistance >= (try Self.route("river", in: dir)).length)
    }

    @Test(arguments: PackageTests.cities) func autopilotOnTheScenicRouteFor600Seconds(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let f = Self.flyAutopilot(try Self.route("scenic", in: dir), city: city, seconds: 600)
        print(String(format: "ROUTE scenic: min alt %.1f m, min clearance %.1f m, max bank %.1f deg, outside %.1f s, distance %.0f m, nudges %d, avoidance %.1f s",
                     f.minAltitude, f.minClearance, f.maxBank, f.outsideSeconds, f.lapDistance, f.nudges, f.warnings))
        #expect(f.minAltitude >= FlightTuning().floor)
        #expect(f.outsideSeconds == 0)
        #expect(f.minClearance > 0)
        #expect(f.maxBank <= 46)
        #expect(f.lapDistance >= (try Self.route("scenic", in: dir)).length)
    }

    /// A low river sample must not have a building taller than altitude − 15 m within 20 m.
    @Test(arguments: PackageTests.cities) func riverLowLegHasNoBuildingWithin20MetresAboveTheRule(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let river = try Self.route("river", in: dir)
        var bad = 0
        var worst = 0.0
        for s in river.samples where s.altitude < 100 {   // the low leg; the return leg is high
            var tallest = 0.0
            for dx in stride(from: -20.0, through: 20.0, by: 5.0) {
                for dy in stride(from: -20.0, through: 20.0, by: 5.0) where dx * dx + dy * dy <= 400 {
                    tallest = max(tallest, Double(city.obstacleHeight(east: s.east + dx, north: s.north + dy)))
                }
            }
            worst = max(worst, tallest - s.altitude)
            if tallest > s.altitude - 15 { bad += 1 }
        }
        print(String(format: "RIVER low leg: samples blocked %d, worst obstacle minus altitude %.1f m", bad, worst))
        #expect(bad == 0)
    }

    /// Across a hand-over, no step moves the aircraft more than speed × dt × 1.01, and the
    /// heading changes less than 1° per step.
    @Test(arguments: PackageTests.cities) func handOverIsContinuousBothWays(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let route = try Self.route("scenic", in: dir)
        let t = FlightTuning()
        let a = route.samples[0], b = route.samples[1]
        let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
        var sim = Simulation(start: start, tuning: t)
        var pilot = Pilot(mode: .auto)
        var hint: Int? = 0
        var maxJumpRatio = 0.0
        var maxHeadingStep = 0.0
        let manual = ControlInput(pitch: 0.3, roll: -0.6, yaw: 0, throttle: 0.5)
        func flyStep(_ sim: inout Simulation) {
            let before = sim.current
            sim.advance(by: t.fixedStep, obstacles: city, extent: city.manifest.extentM) { s, dt in
                let auto = Autopilot.control(for: s, route: route, hint: hint, tuning: t)
                hint = auto.index
                pilot.advance(dt: dt)
                return pilot.blended(manual: manual, auto: auto.control)
            }
            let after = sim.current
            let jump = ((after.east - before.east) * (after.east - before.east) + (after.north - before.north) * (after.north - before.north)).squareRoot()
            let limit = max(before.speed, after.speed) * t.fixedStep * 1.01
            if limit > 0 && jump / limit > maxJumpRatio {
                maxJumpRatio = jump / limit
                print(String(format: "JUMP step: jump %.2f m, limit %.3f m, speed before %.2f after %.2f, east %.1f->%.1f north %.1f->%.1f alt %.1f->%.1f hint %@",
                             jump, limit, before.speed, after.speed, before.east, after.east, before.north, after.north, before.altitude, after.altitude, String(describing: hint)))
            }
            maxHeadingStep = max(maxHeadingStep, abs(wrapPi(after.heading - before.heading)) * 180 / .pi)
        }
        for _ in 0..<(20 * 120) { flyStep(&sim) }
        pilot.toggle()   // to manual
        for _ in 0..<(20 * 120) { flyStep(&sim) }
        pilot.toggle()   // back to auto: blends over 3 s
        for _ in 0..<(20 * 120) { flyStep(&sim) }
        print(String(format: "HANDOVER: largest jump %.3f of the limit, largest heading change %.3f deg per step", maxJumpRatio, maxHeadingStep))
        #expect(maxJumpRatio <= 1.0)
        #expect(maxHeadingStep < 1.0)
    }
}
