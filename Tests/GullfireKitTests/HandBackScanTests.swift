import Foundation
import Testing
@testable import GullfireKit

/// The hand-back's local band (the roofs a turn can reach from the aircraft), and the climb's ratchet and roof check.
/// Pure: synthetic towers and a straight route, no city package.

/// Towers as flat discs: the height at a point is the tallest disc that covers it.
struct TowerField: ObstacleSource {
    struct Tower: Sendable {
        let east, north, radius, height: Double
    }
    let towers: [Tower]

    func height(east: Double, north: Double) -> Float {
        var h: Float = 0
        for t in towers where (east - t.east) * (east - t.east) + (north - t.north) * (north - t.north) <= t.radius * t.radius {
            h = max(h, Float(t.height))
        }
        return h
    }
}

/// A fixed-seed generator, so the synthetic worlds are the same every run.
struct ScanRandom {
    var state: UInt64
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return lo + (hi - lo) * Double(state >> 11) / Double(1 << 53)
    }
}

@Suite("Hand-back local band and climb ratchet")
struct HandBackScanTests {
    static func straightRoute() -> Route {
        Route(file: RouteFile(name: "Straight", closed: false, waypoints: [
            // Route.build needs four waypoints and closes the loop; the return leg runs over the same line at the same altitude.
            Waypoint(east: 0, north: -1000, alt: 50, speedKt: 78),
            Waypoint(east: 0, north: -300, alt: 50, speedKt: 78),
            Waypoint(east: 0, north: 300, alt: 50, speedKt: 78),
            Waypoint(east: 0, north: 1000, alt: 50, speedKt: 78),
        ]))
    }

    /// The radius from the formula in the spec, with the bank limit the simulation uses.
    static func expectedRadius(speed: Double, he: Double) -> Double {
        let t = FlightTuning()
        let r = speed * speed / (t.gravity * tan(t.rollLimit))
        return max(50, 2 * r * sin(he / 2) + 50)
    }

    @Test func localRadiusIsFiftyMetresStraightAheadAndGrowsToTheTurnAtPi() {
        let t = FlightTuning()
        #expect(HandBack.localRadius(speed: 40, headingError: 0, maxBank: t.rollLimit) == 50)
        var previous = -Double.infinity
        for k in 0...36 {
            let he = Double(k) * Double.pi / 36
            let v = HandBack.localRadius(speed: 40, headingError: he, maxBank: t.rollLimit)
            #expect(v >= previous, "the band must not shrink as the turn grows (\(k) of 36)")
            previous = v
        }
        let r = 40.0 * 40.0 / (t.gravity * tan(t.rollLimit))
        #expect(abs(HandBack.localRadius(speed: 40, headingError: .pi, maxBank: t.rollLimit) - (2 * r + 50)) < 1e-9)
        #expect(abs(HandBack.localRadius(speed: 40, headingError: .pi, maxBank: t.rollLimit) - 376.2) < 0.5)
    }

    @Test func localRadiusUsesTheRealBankLimitNotTheAutopilotsCommandScale() {
        // The simulation banks to FlightTuning.rollLimit (45 degrees); the autopilot's Autopilot.bankLimit (35) is a command scale.
        let t = FlightTuning()
        #expect(abs(t.rollLimit - 45 * Double.pi / 180) < 1e-12)
        for he in [0.5, 1.0, 2.0, Double.pi] {
            let real = HandBack.localRadius(speed: 40, headingError: he, maxBank: t.rollLimit)
            let at35 = HandBack.localRadius(speed: 40, headingError: he, maxBank: Autopilot.bankLimit)
            #expect(abs(real - Self.expectedRadius(speed: 40, he: he)) < 1e-9)
            #expect(real < at35, "a steeper turn at 45 degrees has a smaller radius than at 35")
        }
    }

    @Test func localRadiusFloorsAtFiftyMetres() {
        let t = FlightTuning()
        #expect(HandBack.localRadius(speed: 0, headingError: .pi, maxBank: t.rollLimit) == 50)
        #expect(HandBack.localRadius(speed: 5, headingError: 0.5, maxBank: t.rollLimit) >= 50)
        #expect(HandBack.localRadius(speed: 5, headingError: 0, maxBank: t.rollLimit) == 50)
    }

    /// Fix B: over a whole climb with towers scattered about, the ratchet never falls, and the climb ends only once the
    /// aircraft has reached it.
    @Test func theClimbRatchetNeverFalls() {
        var rng = ScanRandom(state: 5)
        var towers: [TowerField.Tower] = []
        for _ in 0..<60 {
            towers.append(.init(east: rng.uniform(-600, 600), north: rng.uniform(-600, 600), radius: rng.uniform(5, 25), height: rng.uniform(40, 300)))
        }
        let world = TowerField(towers: towers)
        let route = Self.straightRoute()
        let t = FlightTuning()
        var s = FlightState(east: 0, north: 0, altitude: 60, heading: 0.3, speed: 40)
        var hb: HandBack? = HandBack(heading: s.heading)
        var last = -Double.infinity
        var climbSteps = 0
        for _ in 0..<12000 {
            let phaseBefore = hb?.phase
            let needBefore = hb?.climbNeedMax ?? -.infinity
            guard let r = Autopilot.handBackControl(for: s, route: route, obstacles: world, state: &hb, tuning: t) else { break }
            if let st = hb {
                #expect(st.climbNeedMax >= needBefore, "the ratchet fell from \(needBefore) to \(st.climbNeedMax)")
                last = max(last, st.climbNeedMax)
                if phaseBefore == .climb { climbSteps += 1 }
                if st.phase == .transit, phaseBefore == .climb {
                    #expect(s.altitude >= needBefore - 1 || st.climbNeedMax >= needBefore, "the climb ended below its ratchet")
                }
            }
            s = step(s, r.control, dt: t.fixedStep, tuning: t)
        }
        #expect(climbSteps > 0, "the synthetic climb must run at least one step")
    }

    /// The ratchet holds the climb when the current need is low: an aircraft below an earlier, higher need keeps climbing.
    @Test func aRaisedRatchetKeepsTheClimbGoingWithNoTowers() {
        let route = Self.straightRoute()
        #expect(route.count > 0)
        let t = FlightTuning()
        let s = FlightState(east: 0, north: 0, altitude: 228, heading: 0.785, speed: 40)
        var hb: HandBack? = HandBack(heading: s.heading)
        hb?.climbNeedMax = 269
        let r = Autopilot.handBackControl(for: s, route: route, obstacles: TowerField(towers: []), state: &hb, tuning: t)
        #expect(r != nil)
        #expect(hb?.phase == .climb, "with the ratchet at 269 m and the aircraft at 228 m, the climb must go on")
        #expect(abs((r?.control.pitch ?? 0) - 0.9) < 1e-12)
    }

    /// Fix A in the climb: a 239 m tower 8 m ahead is the 609 case (the aircraft at 228 m). The local band (a turn of any
    /// direction) sees it, so the climb does not end below 269 m.
    @Test func theClimbDoesNotEndBelowAnAdjacentRoof() {
        let route = Self.straightRoute()
        let t = FlightTuning()
        let world = TowerField(towers: [.init(east: 8 * sin(0.785), north: 8 * cos(0.785), radius: 3, height: 239)])
        let s = FlightState(east: 0, north: 0, altitude: 228, heading: 0.785, speed: 40)
        var hb: HandBack? = HandBack(heading: s.heading)
        _ = Autopilot.handBackControl(for: s, route: route, obstacles: world, state: &hb, tuning: t)
        #expect(hb?.phase == .climb)
        #expect((hb?.climbNeedMax ?? 0) >= 269 - 1e-9)
        // With the same aircraft and no tower, the climb is over at once (its roofs are 30 m, and the ceiling is the route's).
        var none: HandBack? = HandBack(heading: s.heading)
        _ = Autopilot.handBackControl(for: s, route: route, obstacles: TowerField(towers: []), state: &none, tuning: t)
        #expect(none?.phase == .transit)
    }
}

/// The descent glide and the transit's overflow re-aim. Pure: a flat world (no towers) and the straight route.
@Suite("Hand-back glide and overflow re-aim")
struct HandBackGlideTests {
    @Test func glideGradientIsUnderThePitchLimit() {
        #expect(HandBack.glideGradient == 0.30)
        #expect(HandBack.glideGradient < tan(FlightTuning().pitchLimit), "the glide must be flyable at the 20 degree limit")
    }

    /// The glide: from 100 m to an aim at 50 m, the window's top is 75 m (aim + 25), so 25 m must be lost: 83.33 m at 0.30.
    @Test func glideFeasibleBoundary() {
        let edge = (100.0 - 50.0 - 25.0) / HandBack.glideGradient
        #expect(abs(edge - 83.3333) < 1e-3)
        #expect(Autopilot.glideFeasible(altitude: 100, aimAltitude: 50, distance: edge))
        #expect(Autopilot.glideFeasible(altitude: 100, aimAltitude: 50, distance: edge + 0.01))
        #expect(!Autopilot.glideFeasible(altitude: 100, aimAltitude: 50, distance: edge - 0.01))
        #expect(!Autopilot.glideFeasible(altitude: 100, aimAltitude: 50, distance: 0))
    }

    /// Already in the window (or below it): any distance is feasible, including zero.
    @Test func glideFeasibleWhenInsideTheWindowAtAnyDistance() {
        #expect(Autopilot.glideFeasible(altitude: 75, aimAltitude: 50, distance: 0))
        #expect(Autopilot.glideFeasible(altitude: 40, aimAltitude: 50, distance: 0))
        #expect(Autopilot.glideFeasible(altitude: 480, aimAltitude: 480, distance: 0))
        // 480 m down to a 33 m aim: 422 m to lose, so 1,407 m of run at 0.30.
        #expect(!Autopilot.glideFeasible(altitude: 480, aimAltitude: 33, distance: 1400))
        #expect(Autopilot.glideFeasible(altitude: 480, aimAltitude: 33, distance: 1408))
    }

    /// An aircraft 120 m high, 100 m before an aim at 50 m, inside the 120 m cut-off but above the window (75 m): it must move
    /// the aim on to a farther, glide-feasible sample rather than circle the aim. The end test is not met.
    @Test func overflowAboveTheWindowMovesTheAimOn() {
        let route = HandBackScanTests.straightRoute()
        let t = FlightTuning()
        let here = FlightState(east: 0, north: 0, altitude: 120, heading: 0, speed: 40)
        let aimIdx = route.nearestIndex(east: 0, north: 100)
        var hb: HandBack? = HandBack(heading: 0)
        hb?.phase = .transit
        hb?.aimIndex = aimIdx
        let r = Autopilot.handBackControl(for: here, route: route, obstacles: TowerField(towers: []), state: &hb, tuning: t)
        #expect(r != nil, "above the window the hand-back must go on, not end")
        guard let moved = hb?.aimIndex else { Issue.record("the hand-back ended instead of moving the aim"); return }
        #expect(moved != aimIdx, "the aim must move on")
        #expect(route.samples[moved].north > route.samples[aimIdx].north, "the new aim must be farther along the route")
        let a = route.samples[moved]
        let dist = (a.east * a.east + (a.north - here.north) * (a.north - here.north)).squareRoot()
        #expect(Autopilot.glideFeasible(altitude: here.altitude, aimAltitude: a.altitude, distance: dist), "the new aim must be glide-feasible")
        #expect(r?.index == moved)
    }

    /// Inside the window, pointing along the route, within 120 m: the hand-back ends at once, as before.
    @Test func aTransitInTheWindowAlongTheRouteStillEndsAtOnce() {
        let route = HandBackScanTests.straightRoute()
        let t = FlightTuning()
        let here = FlightState(east: 0, north: 0, altitude: 55, heading: 0, speed: 40)
        var hb: HandBack? = HandBack(heading: 0)
        hb?.phase = .transit
        hb?.aimIndex = route.nearestIndex(east: 0, north: 100)
        let r = Autopilot.handBackControl(for: here, route: route, obstacles: TowerField(towers: []), state: &hb, tuning: t)
        #expect(r == nil)
        #expect(hb == nil)
    }
}
