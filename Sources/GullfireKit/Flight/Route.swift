import Foundation

/// One waypoint in a route file: metres east and north, altitude, and speed in knots.
public struct Waypoint: Codable, Sendable, Equatable {
    public var east: Double
    public var north: Double
    public var alt: Double
    public var speedKt: Double

    public init(east: Double, north: Double, alt: Double, speedKt: Double) {
        self.east = east
        self.north = north
        self.alt = alt
        self.speedKt = speedKt
    }
}

/// The route JSON file. The format is public; it is part of the SemVer surface.
public struct RouteFile: Codable, Sendable, Equatable {
    public var name: String
    public var closed: Bool
    public var waypoints: [Waypoint]

    public init(name: String, closed: Bool = true, waypoints: [Waypoint]) {
        self.name = name
        self.closed = closed
        self.waypoints = waypoints
    }
}

/// A closed loop flown as a centripetal Catmull-Rom spline. Samples every 10 m carry
/// position, altitude, speed, tangent and radius of curvature.
public struct Route: Sendable {
    public struct Sample: Sendable, Equatable {
        public var east: Double
        public var north: Double
        public var altitude: Double
        /// Target speed here, metres per second (the waypoint speed, interpolated).
        public var speed: Double
        public var tangentEast: Double
        public var tangentNorth: Double
        /// Radius of curvature, metres (large on straights).
        public var radius: Double
    }

    public let name: String
    public let samples: [Sample]
    public let spacing: Double

    public var count: Int { samples.count }
    public var length: Double { Double(samples.count) * spacing }

    public init(file: RouteFile, spacing: Double = 10) {
        name = file.name
        self.spacing = spacing
        samples = Route.build(file.waypoints, spacing: spacing)
    }

    public static func load(_ url: URL) throws -> Route {
        let file = try JSONDecoder().decode(RouteFile.self, from: Data(contentsOf: url))
        return Route(file: file)
    }

    /// The index of the sample nearest `east`/`north`. With a `hint`, searches a window around it
    /// Without a hint, it searches the whole route.
    public func nearestIndex(east: Double, north: Double, hint: Int? = nil) -> Int {
        var best = 0
        var bestD = Double.infinity
        let range: Range<Int>
        if let hint, count > 0 {
            let window = 300
            range = (hint - window)..<(hint + window)
        } else {
            range = 0..<count
        }
        for raw in range {
            let i = ((raw % count) + count) % count
            let s = samples[i]
            let d = (s.east - east) * (s.east - east) + (s.north - north) * (s.north - north)
            if d < bestD {
                bestD = d
                best = i
            }
        }
        return best
    }

    // MARK: - Construction

    static func build(_ wp: [Waypoint], spacing: Double) -> [Sample] {
        let n = wp.count
        guard n >= 4 else { return [] }
        // Dense points along each closed segment, with altitude and speed interpolated.
        var dense: [(e: Double, n: Double, alt: Double, spd: Double)] = []
        let perSegment = 200
        for i in 0..<n {
            let p0 = wp[(i - 1 + n) % n], p1 = wp[i], p2 = wp[(i + 1) % n], p3 = wp[(i + 2) % n]
            for k in 0..<perSegment {
                let t = Double(k) / Double(perSegment)
                let p = catmullRom(p0, p1, p2, p3, t)
                let alt = p1.alt + (p2.alt - p1.alt) * t
                let spd = (p1.speedKt + (p2.speedKt - p1.speedKt) * t) * FlightTuning.knotsToMetresPerSecond
                dense.append((p.e, p.n, alt, spd))
            }
        }
        // Arc length along the dense points, then resample every `spacing` metres.
        var cum = [0.0]
        for i in 1..<(dense.count + 1) {
            let a = dense[i - 1], b = dense[i % dense.count]
            cum.append(cum[i - 1] + ((b.e - a.e) * (b.e - a.e) + (b.n - a.n) * (b.n - a.n)).squareRoot())
        }
        let total = cum.last ?? 0
        let count = Int(total / spacing)
        var out: [Sample] = []
        out.reserveCapacity(count)
        var j = 0
        for k in 0..<count {
            let s = Double(k) * spacing
            while j < dense.count - 1 && cum[j + 1] < s { j += 1 }
            let a = dense[j], b = dense[(j + 1) % dense.count]
            let seg = cum[j + 1] - cum[j]
            let f = seg > 0 ? (s - cum[j]) / seg : 0
            out.append(Sample(east: a.e + (b.e - a.e) * f, north: a.n + (b.n - a.n) * f,
                              altitude: a.alt + (b.alt - a.alt) * f, speed: a.spd + (b.spd - a.spd) * f,
                              tangentEast: 0, tangentNorth: 0, radius: 1e6))
        }
        // Tangents and radius of curvature from neighbouring samples.
        let m = out.count
        for i in 0..<m {
            let prev = out[(i - 1 + m) % m], next = out[(i + 1) % m]
            let te = next.east - prev.east, tn = next.north - prev.north
            let len = (te * te + tn * tn).squareRoot()
            out[i].tangentEast = len > 0 ? te / len : 0
            out[i].tangentNorth = len > 0 ? tn / len : 0
        }
        for i in 0..<m {
            let a = out[(i - 1 + m) % m], b = out[(i + 1) % m]
            let turn = atan2(a.tangentEast * b.tangentNorth - a.tangentNorth * b.tangentEast,
                             a.tangentEast * b.tangentEast + a.tangentNorth * b.tangentNorth)
            let arc = 2 * spacing
            out[i].radius = abs(turn) > 1e-6 ? min(1e6, arc / abs(turn)) : 1e6
        }
        return out
    }

    /// Centripetal Catmull-Rom (alpha 0.5) between p1 and p2 at parameter t in [0, 1].
    static func catmullRom(_ p0: Waypoint, _ p1: Waypoint, _ p2: Waypoint, _ p3: Waypoint, _ t: Double) -> (e: Double, n: Double) {
        func dist(_ a: Waypoint, _ b: Waypoint) -> Double {
            ((a.east - b.east) * (a.east - b.east) + (a.north - b.north) * (a.north - b.north)).squareRoot()
        }
        let t0 = 0.0
        let t1 = t0 + max(1e-6, dist(p0, p1).squareRoot())
        let t2 = t1 + max(1e-6, dist(p1, p2).squareRoot())
        let t3 = t2 + max(1e-6, dist(p2, p3).squareRoot())
        let u = t1 + (t2 - t1) * t
        func lerp(_ a: (e: Double, n: Double), _ b: (e: Double, n: Double), _ ta: Double, _ tb: Double) -> (e: Double, n: Double) {
            let f = (u - ta) / (tb - ta)
            return (a.e + (b.e - a.e) * f, a.n + (b.n - a.n) * f)
        }
        let a1 = (e: p0.east, n: p0.north), a2 = (e: p1.east, n: p1.north)
        let a3 = (e: p2.east, n: p2.north), a4 = (e: p3.east, n: p3.north)
        let b1 = lerp(a1, a2, t0, t1), b2 = lerp(a2, a3, t1, t2), b3 = lerp(a3, a4, t2, t3)
        let c1 = lerp(b1, b2, t0, t2), c2 = lerp(b2, b3, t1, t3)
        return lerp(c1, c2, t1, t2)
    }
}
