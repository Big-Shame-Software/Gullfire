import Foundation

/// The planner-side fix for avoidance lurches (Spikes/LEVELING_PLAN.md, sections 7 and 8, Phase 2b). The avoidance layer
/// looks 1, 2 and 3 s ahead at the altitude the aircraft has now, so a route that climbs over a roof ahead is taken for a
/// collision course at every ramp. `raise` plans the altitude so that, at every sample, the aircraft is already high enough
/// that the layer would not trip. The profile is only ever raised, and the climbs are started early enough to be followed
/// at the plan's own gradient.
public enum ProfileRepair {
    public struct Settings: Sendable {
        /// Metres kept above the clearance when an obstacle is in the look-ahead.
        public var margin = 2.0
        /// The plan's climb and descent gradient (rise over run), the one the joins are built with.
        public var gradient = 0.8 * tan(20 * Double.pi / 180)

        public init() {}
    }

    /// Speed used for the look-ahead when the sample's own speed is lower, metres per second.
    static let minSpeed = 10.0
    /// A shortfall below this, metres, is met.
    static let settled = 1e-4
    /// Safety bound on the raise sweeps. A route settles in a handful.
    static let maxSweeps = 500
    /// Safety bound on the smoothing rounds around the loop.
    static let maxSmoothingRounds = 10_000
    /// How far past the nearest point a waypoint's search goes before it stops, metres.
    static let searchOvershoot = 20.0

    /// Returns `plan` with its waypoint altitudes raised (never lowered) to the avoidance-clear profile, smoothed so a climb
    /// starts early enough to follow at `gradient`. Only `assembly.waypoints[k].alt` changes. A route with no obstacle in any
    /// look-ahead comes back unchanged, and so does a route that is already clear: the result is a fixed point.
    ///
    /// Each sample's need depends only on the geometry, so it is worked out once. Then, sweep by sweep, every
    /// waypoint-to-waypoint segment is lifted by the worst shortfall among the samples it flies, and the waypoints are
    /// smoothed at the gradient. The segment is a straight blend of its two ends, so lifting both ends by a shortfall lifts
    /// every sample in it by at least that much. The gradient rule carries each climb back to where it has to start.
    public static func raise(_ plan: RoutePlan, obstacles: ObstacleSource, tuning: FlightTuning = FlightTuning(),
                             settings: Settings = Settings()) -> RoutePlan {
        var out = plan
        out.assembly.waypoints = raise(waypoints: plan.assembly.waypoints, obstacles: obstacles, tuning: tuning, settings: settings)
        return out
    }

    /// The same repair on a closed loop of waypoints: the altitudes come back raised (never lowered), and only `alt` changes.
    /// `raise(_:obstacles:...)` is this applied to the plan's waypoints.
    public static func raise(waypoints: [Waypoint], obstacles: ObstacleSource, tuning: FlightTuning = FlightTuning(),
                             settings: Settings = Settings()) -> [Waypoint] {
        let original = waypoints
        guard original.count >= 4 else { return original }
        let route = Route(file: RouteFile(name: "Repair", closed: true, waypoints: original))
        let samples = route.samples
        let m = samples.count
        guard m > 0 else { return original }
        let n = original.count

        var need = [Double](repeating: 0, count: m)
        for i in 0..<m {
            need[i] = requirement(at: i, in: samples, spacing: route.spacing, obstacles: obstacles, tuning: tuning, settings: settings)
        }
        guard need.contains(where: { $0 > 0 }) else { return original }

        // Each waypoint's sample is the nearest one, searched forward from the previous waypoint. Positions do not change
        // with altitude, so this is fixed for the whole repair. Segment k flies the samples from at[k] to at[k + 1].
        var at = [Int](repeating: 0, count: n)
        var from = 0
        for k in 0..<n {
            from = nearestSample(to: original[k], from: from, samples: samples)
            at[k] = from
        }

        var wps = original
        for _ in 0..<maxSweeps {
            let flown = Route(file: RouteFile(name: "Repair", closed: true, waypoints: wps)).samples
            guard flown.count == m else { break }
            var lift = [Double](repeating: 0, count: n)
            for k in 0..<n {
                let a = at[k], span = (at[(k + 1) % n] - a + m) % m
                for t in 0...span {
                    let j = (a + t) % m
                    if need[j] > 0 {
                        lift[k] = max(lift[k], need[j] - flown[j].altitude)
                    }
                }
            }
            guard lift.contains(where: { $0 > settled }) else { break }
            for k in 0..<n where lift[k] > settled {
                wps[k].alt += lift[k]
                wps[(k + 1) % n].alt += lift[k]
            }
            smoothWaypoints(&wps, gradient: settings.gradient)
        }

        return wps
    }

    /// The altitude sample `i` needs. The avoidance layer checks the path at 1, 2 and 3 s ahead, and the wings either side of
    /// the path at 0 s and at each of those times; the sample at each look-ahead is the one `tau` seconds on at this speed.
    /// Zero when nothing is in the way, otherwise the tallest obstacle found plus the clearance and the margin.
    static func requirement(at i: Int, in samples: [Route.Sample], spacing: Double, obstacles: ObstacleSource, tuning: FlightTuning,
                            settings: Settings) -> Double {
        let m = samples.count
        let speed = max(samples[i].speed, minSpeed)
        func ahead(_ tau: Double) -> Int {
            ((i + Int((speed * tau / spacing).rounded())) % m + m) % m
        }
        func height(_ e: Double, _ n: Double) -> Double {
            Double(obstacles.height(east: e, north: n))
        }
        // The wings of sample j: a margin either side of it, along the normal to its tangent.
        func wingHeight(_ j: Int) -> Double {
            let p = samples[j]
            guard tuning.wingMargin > 0 else { return 0 }
            let rx = p.tangentNorth * tuning.wingMargin, ry = -p.tangentEast * tuning.wingMargin
            return max(height(p.east + rx, p.north + ry), height(p.east - rx, p.north - ry))
        }

        var tallest = wingHeight(i)
        for tau in tuning.avoidLookahead {
            let j = ahead(tau)
            tallest = max(tallest, height(samples[j].east, samples[j].north), wingHeight(j))
        }
        return tallest > 0 ? tallest + tuning.clearance + settings.margin : 0
    }

    /// The sample nearest a waypoint, searched forward from `start` (wrapping round the loop). The search stops once it has
    /// gone past the nearest point, so a leg of the route that passes over the waypoint's own leg further on is not picked.
    static func nearestSample(to w: Waypoint, from start: Int, samples: [Route.Sample]) -> Int {
        let m = samples.count
        var best = start % m
        var bestD = Double.infinity
        for k in 0..<m {
            let j = (start + k) % m
            let d = hypot(samples[j].east - w.east, samples[j].north - w.north)
            if d < bestD {
                bestD = d
                best = j
            } else if d > bestD + searchOvershoot {
                break
            }
        }
        return best
    }

    /// The gradient rule over the waypoints, by the horizontal distance between consecutive ones: raise only.
    static func smoothWaypoints(_ wps: inout [Waypoint], gradient: Double) {
        let n = wps.count
        var alt = wps.map(\.alt)
        var steps = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let a = wps[k], b = wps[(k + 1) % n]
            steps[k] = gradient * hypot(b.east - a.east, b.north - a.north) + 1e-6
        }
        smoothLoop(&alt, steps: steps)
        for k in 0..<n {
            wps[k].alt = alt[k]
        }
    }

    /// Raise-only smoothing around a closed loop. `steps[k]` is the largest allowed change between value k and value k+1
    /// (mod count). Each value is only ever raised, to the least that satisfies both neighbours, so the result is never below
    /// the input and each neighbour pair is within its step, in both directions.
    static func smoothLoop(_ v: inout [Double], steps: [Double]) {
        let n = v.count
        guard n > 1 else { return }
        for _ in 0..<maxSmoothingRounds {
            var changed = false
            // Backward, two laps round so the wrap is settled.
            for t in 0..<(2 * n) {
                let k = ((n - 1 - t) % n + n) % n
                let next = (k + 1) % n
                let raised = v[next] - steps[k]
                if raised > v[k] {
                    v[k] = raised
                    changed = true
                }
            }
            // Forward, two laps round.
            for t in 0..<(2 * n) {
                let k = t % n
                let next = (k + 1) % n
                let raised = v[k] - steps[k]
                if raised > v[next] {
                    v[next] = raised
                    changed = true
                }
            }
            if !changed { break }
        }
    }
}
