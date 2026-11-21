import Foundation
import simd

extension Camera {
    /// The world-space ray through a point of the view. ndc.x, ndc.y in -1...1 (x right, y UP), `aspect` = width/height.
    /// Uses the same basis as `viewProjection`: forward f = normalize(target - eye), right s and up u with the roll applied.
    public func ray(ndc: SIMD2<Double>, aspect: Double) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        let eyeD = SIMD3<Double>(Double(eye.x), Double(eye.y), Double(eye.z))
        let targetD = SIMD3<Double>(Double(target.x), Double(target.y), Double(target.z))
        let f = simd_normalize(targetD - eyeD)
        let worldUp = SIMD3<Double>(0, 1, 0)
        let right = simd_normalize(simd_cross(f, worldUp))
        let rollD = Double(roll)
        let up = cos(rollD) * worldUp + sin(rollD) * right
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        let t = tan(Double(fovDegrees) * .pi / 360)
        let direction = simd_normalize(f + ndc.x * t * aspect * s + ndc.y * t * u)
        return (eyeD, direction)
    }
}

/// A street stretch picked on screen.
public struct StreetPick: Sendable, Equatable {
    /// Index into graph.stretches.
    public var stretchIndex: Int
    /// The direction to fly it.
    public var reversed: Bool
    /// Where the click met the ground (east, north), in metres.
    public var hit: SIMD2<Double>
    /// Metres from the hit to the stretch's centre line.
    public var distance: Double

    public init(stretchIndex: Int, reversed: Bool, hit: SIMD2<Double>, distance: Double) {
        self.stretchIndex = stretchIndex
        self.reversed = reversed
        self.hit = hit
        self.distance = distance
    }
}

/// Finds the street under a click on the screen.
public enum StreetPicker {
    /// Marches the ray in 5 m steps (up to 8000 m) until its height is at or below the obstacle height under it
    /// (0 on open ground), then refines by bisection to 1 m. Returns nil when the ray never comes down.
    /// Render space: x east, y altitude, z = -north.
    public static func groundHit(origin: SIMD3<Double>, direction: SIMD3<Double>, obstacles: ObstacleSource) -> SIMD2<Double>? {
        func point(_ t: Double) -> SIMD3<Double> { origin + t * direction }
        func below(_ t: Double) -> Bool {
            let p = point(t)
            let height = Double(obstacles.height(east: p.x, north: -p.z))
            return p.y <= height
        }
        let maxDistance = 8000.0
        var lo = 0.0
        var hi = 0.0
        while hi < maxDistance {
            hi = min(hi + 5, maxDistance)
            if below(hi) {
                // Bisect between the last sample above the ground and this one below it.
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if below(mid) { hi = mid } else { lo = mid }
                }
                let p = point(hi)
                return SIMD2(p.x, -p.z)
            }
            lo = hi
        }
        return nil
    }

    /// The ground hit snapped to the nearest stretch centre line within `maxSnap` metres, and the direction to fly it:
    /// the orientation whose start heading turns least from `aircraftHeading` (radians, 0 = north, clockwise).
    public static func pick(
        camera: Camera,
        ndc: SIMD2<Double>,
        aspect: Double,
        aircraftHeading: Double,
        graph: StreetGraph,
        obstacles: ObstacleSource,
        maxSnap: Double = 80
    ) -> StreetPick? {
        candidates(camera: camera, ndc: ndc, aspect: aspect, aircraftHeading: aircraftHeading, graph: graph,
                   obstacles: obstacles, maxSnap: maxSnap, limit: 1).first
    }

    /// The ground hit's nearby streets, nearest first: every stretch whose centre line is within `maxSnap` metres of the hit,
    /// at most `limit`. Each carries the direction to fly it, chosen as `pick` does. Empty when the ray hits no ground.
    /// Ties in distance keep the lower stretch index first.
    public static func candidates(
        camera: Camera,
        ndc: SIMD2<Double>,
        aspect: Double,
        aircraftHeading: Double,
        graph: StreetGraph,
        obstacles: ObstacleSource,
        maxSnap: Double = 600,
        limit: Int = 6
    ) -> [StreetPick] {
        let ray = camera.ray(ndc: ndc, aspect: aspect)
        guard limit > 0, let hit = groundHit(origin: ray.origin, direction: ray.direction, obstacles: obstacles) else { return [] }

        var near: [(index: Int, distance: Double)] = []
        for (index, stretch) in graph.stretches.enumerated() where stretch.canStartAny {
            let d = distance(from: hit, to: stretch)
            if d <= maxSnap { near.append((index, d)) }
        }
        near.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.index < $1.index }

        return near.prefix(limit).map { candidate in
            let stretch = graph.stretches[candidate.index]
            let forward = PlannedStretch(stretch: stretch, reversed: false).startHeading
            let backward = PlannedStretch(stretch: stretch, reversed: true).startHeading
            let forwardError = abs(angleDifference(heading(of: forward), aircraftHeading))
            let backwardError = abs(angleDifference(heading(of: backward), aircraftHeading))
            // The direction closer to the aircraft's heading, unless only the other one can start a loop.
            let reversed: Bool
            if !stretch.canStart(reversed: false) { reversed = true }
            else if !stretch.canStart(reversed: true) { reversed = false }
            else { reversed = backwardError < forwardError }
            return StreetPick(
                stretchIndex: candidate.index,
                reversed: reversed,
                hit: hit,
                distance: candidate.distance
            )
        }
    }

    /// Distance from a point (east, north, metres) to a stretch's centre line: the nearest of its segments, or the point itself
    /// for a one-point stretch. Infinity for an empty one.
    public static func distance(from p: SIMD2<Double>, to stretch: StreetStretch) -> Double {
        let line = stretch.polyline
        if line.count == 1 { return pointDistance(p, line[0]) }
        guard line.count > 1 else { return .infinity }
        var best = Double.infinity
        for k in 1..<line.count {
            best = min(best, segmentDistance(p, line[k - 1], line[k]))
        }
        return best
    }

    /// The text for a pick: the street's names joined with " / " uppercased (up to 3), else its class uppercased, else "STREET".
    public static func label(for stretch: StreetStretch) -> String {
        let names = stretch.names.filter { !$0.isEmpty }.prefix(3)
        if !names.isEmpty {
            return names.joined(separator: " / ").uppercased()
        }
        if !stretch.streetClass.isEmpty {
            return stretch.streetClass.uppercased()
        }
        return "STREET"
    }

    /// Distance from a point to the segment ab, in metres.
    static func segmentDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        var t = 0.0
        if lengthSquared > 0 {
            let ap = p - a
            t = (ap.x * ab.x + ap.y * ab.y) / lengthSquared
        }
        t = min(max(t, 0), 1)
        return pointDistance(p, a + t * ab)
    }

    static func pointDistance(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double {
        let d = p - q
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    /// Heading of a (east, north) vector, 0 = north, clockwise, radians.
    static func heading(of v: SIMD2<Double>) -> Double {
        atan2(v.x, v.y)
    }

    /// The signed difference a - b wrapped to -pi...pi.
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = a - b
        return atan2(sin(d), cos(d))
    }
}
