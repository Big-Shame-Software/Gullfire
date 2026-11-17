import Foundation

/// Anything that can say how tall the obstacles are at a point, in metres. `CityPackage` does.
public protocol ObstacleSource: Sendable {
    func height(east: Double, north: Double) -> Float
}

extension CityPackage: ObstacleSource {
    public func height(east: Double, north: Double) -> Float {
        obstacleHeight(east: east, north: north)
    }
}

/// The aircraft's position after `tau` seconds on its current heading and turn rate (a constant-turn arc).
public func predict(_ s: FlightState, after tau: Double, tuning t: FlightTuning) -> (east: Double, north: Double) {
    let v = s.speed * cos(s.pitch)
    let omega = t.gravity * tan(s.bank) / max(s.speed, 1)
    if abs(omega) < 1e-9 {
        return (s.east + v * tau * sin(s.heading), s.north + v * tau * cos(s.heading))
    }
    let h = s.heading
    let east = s.east + v * (cos(h) - cos(h + omega * tau)) / omega
    let north = s.north + v * (sin(h + omega * tau) - sin(h)) / omega
    return (east, north)
}

/// What avoidance asks for this step. `pitch` is a command to add to the pilot's; `roll`
/// replaces the pilot's roll while `active`.
public struct AvoidanceResult: Sendable, Equatable {
    public var pitch: Double = 0
    public var roll: Double = 0
    public var active = false
}

public enum Avoidance {
    /// Looks 1, 2 and 3 seconds ahead along the predicted path. A sample is blocked if
    /// the obstacle there is taller than the aircraft's altitude minus the clearance. The check
    /// covers only the path itself, with no sideways margin, because the river is flyable at ±20 m.
    public static func assess(_ s: FlightState, obstacles: ObstacleSource, tuning t: FlightTuning) -> AvoidanceResult {
        var result = AvoidanceResult()
        let limit = Double(s.altitude) - t.clearance
        var blockedAhead = false
        let horizon = t.avoidLookahead.max() ?? 1
        for tau in t.avoidLookahead {
            let p = predict(s, after: tau, tuning: t)
            if Double(obstacles.height(east: p.east, north: p.north)) > limit {
                blockedAhead = true
                // Sooner means harder: with the default 1, 2, 3 s this is 0.8, 0.53, 0.27.
                result.pitch = max(result.pitch, t.avoidPitch * (horizon + 1 - tau) / horizon)
            }
        }
        // Wing check: the same height test a margin either side of the predicted path, now and 1, 2 and 3 s ahead.
        // A building beside the aircraft that the centre line does not touch (a street wall) is steered away from.
        var leftBlocked = false, rightBlocked = false
        if t.wingMargin > 0 {
            let omega = t.gravity * tan(s.bank) / max(s.speed, 1)
            for tau in [0.0] + t.avoidLookahead {
                let p = predict(s, after: tau, tuning: t)
                let h = s.heading + omega * tau
                let rx = cos(h), ry = -sin(h)          // to the right of the direction of travel
                if Double(obstacles.height(east: p.east + rx * t.wingMargin, north: p.north + ry * t.wingMargin)) > limit { rightBlocked = true }
                if Double(obstacles.height(east: p.east - rx * t.wingMargin, north: p.north - ry * t.wingMargin)) > limit { leftBlocked = true }
            }
        }
        guard blockedAhead else {
            if leftBlocked != rightBlocked {
                result.active = true
                result.roll = leftBlocked ? t.avoidRoll * t.wingRoll : -t.avoidRoll * t.wingRoll    // roll away from the wall
            }
            return result
        }
        result.active = true

        // Roll toward the side that is clearer over the next probe distance.
        let left = maxHeight(s, offset: -t.probeAngle, obstacles: obstacles, tuning: t)
        let right = maxHeight(s, offset: t.probeAngle, obstacles: obstacles, tuning: t)
        let leftClear = left <= limit, rightClear = right <= limit
        if leftClear && !rightClear {
            result.roll = -t.avoidRoll
        } else if rightClear && !leftClear {
            result.roll = t.avoidRoll
        } else if leftClear && rightClear {
            result.roll = left <= right ? -t.avoidRoll : t.avoidRoll
        }   // both blocked: pitch only
        return result
    }

    /// The tallest obstacle along a probe ray at `offset` from the heading.
    static func maxHeight(_ s: FlightState, offset: Double, obstacles: ObstacleSource, tuning t: FlightTuning) -> Double {
        let h = s.heading + offset
        var tallest = 0.0
        var d = 20.0
        while d <= t.probeDistance {
            let e = s.east + d * sin(h), n = s.north + d * cos(h)
            tallest = max(tallest, Double(obstacles.height(east: e, north: n)))
            d += 20
        }
        return tallest
    }
}

/// Keeps the aircraft inside the package. Returns a roll command toward the
/// centre when the aircraft is within `boundaryMargin` of the edge and heading outward.
public enum BoundaryGuard {
    public static func assess(_ s: FlightState, extent e: Manifest.Extent, tuning t: FlightTuning) -> (roll: Double, active: Bool) {
        let centreE = (e.minEast + e.maxEast) / 2, centreN = (e.minNorth + e.maxNorth) / 2
        // Distance to each edge, and the outward normal of the nearest one.
        let edges: [(dist: Double, nE: Double, nN: Double)] = [
            (s.east - e.minEast, -1, 0), (e.maxEast - s.east, 1, 0),
            (s.north - e.minNorth, 0, -1), (e.maxNorth - s.north, 0, 1),
        ]
        guard let nearest = edges.min(by: { $0.dist < $1.dist }), nearest.dist < t.boundaryMargin else {
            return (0, false)
        }
        // Outward only: heading has a component along the outward normal.
        let hE = sin(s.heading), hN = cos(s.heading)
        guard hE * nearest.nE + hN * nearest.nN > 0 else { return (0, false) }
        let desired = atan2(centreE - s.east, centreN - s.north)
        let error = wrapPi(desired - s.heading)
        return (clamp(error * 1.5, -1, 1), true)
    }
}
