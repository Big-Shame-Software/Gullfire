import Foundation
import Testing
@testable import GullfireKit

/// A manual probe, not a regression test: flies the current Autopilot, Avoidance and FlightTuning along street
/// runs and reports how well it holds them.
///
///     STREET_PROBE=<cases.json> STREET_CITY=<package dir> STREET_OUT=<output dir> swift test --filter StreetProbe
///
/// It is skipped unless STREET_PROBE is set. It changes no flight code.
@Suite("Street probe (manual)", .enabled(if: ProcessInfo.processInfo.environment["STREET_PROBE"] != nil))
struct StreetProbeTests {
    struct Case: Decodable {
        var name: String
        var route: RouteFile
        /// The street's centre line, east and north in metres, in the direction of travel.
        var line: [[Double]]
        /// East, north, altitude, heading in degrees clockwise from north, speed in knots.
        var start: [Double]
        var seconds: Double
        /// True for a hand-back case: the first control step searches the whole route for its nearest point, as `Pilot` does
        /// after manual flight (otherwise the search starts at the route's first sample).
        var handback: Bool?
        /// Optional tuning for the floor sweep: the floor and the avoidance clearance, metres.
        var floor: Double?
        var clearance: Double?
    }

    struct Result: Encodable {
        var name: String
        var runLength: Double
        var seconds: Double
        var reachedEnd: Bool
        var maxAbsErrorM: Double
        var rmsErrorM: Double
        var maxAbsErrorAfter30PercentM: Double
        var rmsErrorAfter30PercentM: Double
        /// Metres along the run after which the error stays within 3 m; the run length if it never does.
        var settleDistanceM: Double
        var minClearanceM: Double
        var minWingClearanceM: Double
        var secondsInAvoidance: Double
        var collisionNudges: Int
        var minAltitudeM: Double
        var meanSpeedKt: Double
    }

    /// Closest point on a polyline: along-distance and signed lateral offset (positive to the left of travel).
    static func project(_ p: (Double, Double), _ line: [[Double]], cumulative: [Double]) -> (s: Double, err: Double) {
        var best = (s: 0.0, err: Double.infinity)
        for i in 0..<(line.count - 1) {
            let ax = line[i][0], ay = line[i][1], bx = line[i + 1][0], by = line[i + 1][1]
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { continue }
            let u = max(0, min(1, ((p.0 - ax) * dx + (p.1 - ay) * dy) / len2))
            let cx = ax + u * dx, cy = ay + u * dy
            let dist = ((p.0 - cx) * (p.0 - cx) + (p.1 - cy) * (p.1 - cy)).squareRoot()
            if dist < abs(best.err) {
                // Positive to the left of the direction of travel (east, north axes: travel (dx, dy), left (-dy, dx)).
                let side = ((p.0 - cx) * (-dy) + (p.1 - cy) * dx) >= 0 ? 1.0 : -1.0
                best = (cumulative[i] + u * len2.squareRoot(), side * dist)
            }
        }
        return best
    }

    @Test func flyTheCases() throws {
        let env = ProcessInfo.processInfo.environment
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: env["STREET_PROBE"]!)))
        let city = try CityPackage.open(directory: URL(fileURLWithPath: env["STREET_CITY"] ?? "Cities/Chicago", isDirectory: true))
        let out = URL(fileURLWithPath: env["STREET_OUT"] ?? "renders/streets", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var results: [Result] = []

        for c in cases {
            let route = Route(file: c.route)
            var t = FlightTuning()
            if let f = c.floor { t.floor = f }
            if let cl = c.clearance { t.clearance = cl }
            var cumulative = [0.0]
            for i in 1..<c.line.count {
                cumulative.append(cumulative[i - 1] + ((c.line[i][0] - c.line[i - 1][0]) * (c.line[i][0] - c.line[i - 1][0])
                                                         + (c.line[i][1] - c.line[i - 1][1]) * (c.line[i][1] - c.line[i - 1][1])).squareRoot())
            }
            let runLength = cumulative.last!
            let start = FlightState(east: c.start[0], north: c.start[1], altitude: c.start[2],
                                    heading: c.start[3] * .pi / 180, speed: c.start[4] * 0.514444)
            var sim = Simulation(start: start, tuning: t)
            var hint: Int? = c.handback == true ? nil : 0
            var track = "t,east,north,alt,speedKt,bankDeg,s,err,clearance,avoid\n"
            var window: [(s: Double, err: Double)] = []
            var minClear = Double.infinity, minWing = Double.infinity, minAlt = Double.infinity
            var avoid = 0.0, speedSum = 0.0, speedN = 0.0
            var reachedEnd = false
            let steps = Int(c.seconds / t.fixedStep)
            for k in 0..<steps {
                sim.advance(by: t.fixedStep, obstacles: city, extent: city.manifest.extentM) { s, _ in
                    let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t)
                    hint = r.index
                    return r.control
                }
                let s = sim.current
                if sim.proximityWarning { avoid += t.fixedStep }
                let p = Self.project((s.east, s.north), c.line, cumulative: cumulative)
                let here = Double(city.obstacleHeight(east: s.east, north: s.north))
                var wing = here
                for (dx, dy) in [(6.0, 0.0), (-6, 0), (0, 6), (0, -6)] {
                    wing = max(wing, Double(city.obstacleHeight(east: s.east + dx, north: s.north + dy)))
                }
                if p.s > 0, p.s < runLength - 1, abs(p.err) < 150 {
                    window.append((p.s, p.err))
                    minClear = min(minClear, s.altitude - here)
                    minWing = min(minWing, s.altitude - wing)
                    minAlt = min(minAlt, s.altitude)
                    speedSum += s.speed / 0.514444
                    speedN += 1
                }
                // The end counts only after the aircraft has been on the run (a hand-back may start far from it).
                if !window.isEmpty && p.s >= runLength - 1 { reachedEnd = true }
                if k % 12 == 0 {
                    track += String(format: "%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.2f,%.1f,%d\n", Double(k) * t.fixedStep, s.east, s.north,
                                    s.altitude, s.speed / 0.514444, s.bank * 180 / .pi, p.s, p.err, s.altitude - here, sim.proximityWarning ? 1 : 0)
                }
                if reachedEnd && p.s >= runLength - 1 { break }
            }
            let later = window.filter { $0.s >= 0.3 * runLength }
            func stats(_ w: [(s: Double, err: Double)]) -> (max: Double, rms: Double) {
                guard !w.isEmpty else { return (.nan, .nan) }
                return (w.map { abs($0.err) }.max()!, (w.reduce(0) { $0 + $1.err * $1.err } / Double(w.count)).squareRoot())
            }
            // Settled: the last window sample whose error was above 3 m gives the distance after which it stays inside.
            let lastOut = window.last(where: { abs($0.err) > 3 })
            let settle = lastOut?.s ?? 0
            let all = stats(window), after = stats(later)
            results.append(Result(name: c.name, runLength: runLength, seconds: Double(window.count) * t.fixedStep, reachedEnd: reachedEnd,
                                  maxAbsErrorM: all.max, rmsErrorM: all.rms, maxAbsErrorAfter30PercentM: after.max, rmsErrorAfter30PercentM: after.rms,
                                  settleDistanceM: settle, minClearanceM: minClear, minWingClearanceM: minWing,
                                  secondsInAvoidance: avoid, collisionNudges: sim.nudges, minAltitudeM: minAlt,
                                  meanSpeedKt: speedN > 0 ? speedSum / speedN : 0))
            try track.write(to: out.appendingPathComponent("\(c.name).csv"), atomically: true, encoding: .utf8)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try enc.encode(results).write(to: out.appendingPathComponent("results.json"))
    }
}
