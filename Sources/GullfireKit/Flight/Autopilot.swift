import Foundation

/// The cruise autopilot. A pure function of the aircraft's position and the route,
/// apart from the last route index, which only speeds up the search. It chases a point on the
/// route ahead of the aircraft, so it rejoins after manual flight without a special case.
public enum Autopilot {
    /// Bank limit for cruise, radians (35°).
    public static let bankLimit = 35.0 * Double.pi / 180
    /// Lookahead: max(80 m, 2.5 s of travel).
    public static func lookahead(speed: Double) -> Double { max(80, 2.5 * speed) }

    /// The control for this step, and the route index it used.
    public static func control(for s: FlightState, route: Route, hint: Int?, tuning t: FlightTuning) -> (control: ControlInput, index: Int) {
        guard route.count > 0 else { return (ControlInput(throttle: 0.5), 0) }
        let here = route.nearestIndex(east: s.east, north: s.north, hint: hint)
        let ahead = Int((lookahead(speed: s.speed) / route.spacing).rounded())
        let aim = route.samples[(here + ahead) % route.count]

        // Roll: heading error to the aim point, scaled so a 35° error is full roll.
        let desired = atan2(aim.east - s.east, aim.north - s.north)
        let headingError = wrapPi(desired - s.heading)
        let roll = clamp(headingError / bankLimit, -1, 1)

        // Pitch: altitude error at the aim point, full pitch at 60 m.
        let altitudeError = aim.altitude - s.altitude
        let pitch = clamp(altitudeError / 60, -1, 1)

        // Speed: the waypoint speed, capped by the tightest curve in the next 300 m (8.4).
        var tightest = route.samples[here].radius
        for k in 0...Int(300 / route.spacing) {
            tightest = min(tightest, route.samples[(here + k) % route.count].radius)
        }
        let curveCap = (t.gravity * tightest * tan(30 * Double.pi / 180)).squareRoot()
        let target = min(aim.speed, curveCap)
        let throttle = clamp((target - t.speedMin) / t.speedRange, 0, 1)

        return (ControlInput(pitch: pitch, roll: roll, yaw: 0, throttle: throttle), here)
    }
}

/// Hand-back below the roofs. When manual flight ends with the aircraft in a street,
/// chasing the nearest route point cuts across blocks (measured: over a kilometre of buildings and 349 collision nudges
/// from a Loop street). So the autopilot first climbs out, holding the heading and wings level, to the roofs plus 30 m
/// (the tallest obstacle within 30 m of the aircraft and along the next 300 m of its heading), then flies over the roofs
/// to the next point of the route that is itself above the roofs (the climb out of a street run, or a join), and from
/// there follows the route as usual, which descends onto the next street run.
public struct HandBack: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case climb, transit }
    public var phase = Phase.climb
    /// The heading held during the climb.
    public var heading: Double
    /// The route sample the transit flies to, once it is chosen.
    public var aimIndex: Int?
    public init(heading: Double) { self.heading = heading }
}

extension Autopilot {
    /// Seconds-free check used at the hand-back: is anything within 30 m of the aircraft taller than altitude minus 10 m?
    public static func belowRoofs(_ s: FlightState, obstacles: ObstacleSource) -> Bool {
        roofHeight(east: s.east, north: s.north, radius: 30, obstacles: obstacles) > s.altitude - 10
    }

    static func roofHeight(east: Double, north: Double, radius: Double, obstacles: ObstacleSource) -> Double {
        var tallest = 0.0
        var dx = -radius
        while dx <= radius {
            var dy = -radius
            while dy <= radius {
                if dx * dx + dy * dy <= radius * radius {
                    tallest = max(tallest, Double(obstacles.height(east: east + dx, north: north + dy)))
                }
                dy += 5
            }
            dx += 5
        }
        return tallest
    }

    /// A hand-back to run, or nil when the aircraft is already above the roofs (then the usual chase applies unchanged).
    public static func startHandBack(_ s: FlightState, obstacles: ObstacleSource) -> HandBack? {
        belowRoofs(s, obstacles: obstacles) ? HandBack(heading: s.heading) : nil
    }

    /// The control for one step of a hand-back, or nil when it is over (`state` is then nil and the caller follows the
    /// route from `index`). The caller replaces the pilot's input while a hand-back runs.
    public static func handBackControl(for s: FlightState, route: Route, obstacles: ObstacleSource, state: inout HandBack?,
                                       tuning t: FlightTuning) -> (control: ControlInput, index: Int)? {
        guard var hb = state, route.count > 0 else { state = nil; return nil }
        let here = route.nearestIndex(east: s.east, north: s.north)

        switch hb.phase {
        case .climb:
            // The roofs to clear: around the aircraft, and ahead along the held heading.
            var need = roofHeight(east: s.east, north: s.north, radius: 30, obstacles: obstacles)
            var d = 20.0
            while d <= 300 {
                need = max(need, roofHeight(east: s.east + d * sin(hb.heading), north: s.north + d * cos(hb.heading), radius: 20, obstacles: obstacles))
                d += 20
            }
            need += 30
            if s.altitude >= need - 1 {
                hb.phase = .transit
                // The first route sample from here on that is itself 30 m above the roofs around it.
                var k = here
                var chosen: Int?
                for _ in 0..<route.count {
                    let sm = route.samples[k]
                    if sm.altitude - roofHeight(east: sm.east, north: sm.north, radius: 30, obstacles: obstacles) >= 30 { chosen = k; break }
                    k = (k + 1) % route.count
                }
                guard let aim = chosen else { state = nil; return nil }
                hb.aimIndex = aim
                break
            }
            // Hold the heading, but let it drift a few degrees toward the freer side: a street is never perfectly straight,
            // and a held heading walks into the wall. Score each heading by how far it runs before something at or above
            // the aircraft's altitude minus 5 m comes within 5 m of the line.
            var best = (score: -Double.infinity, heading: hb.heading)
            for offDeg in stride(from: -12.0, through: 12.0, by: 4.0) {
                let h = hb.heading + offDeg * .pi / 180
                var free = 150.0
                var d = 10.0
                while d <= 150 {
                    var blocked = false
                    for lateral in [-5.0, 0.0, 5.0] {
                        let e = s.east + d * sin(h) + lateral * cos(h), n = s.north + d * cos(h) - lateral * sin(h)
                        if Double(obstacles.height(east: e, north: n)) > s.altitude - 5 { blocked = true; break }
                    }
                    if blocked { free = d; break }
                    d += 10
                }
                let score = free - 0.5 * abs(offDeg)
                if score > best.score { best = (score, h) }
            }
            hb.heading = best.heading
            let roll = clamp(wrapPi(hb.heading - s.heading) / bankLimit, -1, 1)
            let throttle = clamp((s.speed - t.speedMin) / t.speedRange, 0, 1)
            state = hb
            return (ControlInput(pitch: 0.9, roll: roll, yaw: 0, throttle: throttle), here)
        case .transit:
            break
        }

        // Transit: over the roofs to the aim sample, then back to the usual chase.
        guard let aimIndex = hb.aimIndex else { state = nil; return nil }
        let aim = route.samples[aimIndex]
        let dist = ((aim.east - s.east) * (aim.east - s.east) + (aim.north - s.north) * (aim.north - s.north)).squareRoot()
        if dist < 120 && abs(aim.altitude - s.altitude) < 25 {
            state = nil
            return nil
        }
        // Altitude: the roofs along the straight line to the aim, plus 30 m, never below the route's own altitude there.
        var need = aim.altitude
        var d = 0.0
        let heading = atan2(aim.east - s.east, aim.north - s.north)
        while d < dist {
            need = max(need, roofHeight(east: s.east + d * sin(heading), north: s.north + d * cos(heading), radius: 20, obstacles: obstacles) + 30)
            d += 20
        }
        let roll = clamp(wrapPi(heading - s.heading) / bankLimit, -1, 1)
        let pitch = clamp((min(need, t.ceiling) - s.altitude) / 60, -1, 1)
        let throttle = clamp((aim.speed - t.speedMin) / t.speedRange, 0, 1)
        state = hb
        return (ControlInput(pitch: pitch, roll: roll, yaw: 0, throttle: throttle), aimIndex)
    }
}

/// Who is flying, and the hand-over between them.
public struct Pilot: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case manual, auto }

    public private(set) var mode: Mode
    /// 0 is fully manual, 1 fully automatic. Rises over `blendTime` after manual → auto.
    public private(set) var blend: Double
    public var blendTime = 3.0

    public init(mode: Mode) {
        self.mode = mode
        blend = mode == .auto ? 1 : 0
    }

    /// Space: manual → auto blends over 3 s; auto → manual is immediate.
    public mutating func toggle() {
        switch mode {
        case .auto:
            mode = .manual
            blend = 0
        case .manual:
            mode = .auto
            blend = 0
        }
    }

    /// Advances the blend by `dt` seconds.
    public mutating func advance(dt: Double) {
        if mode == .auto && blend < 1 {
            blend = min(1, blend + dt / blendTime)
        }
    }

    /// The control this step: manual, the autopilot, or a blend of the two.
    public func blended(manual: ControlInput, auto: ControlInput) -> ControlInput {
        switch mode {
        case .manual where blend >= 1:
            return manual
        case .manual:
            return manual
        case .auto:
            let t = blend, m = 1 - t
            return ControlInput(pitch: manual.pitch * m + auto.pitch * t,
                                roll: manual.roll * m + auto.roll * t,
                                yaw: manual.yaw * m + auto.yaw * t,
                                throttle: manual.throttle * m + auto.throttle * t)
        }
    }
}
