import Foundation

/// One thing wrong with an assembled route, and the part of the route it belongs to.
public struct RouteFailure: Sendable, Equatable {
    public var owner: AssemblyOwner
    public var message: String

    public init(owner: AssemblyOwner, message: String) {
        self.owner = owner
        self.message = message
    }
}

/// Port of `check_route` in Tools/make_street_routes.py, on the obstacle grid only: footprints and overhead
/// structures are vetted offline by the generator, so they are not checked here. Adds the stretch-length rule, which
/// the generator never checked.
public enum RouteChecker {
    static let sampleStep = 10.0
    static let centreReach = 3.0
    static let riverClearance = 30.0
    static let riverTolerance = 1.5

    public static func check(_ plan: RoutePlan, obstacles: ObstacleSource, joinSettings js: JoinSettings,
                             settings s: AssemblySettings = .standard) -> [RouteFailure] {
        let wps = plan.assembly.waypoints
        let owners = plan.assembly.owners
        guard wps.count >= 4, owners.count == wps.count else {
            return [RouteFailure(owner: .run(0), message: "route has \(wps.count) waypoints; a closed route needs at least 4")]
        }
        var fails: [RouteFailure] = []
        let route = Route(file: RouteFile(name: "check", closed: true, waypoints: wps))
        let samples = route.samples
        let planGradient = JoinBuilder.planGradient
        let maxGradient = JoinBuilder.tanRadians(20.0) * 0.95

        // The stretch each sample is on: the first stretch whose centre line is within 3 m.
        let lines = plan.stretches.map { $0.points }
        let boxes = lines.map { boundingBox($0, pad: centreReach) }
        func stretchOf(_ p: SIMD2<Double>) -> Int? {
            for (i, line) in lines.enumerated() {
                let b = boxes[i]
                guard p.x >= b.minE && p.x <= b.maxE && p.y >= b.minN && p.y <= b.maxN else { continue }
                if distance(p, line) <= centreReach { return i }
            }
            return nil
        }

        // The nearest assembled waypoint, searched from the previous one (the route is walked in order).
        var hint: Int? = nil
        func waypointOwner(_ p: SIMD2<Double>) -> AssemblyOwner {
            let m = wps.count
            var best = 0
            var bestD = Double.infinity
            let offsets: Range<Int> = hint == nil ? 0..<m : -300..<301
            for off in offsets {
                let idx = hint.map { (($0 + off) % m + m) % m } ?? off
                let d = (wps[idx].east - p.x) * (wps[idx].east - p.x) + (wps[idx].north - p.y) * (wps[idx].north - p.y)
                if d < bestD {
                    bestD = d
                    best = idx
                }
            }
            hint = best
            return owners[best]
        }

        var altPrev = 0.0
        for (i, sample) in samples.enumerated() {
            let p = SIMD2(sample.east, sample.north)
            let a = sample.altitude
            let near = stretchOf(p)
            let owner: AssemblyOwner = near.map { .run($0) } ?? waypointOwner(p)

            if !(js.minEast < p.x && p.x < js.maxEast && js.minNorth < p.y && p.y < js.maxNorth) {
                fails.append(RouteFailure(owner: owner, message: "sample \(i) outside the inner box"))
                altPrev = a
                continue
            }
            if let run = near {
                let tall = JoinBuilder.heightNear(p, w: s.halfwidth, obstacles: obstacles, cellSize: js.cellSize)
                if tall > a - s.margin {
                    fails.append(RouteFailure(owner: .run(run),
                        message: String(format: "sample %d: grid has %.0f m within %.0f m at %.0f m up", i, tall, s.halfwidth, a)))
                }
            } else {
                let tall = JoinBuilder.heightNear(p, w: 20.0, obstacles: obstacles, cellSize: js.cellSize)
                if a < tall + riverClearance - riverTolerance {
                    fails.append(RouteFailure(owner: owner,
                        message: String(format: "sample %d: %.0f m up over %.0f m within 20 m (River rule)", i, a, tall)))
                }
            }
            if i >= 1 {
                let gradient = abs(a - altPrev) / sampleStep
                if gradient > maxGradient {
                    fails.append(RouteFailure(owner: owner, message: String(format: "sample %d: gradient %.2f", i, gradient)))
                }
            }
            altPrev = a
        }

        // Stretch length: the climb out of a stretch and the descent into it are flown along the street.
        let joinCount = plan.joins.count
        if joinCount > 0 {
            for (i, planned) in plan.stretches.enumerated() {
                let climb = max(0, (plan.joins[i % joinCount].startAlt - s.altitude) / planGradient)
                let descend = max(0, (plan.joins[(i - 1 + joinCount) % joinCount].endAlt - s.altitude) / planGradient)
                if climb + descend > planned.length {
                    fails.append(RouteFailure(owner: .run(i),
                        message: String(format: "stretch-length: stretch %@ is %.0f m but its climb and descent need %.0f m",
                                        planned.stretch.id, planned.length, climb + descend)))
                }
            }
        }
        return fails
    }

    /// Distance from a point to a polyline, to its segments rather than only its vertices.
    static func distance(_ p: SIMD2<Double>, _ line: [SIMD2<Double>]) -> Double {
        guard let first = line.first else { return .infinity }
        if line.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
        var best = Double.infinity
        for k in 1..<line.count {
            let a = line[k - 1], ab = line[k] - line[k - 1]
            let len2 = ab.x * ab.x + ab.y * ab.y
            var u = len2 > 0 ? ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2 : 0
            u = min(max(u, 0), 1)
            let q = a + ab * u
            best = min(best, hypot(p.x - q.x, p.y - q.y))
        }
        return best
    }

    struct Box {
        var minE: Double, maxE: Double, minN: Double, maxN: Double
    }

    static func boundingBox(_ line: [SIMD2<Double>], pad: Double) -> Box {
        guard let first = line.first else { return Box(minE: .infinity, maxE: -.infinity, minN: .infinity, maxN: -.infinity) }
        var b = Box(minE: first.x, maxE: first.x, minN: first.y, maxN: first.y)
        for q in line {
            b.minE = min(b.minE, q.x); b.maxE = max(b.maxE, q.x)
            b.minN = min(b.minN, q.y); b.maxN = max(b.maxN, q.y)
        }
        b.minE -= pad; b.maxE += pad; b.minN -= pad; b.maxN += pad
        return b
    }
}

extension JoinBuilder {
    /// tan of a angle in degrees, computed as the generator does (math.tan(math.radians(x))).
    static func tanRadians(_ degrees: Double) -> Double { tan(radians(degrees)) }
}
