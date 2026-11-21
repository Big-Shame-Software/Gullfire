import Foundation
import Testing
@testable import GullfireKit

/// The autopilot's "where am I on the route" must not jump to another leg that passes overhead. Scenic's 450 m leg crosses 6 m
/// above its own 70 m leg; with the horizontal distance alone, an aircraft 20 m to one side of the low leg took the high leg as
/// the nearest part of the route and pitched hard up to reach it (a 21 m/s2 jolt, every lap).
@Suite("Route nearest point")
struct RouteNearestTests {
    /// A closed loop shaped like an 8: the leg A to B at 70 m and the leg D to E at 450 m cross over the origin.
    static func figureEight() -> Route {
        let w: [(Double, Double, Double)] = [(-400, -300, 70), (400, 300, 70), (600, 0, 260), (400, -300, 450), (-400, 300, 450), (-600, 0, 260)]
        return Route(file: RouteFile(name: "eight", closed: true, waypoints: w.map { Waypoint(east: $0.0, north: $0.1, alt: $0.2, speedKt: 80) }))
    }

    static func lowAndHighIndexAtTheCrossing(_ route: Route) -> (low: Int, high: Int) {
        let near = route.samples.indices.filter { hypot(route.samples[$0].east, route.samples[$0].north) < 15 }
        let low = near.filter { route.samples[$0].altitude < 150 }.min { hypot(route.samples[$0].east, route.samples[$0].north) < hypot(route.samples[$1].east, route.samples[$1].north) }!
        let high = near.filter { route.samples[$0].altitude > 350 }.min { hypot(route.samples[$0].east, route.samples[$0].north) < hypot(route.samples[$1].east, route.samples[$1].north) }!
        return (low, high)
    }

    @Test func anAircraftBesideTheLowLegStaysOnTheLowLegWhenAnotherLegPassesOverhead() {
        let route = Self.figureEight()
        let (low, high) = Self.lowAndHighIndexAtTheCrossing(route)
        let t = route.samples[low]
        // 12 m to the side of the low leg: the high leg crosses at an angle, so horizontally it is nearer.
        let p = SIMD2(t.east - t.tangentNorth * 12, t.north + t.tangentEast * 12)
        let wide = route.nearestIndex(east: p.x, north: p.y, hint: low)   // the old window of 300 samples
        #expect(abs(wide - high) < 40, "the old window should pick the leg overhead here (it picked \(wide); high leg at \(high))")
        // The legs are far apart along the route, so a narrow window cannot reach the other one.
        let alongRoute = min(abs(high - low), route.count - abs(high - low))
        let here = route.nearestIndex(east: p.x, north: p.y, hint: low, window: min(Autopilot.trackingWindow, alongRoute - 1))
        #expect(abs(here - low) < 30, "the narrow window picked \(here), the low leg is at \(low)")
        #expect(route.samples[here].altitude < 150)
    }

    @Test func onARealRouteAnAircraftTwentyMetresOffTheLineKeepsItsLeg() throws {
        let url = PackageTests.chicago.appendingPathComponent("routes/scenic.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let route = try Route.load(url)
        let s = route.samples[197]
        for offset in [0.0, 20, 40, 80] {
            let p = SIMD2(s.east - s.tangentNorth * offset, s.north + s.tangentEast * offset)
            let here = route.nearestIndex(east: p.x, north: p.y, hint: 196, window: Autopilot.trackingWindow)
            #expect(abs(here - 197) < 40, "\(offset) m off the line the search chose \(here)")
        }
    }

    @Test func theWindowIsWideEnoughForAnAircraftThatKeepsMoving() {
        // 45 m/s for one fixed step is a few centimetres of route: the window only has to follow a moving aircraft, not find one.
        #expect(Autopilot.trackingWindow >= 50)
    }
}
