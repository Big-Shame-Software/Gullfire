import Foundation

/// The tallest roof within 60 m of each sample of one route, worked out the first time it is asked for and kept. Lowering reads
/// about fifty of these ahead of the aircraft on every control step, and they never change, so the app keeps one per route.
public final class RoofCache: @unchecked Sendable {
    private var values: [Double]
    private let lock = NSLock()

    /// `count` is the route's sample count.
    public init(count: Int) {
        values = Array(repeating: .nan, count: max(0, count))
    }

    func roof(index: Int, sample: Route.Sample, obstacles: ObstacleSource) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0, index < values.count else {
            return Autopilot.roofHeight(east: sample.east, north: sample.north, radius: 60, obstacles: obstacles)
        }
        if values[index].isNaN {
            values[index] = Autopilot.roofHeight(east: sample.east, north: sample.north, radius: 60, obstacles: obstacles)
        }
        return values[index]
    }
}

/// The cruise autopilot. A pure function of the aircraft's position and the route,
/// apart from the last route index, which only speeds up the search. It chases a point on the
/// route ahead of the aircraft, so it rejoins after manual flight without a special case.
public enum Autopilot {
    /// How far (in route samples, 10 m each) the nearest-point search may stray from where the aircraft was last step.
    public static let trackingWindow = 100
    /// Bank limit for cruise, radians (35°).
    public static let bankLimit = 35.0 * Double.pi / 180
    /// Lookahead: max(80 m, 2.5 s of travel).
    public static func lookahead(speed: Double) -> Double { max(80, 2.5 * speed) }

    /// The altitude to fly over a route sample, given the route's altitude there, the pilot's height offset (metres,
    /// + higher, − lower) and the tallest roof within 30 m of the sample.
    ///
    /// A street sample (the route is less than 30 m above the roof) takes the offset only upward, so the aircraft never
    /// drops below the route there. An open sample may go down with the offset, but never under the roof plus 30 m.
    public static func targetAltitude(routeAltitude: Double, offset: Double, roofAhead: Double) -> Double {
        // Raising never needs a roof check: the route plus the offset is always above the route.
        if offset >= 0 { return routeAltitude + offset }
        let street = routeAltitude - roofAhead < 30
        if street {
            return routeAltitude + max(offset, 0)
        }
        return max(routeAltitude + offset, roofAhead + 30)
    }

    /// The control for this step, and the route index it used.
    ///
    /// `heightOffset` raises (+) or lowers (−) the flight height over the route, subject to `targetAltitude`. Without
    /// `obstacles` every sample reads as a street, so the offset can only raise the aircraft.
    public static func control(for s: FlightState, route: Route, hint: Int?, tuning t: FlightTuning,
                               heightOffset: Double = 0, obstacles: ObstacleSource? = nil,
                               roofs: RoofCache? = nil) -> (control: ControlInput, index: Int) {
        guard route.count > 0 else { return (ControlInput(throttle: 0.5), 0) }
        // A narrow window (1 km either side of the last index): a route that passes over itself must not look nearer on its other leg.
        let here = route.nearestIndex(east: s.east, north: s.north, hint: hint, window: Autopilot.trackingWindow)
        let ahead = Int((lookahead(speed: s.speed) / route.spacing).rounded())
        let aim = route.samples[(here + ahead) % route.count]

        // Roll: heading error to the aim point, scaled so a 35° error is full roll.
        let desired = atan2(aim.east - s.east, aim.north - s.north)
        let headingError = wrapPi(desired - s.heading)
        let roll = clamp(headingError / bankLimit, -1, 1)

        // Pitch: altitude error at the target altitude over the aim point, full pitch at 60 m. With no obstacles the
        // roof is taken as the route's own altitude, which reads the sample as a street.
        // Lowering is limited by what the aircraft can still recover before it gets there. The aircraft can make up about
        // 0.06 m of height per metre flown (the climb it has left after following the route's own ramps, which are drawn at
        // 0.8 of its limit); the spare room at a point ahead is the route's height there minus the roofs minus 30 m. So the
        // lowering allowed now is the smallest of (room + 0.06 * distance) over the next kilometre of route. A street, or a
        // tower the route climbs over, takes the allowance to zero where it is, and the aircraft comes back up to the route's
        // height smoothly as it approaches. Over open ground the full setting is allowed. Raising needs no check.
        var effective = max(heightOffset, 0)
        if let obstacles, heightOffset < 0 {
            var allowance = -heightOffset
            let last = Int((1000 / route.spacing).rounded())
            var k = 0
            while k <= last {
                let index = (here + k) % route.count
                let sm = route.samples[index]
                let roof = roofs?.roof(index: index, sample: sm, obstacles: obstacles)
                    ?? roofHeight(east: sm.east, north: sm.north, radius: 60, obstacles: obstacles)
                let room = max(0, sm.altitude - roof - 30)
                allowance = min(allowance, room + 0.06 * Double(k) * route.spacing)
                if allowance <= 0 { break }
                k += 2
            }
            effective = -allowance
        }
        let targetAlt = aim.altitude + effective
        let altitudeError = targetAlt - s.altitude
        let pitch: Double
        if t.autopilotFeedforward > 0 {
            // Fly the profile where the aircraft is, climbing at the slope the route asks for between here and the aim, and
            // correct what is left over. A proportional command on the altitude at the aim alone needs a steady lag of 15 to 20 m
            // behind a ramp to produce the climb rate the ramp asks for (measured), which uses up the planned clearance.
            // The altitudes are read between the route's 10 m samples, at the aircraft's own distance along the route, not at the
            // nearest sample: at 31 m/s the nearest sample changes three times a second, and a step of up to 3 m in the reading
            // would step the pitch command with it.
            let here0 = route.samples[here]
            let alongHere = min(max(((s.east - here0.east) * here0.tangentEast + (s.north - here0.north) * here0.tangentNorth) / route.spacing, -1), 1)
            func altitudeAt(_ index: Double) -> Double {
                let n = route.count
                let lower = Int(index.rounded(.down))
                let fraction = index - Double(lower)
                let a = route.samples[((lower % n) + n) % n].altitude
                let b = route.samples[(((lower + 1) % n) + n) % n].altitude
                return a + (b - a) * fraction
            }
            let hereIndex = Double(here) + alongHere
            let hereAlt = altitudeAt(hereIndex) + effective
            let slopeAhead = max(1.0, Double(ahead) * t.autopilotFeedforwardWindow)
            let slope = (altitudeAt(hereIndex + slopeAhead) + effective - hereAlt) / (slopeAhead * route.spacing)
            let feedforward = t.autopilotFeedforward * atan(slope) / t.pitchLimit
            pitch = clamp(feedforward + (hereAlt - s.altitude) / 40, -1, 1)
        } else {
            pitch = clamp(altitudeError / 60, -1, 1)
        }

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
    /// Where to start looking for the elevated point to fly to: the route sample the search begins at, instead of the one
    /// nearest the aircraft. Entering a loop at a particular place (a picked street) sets it.
    public var startIndex: Int?
    /// The climb ratchet: the highest climb need so far. The climb ends when the aircraft reaches it, and it never falls, so a
    /// tower that drops out of the scan for a step (the held heading drifts) cannot end the climb early.
    public var climbNeedMax = -Double.infinity
    /// The steepest descent the transit can count on, as height lost per metre flown (0.30, about 17 degrees). The pitch limit
    /// is 20 degrees (tan 20 = 0.364), but the aircraft is not at the limit the whole way down, so the aim is picked where a
    /// glide at 0.30 reaches it. A glide steeper than the limit cannot be flown, and one at the limit overflows the aim.
    public static let glideGradient = 0.30

    public init(heading: Double, startIndex: Int? = nil) {
        self.heading = heading
        self.startIndex = startIndex
    }

    /// The largest distance the aircraft can reach from where it is while it turns through `headingError` radians (0 to pi)
    /// at the bank limit `maxBank`: the turn's chord, 2 R sin(headingError / 2) with R = speed^2 / (g tan(maxBank)), plus 50 m
    /// (20 m for the wing and disk, 30 m of slack). Never under 50 m.
    public static func localRadius(speed: Double, headingError: Double, maxBank: Double) -> Double {
        let g = FlightTuning().gravity
        let he = min(max(abs(headingError), 0), Double.pi)
        let r = speed * speed / (g * tan(maxBank))
        return max(50, 2 * r * sin(he / 2) + 50)
    }
}

extension Autopilot {
    /// A height boost for the minute after a hand-back onto a street loop ends, in metres: 60 m, settling to nothing over 60 s.
    /// The loop's joins over dense towers allow a few metres of error, and an aircraft that has just arrived is rarely exactly on
    /// the line. Raising is always safe (the 1.1 height rule), so it arrives high and settles onto the route's own height.
    public static func entryBoost(secondsSinceHandBack t: Double) -> Double {
        max(0, 60 * (1 - t / 60))
    }

    /// Whether an aim at `aimAltitude`, `distance` metres away, can be reached by a glide from `altitude` at `HandBack.glideGradient`
    /// and still be inside the join's altitude window (25 m above the aim, the window's upper edge). Pure.
    public static func glideFeasible(altitude: Double, aimAltitude: Double, distance: Double) -> Bool {
        distance >= (altitude - aimAltitude - 25) / HandBack.glideGradient
    }

    /// The first route sample among `count` candidates at `from + offset + i * stride` (wrapping) that is 30 m above the roofs
    /// around it and, when `glide` is set, glide-feasible from the aircraft (`glideFeasible`). nil when none is.
    static func elevatedAim(from k0: Int, offset: Int, stride: Int, count: Int, s: FlightState, route: Route,
                            obstacles: ObstacleSource, glide: Bool) -> Int? {
        guard route.count > 0 else { return nil }
        for i in 0..<count {
            let k = (k0 + offset + i * stride) % route.count
            let sm = route.samples[k]
            if glide {
                let dE = sm.east - s.east, dN = sm.north - s.north
                guard glideFeasible(altitude: s.altitude, aimAltitude: sm.altitude, distance: (dE * dE + dN * dN).squareRoot()) else { continue }
            }
            if sm.altitude - roofHeight(east: sm.east, north: sm.north, radius: 30, obstacles: obstacles) >= 30 { return k }
        }
        return nil
    }

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

    /// The roofs a turn through `headingError` can reach from here, plus 30 m: the tallest roof within `HandBack.localRadius`.
    static func localNeed(_ s: FlightState, headingError: Double, obstacles: ObstacleSource, tuning t: FlightTuning) -> Double {
        let radius = HandBack.localRadius(speed: s.speed, headingError: headingError, maxBank: t.rollLimit)
        return roofHeight(east: s.east, north: s.north, radius: radius, obstacles: obstacles) + 30
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
            // 800 m ahead, not 300: at the 20 degree pitch limit a climb over a 150 m tower needs about 400 m of run, and a
            // climb that starts when the tower comes within 300 m does not get over it.
            while d <= 800 {
                need = max(need, roofHeight(east: s.east + d * sin(hb.heading), north: s.north + d * cos(hb.heading), radius: 20, obstacles: obstacles))
                d += 20
            }
            need += 30
            // Local band (fix A): the roofs a turn of any direction from here can reach.
            need = max(need, localNeed(s, headingError: .pi, obstacles: obstacles, tuning: t))
            // Ratchet (fix B): judged against the highest need so far, which never falls.
            hb.climbNeedMax = max(hb.climbNeedMax, need)
            // (The aircraft cannot climb past the ceiling, so a need above it must not hold the climb forever.)
            if s.altitude >= min(hb.climbNeedMax, t.ceiling) - 1 {
                hb.phase = .transit
                // The first route sample from here on that is itself 30 m above the roofs around it.
                // (Glide-feasible from here first; if no sample on the route is, the first elevated one as before.)
                let k0 = hb.startIndex ?? here
                let chosen = elevatedAim(from: k0, offset: 0, stride: 1, count: route.count, s: s, route: route, obstacles: obstacles, glide: true)
                    ?? elevatedAim(from: k0, offset: 0, stride: 1, count: route.count, s: s, route: route, obstacles: obstacles, glide: false)
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
        guard var aimIndex = hb.aimIndex else { state = nil; return nil }
        var aim = route.samples[aimIndex]
        var dist = ((aim.east - s.east) * (aim.east - s.east) + (aim.north - s.north) * (aim.north - s.north)).squareRoot()
        // The hand-back ends on the route's own height or above it (down to 5 m under), never well under it: the route's
        // climbs over towers are drawn at the steepest the aircraft can follow, and an aircraft that joins 25 m under one
        // cannot catch up and grazes the tower. It also ends only pointing along the route (within 26 degrees): an aircraft
        // that arrives across the route swings about it at the join's tight turn radius and wanders off the line over the
        // towers. When it arrives across, the aim moves on along the route to the next elevated sample (30 m above the roofs).
        if dist < 120 && s.altitude >= aim.altitude - 5 && s.altitude - aim.altitude < 25 {
            let along = atan2(aim.tangentEast, aim.tangentNorth)
            if abs(wrapPi(along - s.heading)) < 0.45 {
                state = nil
                return nil
            }
            let found = elevatedAim(from: aimIndex, offset: 5, stride: 5, count: 60, s: s, route: route, obstacles: obstacles, glide: true)
            guard let next = found else { state = nil; return nil }
            hb.aimIndex = next
            aimIndex = next
            aim = route.samples[next]
            dist = ((aim.east - s.east) * (aim.east - s.east) + (aim.north - s.north) * (aim.north - s.north)).squareRoot()
        } else if dist < 120 && s.altitude - aim.altitude >= 25 {
            // Overflow: the aircraft has passed the aim above the window. Waiting for the window circles it over the aim (the
            // aim moves only inside the window), so the aim moves on now to the next elevated, glide-feasible sample: the
            // next 60 steps of 5 samples, then the whole route once. If none is found, the aim stays.
            let next = elevatedAim(from: aimIndex, offset: 5, stride: 5, count: 60, s: s, route: route, obstacles: obstacles, glide: true)
                ?? elevatedAim(from: aimIndex, offset: 1, stride: 1, count: route.count - 1, s: s, route: route, obstacles: obstacles, glide: true)
            if let n = next {
                hb.aimIndex = n
                aimIndex = n
                aim = route.samples[n]
                dist = ((aim.east - s.east) * (aim.east - s.east) + (aim.north - s.north) * (aim.north - s.north)).squareRoot()
            }
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
