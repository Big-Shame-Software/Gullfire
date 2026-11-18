import Foundation
import Testing
@testable import GullfireKit

/// A roof height that is the same everywhere, for control tests without a city.
struct FlatRoofs: ObstacleSource {
    var height: Float
    func height(east: Double, north: Double) -> Float { height }
}

/// Flight height: `Autopilot.targetAltitude` and the height offset in `Autopilot.control`.
@Suite("Flight height")
struct FlightHeightTests {
    /// A 400 m square at a constant 100 m, flown at 60 knots.
    static func flatSquare() -> Route {
        Route(file: RouteFile(name: "flat square", closed: true, waypoints: [
            Waypoint(east: 0, north: 0, alt: 100, speedKt: 60),
            Waypoint(east: 400, north: 0, alt: 100, speedKt: 60),
            Waypoint(east: 400, north: 400, alt: 100, speedKt: 60),
            Waypoint(east: 0, north: 400, alt: 100, speedKt: 60),
        ]))
    }

    /// A state on the route at its first sample, level, at the route's altitude.
    static func onRoute(_ route: Route) -> FlightState {
        let a = route.samples[0], b = route.samples[1]
        return FlightState(east: a.east, north: a.north, altitude: a.altitude,
                           heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
    }

    @Test func routeIsFlatAtOneHundredMetres() {
        let route = Self.flatSquare()
        #expect(route.samples.allSatisfy { abs($0.altitude - 100) < 1e-6 })
    }

    @Test func raiseOnAStreetSampleGivesRoutePlusThirty() {
        // The roof is 10 m below the route's altitude: the route is 10 m above it, so it is a street.
        let target = Autopilot.targetAltitude(routeAltitude: 100, offset: 30, roofAhead: 90)
        #expect(abs(target - 130) < 1e-9)
    }

    @Test func lowerOnAStreetSampleReturnsTheRouteAltitude() {
        let target = Autopilot.targetAltitude(routeAltitude: 100, offset: -20, roofAhead: 90)
        #expect(target == 100)
    }

    @Test func lowerOnAnOpenSampleGoesDownButNeverUnderTheRoofPlusThirty() {
        // The roof is 50 m below the route: 50 m is at least 30 m, so the sample is open.
        let target = Autopilot.targetAltitude(routeAltitude: 200, offset: -100, roofAhead: 150)
        #expect(target < 200)
        #expect(abs(target - 180) < 1e-9)   // roof 150 + 30, not the route minus 100 (100)
    }

    @Test func lowerOnAnOpenSampleAboveTheFloorGoesDown() {
        let target = Autopilot.targetAltitude(routeAltitude: 200, offset: -40, roofAhead: 50)
        #expect(abs(target - 160) < 1e-9)
    }

    @Test func controlRaisesOnAStreetSample() {
        // Roofs at 80 m under a route at 100 m: a street. +30 asks for 130 m, so pitch is 30 / 60.
        let route = Self.flatSquare()
        let s = Self.onRoute(route)
        let r = Autopilot.control(for: s, route: route, hint: 0, tuning: FlightTuning(),
                                  heightOffset: 30, obstacles: FlatRoofs(height: 80))
        #expect(abs(r.control.pitch - 0.5) < 1e-9)
    }

    @Test func controlLowersOnAnOpenSampleButNotUnderTheRoofPlusThirty() {
        // Roofs at 0 m: the route at 100 m is open. −40 asks for 60 m, above the 30 m floor, so pitch is −40 / 60.
        let route = Self.flatSquare()
        let s = Self.onRoute(route)
        let r = Autopilot.control(for: s, route: route, hint: 0, tuning: FlightTuning(),
                                  heightOffset: -40, obstacles: FlatRoofs(height: 0))
        #expect(abs(r.control.pitch - (-40.0 / 60)) < 1e-9)

        // −100 asks for 0 m, under the 30 m floor, so the target is 30 m: the error is −70 m, past the 60 m full pitch.
        // Pitch clamps to −1.
        let low = Autopilot.control(for: s, route: route, hint: 0, tuning: FlightTuning(),
                                    heightOffset: -100, obstacles: FlatRoofs(height: 0))
        #expect(low.control.pitch == -1)
    }

    @Test func controlLowerWithoutObstaclesDoesNothingBelowTheRoute() {
        // With no obstacles every sample is a street, so a negative offset cannot take the aircraft under the route.
        let route = Self.flatSquare()
        let s = Self.onRoute(route)
        let r = Autopilot.control(for: s, route: route, hint: 0, tuning: FlightTuning(), heightOffset: -50)
        #expect(r.control.pitch == 0)
    }

    /// Offset 0 with no obstacles is the same control as before the height offset existed: the pitch is the
    /// altitude error at the aim sample, and the defaults equal the explicit zero offset.
    @Test(arguments: PackageTests.cities) func offsetZeroGivesTheSameControlOnTheRiverRoute(dir: URL) throws {
        let route = try RouteFlightTests.route("river", in: dir)
        let t = FlightTuning()
        for i in stride(from: 0, to: route.count, by: 37) {
            let sample = route.samples[i]
            let s = FlightState(east: sample.east, north: sample.north, altitude: sample.altitude - 12,
                                heading: atan2(sample.tangentEast, sample.tangentNorth), speed: sample.speed)
            let implicit = Autopilot.control(for: s, route: route, hint: i, tuning: t)
            let explicit = Autopilot.control(for: s, route: route, hint: i, tuning: t, heightOffset: 0, obstacles: nil)
            #expect(implicit.control == explicit.control)
            #expect(implicit.index == explicit.index)

            // The pitch is the altitude error at the aim sample, as before the offset existed.
            let ahead = Int((Autopilot.lookahead(speed: s.speed) / route.spacing).rounded())
            let aim = route.samples[(implicit.index + ahead) % route.count]
            let expectedPitch = min(1, max(-1, (aim.altitude - s.altitude) / 60))
            #expect(abs(implicit.control.pitch - expectedPitch) < 1e-9)
        }
    }
}

/// Run-level checks of flight height on the real package: every street run flown with the lowest offset never goes
/// below the same run flown at its own height, and every route stays clear with the offsets the keys allow.
@Suite("Flight height on real routes", .enabled(if: StreetRouteFiles.available))
struct FlightHeightRouteTests {
    @Test(arguments: StreetRouteFiles.seeds) func streetRunNeverGoesBelowItsOwnHeightWhenLowered(seed: Int) throws {
        let city = try CityPackage.open(directory: StreetRouteFiles.chicago)
        let route = try StreetRouteFiles.route(seed)
        let base = RouteFlightTests.flyAutopilot(route, city: city, seconds: 600)
        let low = RouteFlightTests.flyAutopilot(route, city: city, seconds: 600, heightOffset: -60, withObstacles: true)
        print(String(format: "HEIGHT street-%d: base min alt %.1f, lowered min alt %.1f, lowered clearance %.1f, nudges %d",
                     seed, base.minAltitude, low.minAltitude, low.minClearance, low.nudges))
        #expect(low.minAltitude >= base.minAltitude - 1.0)
        #expect(low.minClearance > 0)
        #expect(low.nudges == 0)
        #expect(low.outsideSeconds == 0)
    }

    @Test(arguments: [-60.0, 30.0, 120.0], ["scenic", "river"]) func openRouteStaysClear(offset: Double, name: String) throws {
        let city = try CityPackage.open(directory: StreetRouteFiles.chicago)
        let route = try Route.load(StreetRouteFiles.chicago.appendingPathComponent("routes/\(name).json"))
        let f = RouteFlightTests.flyAutopilot(route, city: city, seconds: 600, heightOffset: offset, withObstacles: true)
        print(String(format: "HEIGHT %@ %+.0f: min alt %.1f, clearance %.1f, nudges %d, outside %.1f", name, offset, f.minAltitude, f.minClearance, f.nudges, f.outsideSeconds))
        #expect(f.minClearance > 0)
        #expect(f.nudges == 0)
        #expect(f.outsideSeconds == 0)
    }
}
