import Foundation

/// A street stretch as the route uses it: its centre line, possibly walked backwards.
public struct PlannedStretch: Sendable, Equatable {
    public var stretch: StreetStretch
    public var reversed: Bool

    public init(stretch: StreetStretch, reversed: Bool) {
        self.stretch = stretch
        self.reversed = reversed
    }

    /// The centre line in the direction flown.
    public var points: [SIMD2<Double>] {
        let p = stretch.polyline
        return reversed ? Array(p.reversed()) : p
    }

    public var start: SIMD2<Double> { points.first ?? SIMD2(0, 0) }
    public var end: SIMD2<Double> { points.last ?? SIMD2(0, 0) }

    /// Direction at the start, from the first three metres of the line (as the generator does).
    public var startHeading: SIMD2<Double> {
        let p = points
        guard p.count >= 4 else { return unitVector(p.count < 2 ? SIMD2(0, 0) : p[1] - p[0]) }
        return unitVector(p[3] - p[0])
    }

    /// Direction at the end, from the last three metres of the line.
    public var endHeading: SIMD2<Double> {
        let p = points
        guard p.count >= 4 else { return unitVector(p.count < 2 ? SIMD2(0, 0) : p[p.count - 1] - p[p.count - 2]) }
        return unitVector(p[p.count - 1] - p[p.count - 4])
    }

    /// Polyline length in metres.
    public var length: Double {
        let p = points
        var total = 0.0
        for k in 1..<max(p.count, 1) {
            total += hypot(p[k].x - p[k - 1].x, p[k].y - p[k - 1].y)
        }
        return total
    }

    func unitVector(_ v: SIMD2<Double>) -> SIMD2<Double> {
        let l = hypot(v.x, v.y)
        return l > 0 ? v / l : SIMD2(0, 0)
    }
}

/// The speeds and altitudes the route is assembled with (the generator's command-line defaults).
public struct AssemblySettings: Sendable {
    /// Metres above ground for the stretches.
    public var altitude: Double
    /// Knots flown along the stretches.
    public var speedKt: Double
    /// Knots flown along the joins.
    public var joinSpeedKt: Double
    /// Metres of clearance above the tallest obstacle beside a stretch.
    public var margin: Double
    /// Metres either side of the centre line that the corridor check covers.
    public var halfwidth: Double

    public init(altitude: Double, speedKt: Double, joinSpeedKt: Double, margin: Double, halfwidth: Double) {
        self.altitude = altitude
        self.speedKt = speedKt
        self.joinSpeedKt = joinSpeedKt
        self.margin = margin
        self.halfwidth = halfwidth
    }

    public static let standard = AssemblySettings(altitude: 15, speedKt: 40, joinSpeedKt: 60, margin: 10, halfwidth: 6)
}

/// What a waypoint belongs to: a stretch (by its index in the sequence) or a join after it.
public enum AssemblyOwner: Sendable, Equatable {
    case run(Int)
    case join(Int)
}

/// The waypoints of a closed loop, with the owner of each.
public struct Assembly: Sendable, Equatable {
    public var waypoints: [Waypoint]
    public var owners: [AssemblyOwner]

    public init(waypoints: [Waypoint], owners: [AssemblyOwner]) {
        self.waypoints = waypoints
        self.owners = owners
    }
}

/// A planned loop: the stretches in flying order, the joins (`joins[i]` from stretch i to stretch i+1, the last one
/// closing the loop) and the assembled waypoints.
public struct RoutePlan: Sendable {
    public var stretches: [PlannedStretch]
    public var joins: [Join]
    public var assembly: Assembly

    public init(stretches: [PlannedStretch], joins: [Join], assembly: Assembly) {
        self.stretches = stretches
        self.joins = joins
        self.assembly = assembly
    }
}

/// Port of `assemble` in Tools/make_street_routes.py.
public enum RouteAssembler {
    /// Waypoints every 25 m along each stretch; the join path points between them.
    static let waypointSpacing = 25.0

    public static func assemble(_ seq: [PlannedStretch], joins: [Join], settings s: AssemblySettings) -> Assembly {
        var out = Assembly(waypoints: [], owners: [])
        let k = seq.count
        guard k > 0, joins.count == k else { return out }
        let planGradient = JoinBuilder.planGradient
        for i in 0..<k {
            let pts = seq[i].points
            let xs = pts.map { $0.x }, ys = pts.map { $0.y }
            let d = cumulativeDistance(pts)
            let length = d.last ?? 0
            let joinIn = joins[(i - 1 + k) % k], joinOut = joins[i]
            let climb = (joinOut.startAlt - s.altitude) / planGradient      // metres of street used to climb before the end
            let descend = (joinIn.endAlt - s.altitude) / planGradient       // metres of street used to descend after the start

            var t: [Double] = []
            var n = 0
            while Double(n) * waypointSpacing < length {
                t.append(Double(n) * waypointSpacing)
                n += 1
            }
            if let last = t.last, length - last > 1.0 { t.append(length) }

            for s0 in t {
                let east = interpolate(s0, d, xs)
                let north = interpolate(s0, d, ys)
                var alt = s.altitude
                if descend > 0 && s0 < descend {
                    alt = s.altitude + (joinIn.endAlt - s.altitude) * (1 - s0 / descend)
                }
                if climb > 0 && s0 > length - climb {
                    alt = max(alt, s.altitude + (joinOut.startAlt - s.altitude) * (s0 - (length - climb)) / climb)
                }
                out.waypoints.append(Waypoint(east: east, north: north, alt: alt, speedKt: s.speedKt))
                out.owners.append(.run(i))
            }

            // The join to the next stretch: its path points without the two ends (those are the stretches' own points).
            let j = joinOut
            if j.path.count > 2 {
                for m in 1..<(j.path.count - 1) {
                    out.waypoints.append(Waypoint(east: j.path[m].x, north: j.path[m].y, alt: j.alt[m], speedKt: s.joinSpeedKt))
                    out.owners.append(.join(i))
                }
            }
        }
        return out
    }

    /// Cumulative distance along a polyline, starting at 0.
    static func cumulativeDistance(_ p: [SIMD2<Double>]) -> [Double] {
        var d = [Double](repeating: 0, count: p.count)
        if p.count > 1 {
            for k in 1..<p.count {
                d[k] = d[k - 1] + hypot(p[k].x - p[k - 1].x, p[k].y - p[k - 1].y)
            }
        }
        return d
    }

    /// np.interp(x, xp, fp) for increasing xp: clamped at the ends, linear between.
    static func interpolate(_ x: Double, _ xp: [Double], _ fp: [Double]) -> Double {
        guard let first = xp.first, let last = xp.last else { return 0 }
        if x <= first { return fp[0] }
        if x >= last { return fp[fp.count - 1] }
        var lo = 0, hi = xp.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xp[mid] <= x { lo = mid } else { hi = mid }
        }
        let span = xp[hi] - xp[lo]
        guard span > 0 else { return fp[lo] }
        return fp[lo] + (fp[hi] - fp[lo]) * ((x - xp[lo]) / span)
    }
}

extension JoinSettings {
    /// The settings the generator builds joins with, for a package: the allowed box is the package extent inset by
    /// 600 m (the generator's BOUNDARY_MARGIN) on every side.
    public static func standard(for manifest: Manifest) -> JoinSettings {
        let e = manifest.extentM
        let margin = 600.0
        return JoinSettings(altitude: 15, joinSpeedKt: 60, maxJoin: 2500, maxClimb: 400, maxTop: 450,
                            cellSize: manifest.obstacleGrid.cellSizeM,
                            minEast: e.minEast + margin, maxEast: e.maxEast - margin,
                            minNorth: e.minNorth + margin, maxNorth: e.maxNorth - margin)
    }
}
