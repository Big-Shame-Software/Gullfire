import Foundation

/// The River loop. The path is the main stem from the lake to the fork, then the
/// longer branch, resampled every 60 m. The low leg is at 60 m where it is clear and climbs over
/// the tight stretches (PLAN 8.3 step 5, owner 2026-11-11). The return leg is high, as before.
public enum RiverRoute {
    public struct Stretch: Sendable, Equatable {
        public var startEast: Double, startNorth: Double
        public var endEast: Double, endNorth: Double
        /// Highest altitude reached in the stretch, metres.
        public var peakAltitude: Double
        /// The building that sets the peak: its location and height.
        public var causeEast: Double, causeNorth: Double, causeHeight: Double
        /// Distance along the low leg from the lake end, metres (start and end).
        public var startDistance: Double, endDistance: Double
    }

    public struct Profile: Sendable {
        public var route: RouteFile
        /// Altitude at every 60 m point of the low leg, metres.
        public var lowLegAltitudes: [Double]
        /// Distance along the low leg of each point, metres.
        public var lowLegDistances: [Double]
        /// The raised points' required altitude before ramps (for the report), metres.
        public var required: [Double]
        public var stretches: [Stretch]
        /// Climb gradient used for the ramps: rise per metre of distance, from `FlightTuning.pitchLimit`.
        public var gradient: Double
        /// Share of the low leg still at the 60 m floor.
        public var shareAtFloor: Double
    }

    public static let floorAltitude = 60.0
    public static let returnAltitude = 350.0
    public static let lateralRadius = 20.0
    public static let clearanceAboveBuilding = 30.0
    public static let gapMerge = 300.0
    public static let spacing = 60.0
    /// Clearance is checked, and the profile computed, every 10 m along the line.
    public static let checkSpacing = 10.0
    public static let returnOffset = 600.0

    /// `stem` runs from the lake end to the fork; `branch` starts at the fork (PLAN 8.3 step 2).
    /// The loop is the low leg (60 m floor) then the return leg (350 m floor), and the same rule
    /// applies to both: the altitude is at least the floor and at least the tallest building within
    /// 20 m laterally plus 30 m. Ramps follow the gradient limit around the whole closed loop.
    public static func build(stem: [[Double]], branch: [[Double]], obstacles: ObstacleSource,
                             tuning: FlightTuning, speedKnots: Double = 90) -> Profile {
        build(path: stem + branch.dropFirst(), returnShift: [0, returnOffset],
              obstacles: obstacles, tuning: tuning, speedKnots: speedKnots)
    }

    /// The same loop for a river given as one path. `returnShift` is the (east, north) offset in
    /// metres of the high return leg from the low leg. Chicago's is 600 m north; a river that runs
    /// north-south needs a sideways shift, which the city's `river_chains.json` supplies.
    public static func build(path: [[Double]], returnShift: [Double], obstacles: ObstacleSource,
                             tuning: FlightTuning, speedKnots: Double = 90) -> Profile {
        // The clearance is checked every 10 m along each leg, not only at the 60 m waypoints: a 20 m
        // radius around a point 60 m apart misses obstacles between them (the Willis antenna, 23 m off
        // the line, was missed that way). Waypoints stay every 60 m; see below.
        let low = resample(path, step: checkSpacing)
        let back = resample(path, step: checkSpacing).reversed().map { [$0[0] + returnShift[0], $0[1] + returnShift[1]] }
        let points = low + back
        let n = points.count
        let lowCount = low.count
        // Distance from each point to the next, around the loop.
        var step = [Double](repeating: 0, count: n)
        for i in 0..<n { step[i] = dist(points[i], points[(i + 1) % n]) }
        var cumulative = [Double](repeating: 0, count: n)
        for i in 1..<n { cumulative[i] = cumulative[i - 1] + step[i - 1] }
        let loopLength = cumulative[n - 1] + step[n - 1]

        // Floor and requirement at each point.
        var floorAt = [Double](repeating: floorAltitude, count: n)
        for i in lowCount..<n { floorAt[i] = returnAltitude }
        var required = floorAt
        var causeHeight = [Double](repeating: 0, count: n)
        var causeAt = [(Double, Double)](repeating: (0, 0), count: n)
        for i in 0..<n {
            var tallest = 0.0
            var at = (points[i][0], points[i][1])
            for dx in stride(from: -lateralRadius, through: lateralRadius, by: 2) {
                for dy in stride(from: -lateralRadius, through: lateralRadius, by: 2)
                where dx * dx + dy * dy <= lateralRadius * lateralRadius {
                    let e = points[i][0] + dx, nn = points[i][1] + dy
                    let h = Double(obstacles.height(east: e, north: nn))
                    if h > tallest { tallest = h; at = (e, nn) }
                }
            }
            causeHeight[i] = tallest
            causeAt[i] = at
            if tallest > 0 { required[i] = max(floorAt[i], tallest + clearanceAboveBuilding) }
        }

        // Gaps: a stretch of points between two raised ones closer than 300 m is raised too.
        // Walks the loop once; a gap that wraps round the start is handled the same way.
        let raised = (0..<n).map { required[$0] > floorAt[$0] }
        if let firstRaised = raised.firstIndex(of: true) {
            var lastRaisedEnd: Int?
            var i = 0
            var walked = 0
            while walked < n {
                let k = (firstRaised + i) % n
                if raised[k] {
                    if let prev = lastRaisedEnd {
                        let gap = (cumulative[k] - cumulative[prev] + loopLength).truncatingRemainder(dividingBy: loopLength)
                        if gap < gapMerge {
                            var m = (prev + 1) % n
                            let peak = max(required[prev], required[k])
                            while m != k {
                                required[m] = max(required[m], peak)
                                m = (m + 1) % n
                            }
                        }
                    }
                    var j = k
                    while raised[(j + 1) % n] && (j + 1) % n != firstRaised { j = (j + 1) % n }
                    lastRaisedEnd = j
                    i = (j - firstRaised + n) % n + 1
                    walked = i
                } else {
                    i += 1
                    walked = i
                }
            }
        }

        // Ramps: the least altitude that is at least `required` and never climbs or descends faster
        // than the gradient allows. Two cyclic forward and backward passes settle the loop.
        let gradient = tan(tuning.pitchLimit)
        var alt = required
        for _ in 0..<2 {
            for k in 0..<(2 * n) {
                let i = k % n, prev = (i - 1 + n) % n
                alt[i] = max(alt[i], alt[prev] - gradient * step[prev])
            }
            for k in stride(from: 2 * n - 1, through: 0, by: -1) {
                let i = k % n, next = (i + 1) % n
                alt[i] = max(alt[i], alt[next] - gradient * step[i])
            }
        }

        // Stretches per leg: runs above that leg's floor.
        var stretches: [Stretch] = []
        var k = 0
        while k < n {
            let legFloor = floorAt[k]
            guard alt[k] > legFloor + 0.5 else { k += 1; continue }
            var end = k
            while end + 1 < n && alt[end + 1] > floorAt[end + 1] + 0.5 && (end + 1 < lowCount) == (k < lowCount) {
                end += 1
            }
            var peakIndex = k
            for m in k...end where alt[m] > alt[peakIndex] { peakIndex = m }
            var causeIndex = k
            for m in k...end where causeHeight[m] > causeHeight[causeIndex] { causeIndex = m }
            stretches.append(Stretch(
                startEast: points[k][0], startNorth: points[k][1], endEast: points[end][0], endNorth: points[end][1],
                peakAltitude: alt[peakIndex],
                causeEast: causeAt[causeIndex].0, causeNorth: causeAt[causeIndex].1, causeHeight: causeHeight[causeIndex],
                startDistance: cumulative[k], endDistance: cumulative[end]))
            k = end + 1
        }

        // Waypoints every 60 m. Each takes the highest altitude within 30 m either side of
        // it, so a 10 m profile point between two waypoints is never below its requirement.
        var waypoints: [Waypoint] = []
        let every = Int((spacing / checkSpacing).rounded())
        for m in stride(from: 0, to: n, by: every) {
            var top = alt[m]
            for d in -(every / 2)...(every / 2) { top = max(top, alt[(m + d + n) % n]) }
            waypoints.append(Waypoint(east: points[m][0], north: points[m][1], alt: top, speedKt: speedKnots))
        }
        let lowAtFloor = (0..<lowCount).filter { alt[$0] <= floorAltitude + 0.5 }.count
        return Profile(route: RouteFile(name: "River", closed: true, waypoints: waypoints),
                       lowLegAltitudes: Array(alt[0..<lowCount]), lowLegDistances: Array(cumulative[0..<lowCount]),
                       required: required, stretches: stretches, gradient: gradient,
                       shareAtFloor: Double(lowAtFloor) / Double(lowCount))
    }

    static func dist(_ a: [Double], _ b: [Double]) -> Double {
        ((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1])).squareRoot()
    }

    /// Points every `step` metres of arc length along a polyline, including its last point.
    public static func resample(_ points: [[Double]], step: Double) -> [[Double]] {
        guard points.count > 1 else { return points }
        var out: [[Double]] = [points[0]]
        var carry = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let seg = dist(a, b)
            guard seg > 0 else { continue }
            var d = step - carry
            while d <= seg {
                let f = d / seg
                out.append([a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f])
                d += step
            }
            carry = seg - (d - step)
        }
        if let last = points.last, dist(out[out.count - 1], last) > 1 { out.append(last) }
        return out
    }
}
