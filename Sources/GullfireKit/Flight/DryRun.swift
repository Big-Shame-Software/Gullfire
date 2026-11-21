import Foundation

/// One stretch of a dry run in which a warning was on, or one collision nudge.
public struct DryRunEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case avoidance, boundary, nudge }
    public var kind: Kind
    /// The route index the autopilot reported when the event began.
    public var routeIndex: Int
    /// Seconds into the flight when the event began.
    public var time: Double
    /// Seconds the event lasted (0 for a nudge).
    public var duration: Double
}

/// What a dry run found over one flight.
public struct DryRunReport: Sendable, Equatable {
    /// Simulated flight time.
    public var seconds: Double
    /// Sorted by start time.
    public var events: [DryRunEvent]
    public var nudges: Int
    public var avoidanceSeconds: Double
    /// m/s2: the second difference of altitude at 0.1 s, from 1.5 s on.
    public var maxVerticalAcceleration: Double

    public var isClean: Bool { events.isEmpty && nudges == 0 }
    public var avoidanceEvents: [DryRunEvent] { events.filter { $0.kind == .avoidance } }
}

/// A warning that is on at the moment, not yet closed into an event.
private struct OpenRun {
    var routeIndex: Int
    var first: Int
    var last: Int
}

public enum DryRun {
    /// The longest flight a dry run simulates, seconds.
    public static let maxSeconds = 400.0
    /// Spacing of the altitude samples for the vertical acceleration, seconds.
    static let sampleInterval = 0.1
    /// Vertical acceleration is not measured before this: the simulator starts level.
    static let startWindow = 1.5

    /// Flies `route` headless on a copy of the simulator with the real autopilot, from the route's first sample (heading to the
    /// second), for `seconds` (default: one lap at the route's own first-sample speed, plus 10 s, at most 400 s). Groups
    /// consecutive steps with the avoidance warning on into ONE event (same for the boundary warning); a collision nudge is its
    /// own event. Pure: no state, same inputs give the same report.
    public static func fly(route: Route, obstacles: ObstacleSource, extent: Manifest.Extent, tuning: FlightTuning = FlightTuning(),
                           heightOffset: Double = 0, seconds: Double? = nil) -> DryRunReport {
        let t = tuning
        guard route.count >= 2 else {
            return DryRunReport(seconds: 0, events: [], nudges: 0, avoidanceSeconds: 0, maxVerticalAcceleration: 0)
        }
        let a = route.samples[0], b = route.samples[1]
        let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)

        let requested = seconds ?? (route.length / max(a.speed, 1) + 10)
        let steps = Int((min(max(requested, 0), maxSeconds) / t.fixedStep).rounded())

        var sim = Simulation(start: start, tuning: t)
        var hint: Int? = 0
        var index = 0
        let roofs: RoofCache? = heightOffset < 0 ? RoofCache(count: route.count) : nil
        let every = max(1, Int((sampleInterval / t.fixedStep).rounded()))

        var events: [DryRunEvent] = []
        var avoidanceSteps = 0
        var avoidanceRun: OpenRun?
        var boundaryRun: OpenRun?
        var altitudes = [start.altitude]

        func close(_ run: inout OpenRun?, _ kind: DryRunEvent.Kind) {
            guard let r = run else { return }
            events.append(DryRunEvent(kind: kind, routeIndex: r.routeIndex, time: Double(r.first) * t.fixedStep,
                                      duration: Double(r.last - r.first + 1) * t.fixedStep))
            run = nil
        }
        func track(_ run: inout OpenRun?, _ kind: DryRunEvent.Kind, active: Bool, step: Int) {
            if active {
                if run != nil {
                    run?.last = step
                } else {
                    run = OpenRun(routeIndex: index, first: step, last: step)
                }
            } else {
                close(&run, kind)
            }
        }

        for step in stride(from: 1, through: steps, by: 1) {
            let nudgesBefore = sim.nudges
            sim.advance(by: t.fixedStep, obstacles: obstacles, extent: extent) { s, _ in
                let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t, heightOffset: heightOffset,
                                          obstacles: obstacles, roofs: roofs)
                hint = r.index
                index = r.index
                return r.control
            }

            if sim.nudges > nudgesBefore {
                events.append(DryRunEvent(kind: .nudge, routeIndex: index, time: Double(step) * t.fixedStep, duration: 0))
            }
            if sim.proximityWarning { avoidanceSteps += 1 }
            track(&avoidanceRun, .avoidance, active: sim.proximityWarning, step: step)
            track(&boundaryRun, .boundary, active: sim.boundaryWarning, step: step)

            if step % every == 0 {
                altitudes.append(sim.current.altitude)
            }
        }
        close(&avoidanceRun, .avoidance)
        close(&boundaryRun, .boundary)
        events.sort { ($0.time, $0.kind.rawValue) < ($1.time, $1.kind.rawValue) }

        var maxAz = 0.0
        if altitudes.count >= 3 {
            for k in 1..<(altitudes.count - 1) where Double(k) * sampleInterval >= startWindow {
                let az = abs(altitudes[k + 1] - 2 * altitudes[k] + altitudes[k - 1]) / (sampleInterval * sampleInterval)
                maxAz = max(maxAz, az)
            }
        }

        return DryRunReport(seconds: Double(steps) * t.fixedStep, events: events, nudges: sim.nudges,
                            avoidanceSeconds: Double(avoidanceSteps) * t.fixedStep, maxVerticalAcceleration: maxAz)
    }
}
