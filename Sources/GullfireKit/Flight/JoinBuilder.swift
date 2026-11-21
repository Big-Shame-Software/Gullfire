import Foundation

/// The constants and limits a join is built with. The bounds are the allowed box (the generator's "edge").
public struct JoinSettings: Sendable {
    public var altitude: Double
    public var joinSpeedKt: Double
    public var maxJoin: Double
    public var maxClimb: Double
    public var maxTop: Double
    public var cellSize: Double
    public var minEast: Double
    public var maxEast: Double
    public var minNorth: Double
    public var maxNorth: Double

    public init(altitude: Double, joinSpeedKt: Double, maxJoin: Double, maxClimb: Double, maxTop: Double, cellSize: Double,
                minEast: Double, maxEast: Double, minNorth: Double, maxNorth: Double) {
        self.altitude = altitude
        self.joinSpeedKt = joinSpeedKt
        self.maxJoin = maxJoin
        self.maxClimb = maxClimb
        self.maxTop = maxTop
        self.cellSize = cellSize
        self.minEast = minEast
        self.maxEast = maxEast
        self.minNorth = minNorth
        self.maxNorth = maxNorth
    }
}

/// A feasible join from the end of one stretch to the start of another: a point every 10 m, with the altitude at each.
public struct Join: Sendable, Equatable {
    public let path: [SIMD2<Double>]
    public let alt: [Double]
    public let startAlt: Double
    public let endAlt: Double
    public let length: Double
}

/// Port of `make_join`, `hermite_path`, `min_radius` and `river_profile` in Tools/make_street_routes.py.
public enum JoinBuilder {
    static let g = 9.80665
    static let kt = 0.514444
    static let checkStep = 10.0
    /// Python's math.radians(x) is x * (pi / 180); kept so the constants match the generator bit for bit.
    static func radians(_ degrees: Double) -> Double { degrees * (Double.pi / 180.0) }
    static let planGradient = 0.8 * tan(radians(20.0))

    public static func build(from aEnd: SIMD2<Double>, heading aDir: SIMD2<Double>,
                             to bStart: SIMD2<Double>, heading bDir: SIMD2<Double>,
                             obstacles: ObstacleSource, settings s: JoinSettings) -> Join? {
        let dist = hypot(bStart.x - aEnd.x, bStart.y - aEnd.y)
        let rMin = s.joinSpeedKt * kt * s.joinSpeedKt * kt / (g * tan(radians(30.0)))
        guard dist >= 150.0 && dist <= s.maxJoin else { return nil }
        for k in [0.5 * dist, 0.8 * dist, 1.2 * dist] {
            let path = hermitePath(aEnd, aDir, bStart, bDir, k)
            if minRadius(path) < rMin * 0.9 { continue }
            if path.contains(where: { $0.x <= s.minEast || $0.x >= s.maxEast || $0.y <= s.minNorth || $0.y >= s.maxNorth }) {
                continue
            }
            let alt = riverProfile(path, obstacles: obstacles, cellSize: s.cellSize, altFloor: s.altitude)
            if (alt[0] - s.altitude) / planGradient > s.maxClimb || (alt[alt.count - 1] - s.altitude) / planGradient > s.maxClimb {
                continue
            }
            if (alt.max() ?? 0) > s.maxTop { continue }
            return Join(path: path, alt: alt, startAlt: alt[0], endAlt: alt[alt.count - 1], length: pathLength(path))
        }
        return nil
    }

    /// A smooth path from p0 heading d0 to p1 heading d1, as points every 10 m, ends included.
    static func hermitePath(_ p0: SIMD2<Double>, _ d0: SIMD2<Double>, _ p1: SIMD2<Double>, _ d1: SIMD2<Double>, _ k: Double) -> [SIMD2<Double>] {
        let n = 400
        let step = 1.0 / Double(n - 1)
        var dense = [SIMD2<Double>]()
        dense.reserveCapacity(n)
        for i in 0..<n {
            let u = Double(i) * step
            let h00 = 2 * u * u * u - 3 * u * u + 1
            let h10 = u * u * u - 2 * u * u + u
            let h01 = -2 * u * u * u + 3 * u * u
            let h11 = u * u * u - u * u
            dense.append(h00 * p0 + h10 * d0 * k + h01 * p1 + h11 * d1 * k)
        }
        // Cumulative distance along the dense path.
        var d = [Double](repeating: 0, count: n)
        for i in 1..<n {
            let dx = dense[i].x - dense[i - 1].x, dy = dense[i].y - dense[i - 1].y
            d[i] = d[i - 1] + hypot(dx, dy)
        }
        let total = d[n - 1]
        var out = [SIMD2<Double>]()
        var j = 0
        var idx = 0
        // numpy arange(0, total, 10): values i*10 strictly below total.
        while true {
            let t = Double(idx) * checkStep
            if !(t < total) { break }
            while j < n - 2 && d[j + 1] <= t { j += 1 }
            out.append(interpolate(t, d, dense, j))
            idx += 1
        }
        out.append(dense[n - 1])
        return out
    }

    /// Linear interpolation on segment j (np.interp semantics: slope * (t - x[j]) + y[j]).
    static func interpolate(_ t: Double, _ d: [Double], _ dense: [SIMD2<Double>], _ j: Int) -> SIMD2<Double> {
        let x0 = d[j], x1 = d[j + 1]
        let slopeX = (dense[j + 1].x - dense[j].x) / (x1 - x0)
        let slopeY = (dense[j + 1].y - dense[j].y) / (x1 - x0)
        return SIMD2(slopeX * (t - x0) + dense[j].x, slopeY * (t - x0) + dense[j].y)
    }

    static func pathLength(_ path: [SIMD2<Double>]) -> Double {
        var total = 0.0
        for i in 1..<max(path.count, 1) {
            total += hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y)
        }
        return total
    }

    /// The smallest turning radius along the path, from the angle between consecutive segments.
    static func minRadius(_ path: [SIMD2<Double>]) -> Double {
        guard path.count >= 3 else { return 1e9 }
        var best = Double.infinity
        for i in 0..<(path.count - 2) {
            let a = path[i], b = path[i + 1], c = path[i + 2]
            let ab = b - a, bc = c - b
            let cross = ab.x * bc.y - ab.y * bc.x
            let dot = ab.x * bc.x + ab.y * bc.y
            let ang = abs(atan2(cross, dot))
            let arc = hypot(ab.x, ab.y) + hypot(bc.x, bc.y)
            let r = ang > 1e-6 ? arc / max(ang, 1e-9) : 1e9
            best = min(best, r)
        }
        return best
    }

    /// Height of the tallest obstacle within about w metres of a point, as the generator's grid query: the max over
    /// cells whose offset is within (w + cell size), with the grid's own cells read through the obstacle source.
    static func heightNear(_ p: SIMD2<Double>, w: Double, obstacles: ObstacleSource, cellSize c: Double) -> Double {
        let k = Int(ceil(w / c))
        var out = 0.0
        for dr in -k...k {
            for dc in -k...k {
                let ox = Double(dc) * c, oy = Double(dr) * c
                if ox * ox + oy * oy > (w + c) * (w + c) { continue }
                let h = Double(obstacles.height(east: p.x + ox, north: p.y + oy))
                out = max(out, h)
            }
        }
        return out
    }

    /// The River rule on a join. Returns the altitude at each path point.
    static func riverProfile(_ path: [SIMD2<Double>], obstacles: ObstacleSource, cellSize: Double, altFloor: Double) -> [Double] {
        var req = path.map { max(altFloor, heightNear($0, w: 20.0, obstacles: obstacles, cellSize: cellSize) + 33.0) }
        let base = [Double](repeating: altFloor, count: path.count)
        let n = path.count
        // Raised points are found once, before the gap merge.
        var raisedIdx = [Int]()
        for i in 0..<n where req[i] > base[i] + 0.5 { raisedIdx.append(i) }
        // Merge gaps under 300 m between raised points.
        if raisedIdx.count >= 2 {
            for q in 0..<(raisedIdx.count - 1) {
                let a = raisedIdx[q], b = raisedIdx[q + 1]
                if 1 < b - a && Double(b - a) * checkStep < 300.0 {
                    let m = max(req[a], req[b])
                    for i in a...b { req[i] = max(req[i], m) }
                }
            }
        }
        var alt = req
        let step = planGradient * checkStep
        for _ in 0..<2 {
            if n > 1 {
                for i in 1..<n { alt[i] = max(alt[i], alt[i - 1] - step) }
                for i in stride(from: n - 2, through: 0, by: -1) { alt[i] = max(alt[i], alt[i + 1] - step) }
            }
        }
        return alt
    }
}
