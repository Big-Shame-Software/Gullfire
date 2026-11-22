import Foundation
import Testing
@testable import GullfireKit

/// Entry sweep: a headless sweep of the endless-flight entry (U, or a street click) over the Loop, for hand-back diagnosis.
/// Each start is flown for 30 s (GULLFIRE_ENTRY_SWEEP_SECONDS) as a forced hand-back, then the chase; it reports nudges,
/// clearances (aircraft and wing points), phases, the start-state feasibility gradient, and one TSV row per start. Off unless
/// GULLFIRE_ENTRY_SWEEP=1. Other env: GULLFIRE_ENTRY_SWEEP_STEP=<m> (grid, default 250), _LIMIT=<n> (first n starts),
/// _BASE=package (package maximum + 80 m instead of tallest-within-100 m + 60/80/100), _OUT=<path> (TSV),
/// _TRACE=<index,...> (0.5 s traces) with _TRACE_STRIDE=<steps>. Release only (swift test -c release -Xswiftc -enable-testing):
/// the 1,176-start 30 s run takes about 20 to 50 s there (in debug it is over an hour). Progress goes to stderr every 50 starts.
enum EntrySweep {
    static let enabled = ProcessInfo.processInfo.environment["GULLFIRE_ENTRY_SWEEP"] == "1"
    static let packageBase = ProcessInfo.processInfo.environment["GULLFIRE_ENTRY_SWEEP_BASE"] == "package"
    /// Start altitudes above the tallest obstacle within 100 m of the start (or above the package maximum, in package mode).
    static let aboveRoof: [Double] = packageBase ? [80] : [60, 80, 100]
    static let headingsDeg: [Double] = (0..<8).map { Double($0) * 45 }
    /// Start grid: within 1 km of the package origin (the Loop).
    static let gridRadius = 1000.0
    static let spacing = Double(ProcessInfo.processInfo.environment["GULLFIRE_ENTRY_SWEEP_STEP"] ?? "") ?? 250.0
    static let seconds = Double(ProcessInfo.processInfo.environment["GULLFIRE_ENTRY_SWEEP_SECONDS"] ?? "") ?? 30.0
    static let speed = 40.0
    static let workers = 8
    /// The loop flown is the first endless loop from this seed (the seed the existing entry tests use).
    static let seed: UInt64 = 7
    /// Starts with a nudge or a clearance under this are printed.
    static let flagBelow = 15.0
    /// Feasibility: the largest gradient the start can be asked to climb, and the 15 m clearance the test asks for.
    static let maxFeasibleGradient = 0.30
    static let requiredClearance = 15.0
    static let feasibilityAhead = 800.0
    static let feasibilityHalfWidth = 6.0
    static let phases = ["climb start", "climb", "join", "settle", "route"]
    /// Starts to trace (GULLFIRE_ENTRY_TRACE=<index>[,<index>...]): one line every 0.5 s, plus the step of any nudge.
    /// Trace every this many steps (GULLFIRE_ENTRY_TRACE_STRIDE, default 60 = every 0.5 s).
    static let traceStride = Int(ProcessInfo.processInfo.environment["GULLFIRE_ENTRY_TRACE_STRIDE"] ?? "") ?? 60
    static let traceSet: Set<Int> = Set((ProcessInfo.processInfo.environment["GULLFIRE_ENTRY_TRACE"] ?? "")
        .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })

    /// The tallest obstacle along a line from a point, sampled every 5 m out to `length`, and the distance at which it is tallest.
    static func tallestAlong(east: Double, north: Double, bearing: Double, length: Double, city: CityPackage) -> (height: Double, at: Double) {
        var best = (height: 0.0, at: 0.0)
        var d = 0.0
        while d <= length {
            let h = Double(city.obstacleHeight(east: east + d * sin(bearing), north: north + d * cos(bearing)))
            if h > best.height { best = (h, d) }
            d += 5
        }
        return best
    }

    /// One trace line: the aircraft, the hand-back's state, the climb and transit heights it aims at (recomputed from the same
    /// expressions as `Autopilot.handBackControl`, with the same `Autopilot.roofHeight`), the join point, and the obstacles.
    static func traceLine(index: Int, t: Double, phase: String, s: FlightState, hb: HandBack?, lastAim: Int?, control: ControlInput,
                          boost: Double, route: Route, city: CityPackage, tag: String) -> String {
        let h = s.heading
        // Climb: `need` = roofs within 30 m, then the largest roof within 20 m of each point 20...800 m along the HELD heading
        // (hb.heading, which handBackControl drifts each step), + 30.
        var climbNeed = Double.nan
        if let held = hb?.heading, hb?.phase == .climb {
            var need = Autopilot.roofHeight(east: s.east, north: s.north, radius: 30, obstacles: city)
            var d = 20.0
            while d <= 800 {
                need = max(need, Autopilot.roofHeight(east: s.east + d * sin(held), north: s.north + d * cos(held), radius: 20, obstacles: city))
                d += 20
            }
            climbNeed = need + 30
        }
        // Transit: the aim is `hb.aimIndex` (or the last one set); `need` starts at the aim's altitude and takes the largest
        // roof within 20 m + 30 at every 20 m of the straight line to the aim.
        var joinPart = "join none"
        var lineText = "line to join n/a"
        var transitNeed = Double.nan
        if let idx = hb?.aimIndex ?? lastAim {
            let a = route.samples[idx]
            let dE = a.east - s.east, dN = a.north - s.north
            let dist = (dE * dE + dN * dN).squareRoot()
            let bearing = atan2(dE, dN)
            var need = a.altitude
            var d = 0.0
            while d < dist {
                need = max(need, Autopilot.roofHeight(east: s.east + d * sin(bearing), north: s.north + d * cos(bearing), radius: 20, obstacles: city) + 30)
                d += 20
            }
            transitNeed = need
            let along = tallestAlong(east: s.east, north: s.north, bearing: bearing, length: min(dist, 1000), city: city)
            lineText = String(format: "line to join: tallest %.1f m at %.0f m", along.height, along.at)
            joinPart = String(format: "join idx %d E %.1f N %.1f alt %.1f dist %.1f bearing %.1f", idx, a.east, a.north, a.altitude, dist, bearing * 180 / .pi)
        }
        // Chase (no hand-back): the aim point the route chase uses, with the entry boost.
        var chasePart = "chase n/a"
        if hb == nil {
            let here = route.nearestIndex(east: s.east, north: s.north)
            let ahead = Int((Autopilot.lookahead(speed: s.speed) / route.spacing).rounded())
            let target = (here + ahead) % route.count
            let aim = route.samples[target]
            chasePart = String(format: "chase aim idx %d E %.1f N %.1f alt %.1f + boost %.1f", target, aim.east, aim.north, aim.altitude, boost)
        }
        let hbText = hb.map { $0.phase == .climb ? "hb climb hdg-held \(String(format: "%.1f", $0.heading * 180 / .pi))" : "hb transit" } ?? "hb none"
        let h50 = tallest(within: 50, east: s.east, north: s.north, city: city)
        let ahead800 = tallestAlong(east: s.east, north: s.north, bearing: h, length: 800, city: city)
        let core = String(format: "t %5.1f | E %7.1f N %7.1f alt %6.1f hdg %6.1f pitch %+5.1f bank %+5.1f speed %4.1f | cmd pitch %+5.1f roll %+5.2f | boost %4.1f | climb need %6.1f transit need %6.1f",
                          t, s.east, s.north, s.altitude, h * 180 / .pi, s.pitch * 180 / .pi, s.bank * 180 / .pi, s.speed,
                          control.pitch * FlightTuning().pitchLimit * 180 / .pi, control.roll, boost, climbNeed, transitNeed)
        let obst = String(format: "tallest within 50 m %.1f | heading 800 m: tallest %.1f at %.0f m", h50, ahead800.height, ahead800.at)
        return "TRACE \(index) \(phase) \(tag) | \(core) | \(hbText) | \(joinPart) | \(lineText) | \(chasePart) | \(obst)"
    }

    /// The minimum seen over a start, with what the aircraft was doing then.
    struct Extreme: Sendable {
        var clear = Double.infinity
        var t = 0.0
        var phase = ""
        var pitchDeg = 0.0
        var vs = 0.0
        var obstH = 0.0
        /// Whether Avoidance was already predicting an obstacle at that step.
        var warning = false
        /// Metres from where the warning first came on (this episode) to the minimum, along the heading then. nil when not warning.
        var ahead: Double? = nil
    }

    /// The first step where the lowest clearance (aircraft or wing point) fell under 15 m, and the first obstacle ahead on the
    /// heading then that stands above altitude minus 15 m.
    struct Crossing: Sendable {
        var t: Double
        var phase: String
        var clear: Double
        var obstH: Double
        var distanceAhead: Double?
        var distanceObstH: Double?
    }

    /// Commands and attitude at one step, kept for the three seconds before a nudge.
    struct Step: Sendable {
        var t: Double
        var phase: String
        var cmdPitchDeg: Double
        var pitchDeg: Double
    }

    struct TraceLine: Sendable {
        let t: Double
        let text: String
    }

    struct Row: Sendable {
        var index: Int
        var east: Double
        var north: Double
        var aboveRoof: Double
        var headingDeg: Double
        var roofNear: Double
        var altitude: Double
        var maxGradient = 0.0
        var nudges = 0
        var firstNudgeT: Double? = nil
        var firstNudgePhase = ""
        var nudgesByPhase: [String: Int] = [:]
        /// The three seconds before the first nudge: steps at 3, 2 and 1 s before it, nearest to each.
        var preNudge: [Step] = []
        var crossing: Crossing? = nil
        /// Lowest of: the aircraft's own point, and the two wing points (a wing margin either side, across the heading).
        var all = Extreme()
        /// The aircraft's own point only.
        var centre = Extreme()
        /// Lowest of the two wing points only.
        var wing = Extreme()
        /// Trace lines (only for traced starts).
        var trace: [TraceLine] = []
        /// Time the hand-back ended (the end of the transit), nil if it never ran.
        var handBackEnd: Double? = nil
        /// Highest altitude reached during the 30 s.
        var maxAltitude = 0.0

        var feasible: Bool { maxGradient <= EntrySweep.maxFeasibleGradient }
    }

    struct Job: Sendable {
        let index: Int
        let east, north, aboveRoof, headingDeg: Double
        /// The base height for the start altitude (package maximum in package mode); nil for tallest-within-100 m.
        let base: Double?
    }

    /// Start points: the square grid, kept where it lies within the radius.
    static func startPoints() -> [(east: Double, north: Double)] {
        let k = Int((gridRadius / spacing).rounded())
        var out: [(east: Double, north: Double)] = []
        for i in -k...k {
            for j in -k...k {
                let e = Double(i) * spacing, n = Double(j) * spacing
                if e * e + n * n <= gridRadius * gridRadius { out.append((e, n)) }
            }
        }
        return out
    }

    static func jobs(packageMax: Double?) -> [Job] {
        var out: [Job] = []
        for p in startPoints() {
            for above in aboveRoof {
                for h in headingsDeg {
                    out.append(Job(index: out.count, east: p.east, north: p.north, aboveRoof: above, headingDeg: h, base: packageMax))
                }
            }
        }
        return out
    }

    /// The tallest obstacle in the package, read at every cell centre of the obstacle grid.
    static func packageMaximum(city: CityPackage) -> Double {
        let g = city.manifest.obstacleGrid
        var m = 0.0
        for i in 0..<g.cols {
            for j in 0..<g.rows {
                let e = g.minEast + (Double(i) + 0.5) * g.cellSizeM
                let n = g.minNorth + (Double(j) + 0.5) * g.cellSizeM
                m = max(m, Double(city.obstacleHeight(east: e, north: n)))
            }
        }
        return m
    }

    /// The tallest obstacle within `radius` of a point, read on a 5 m grid.
    static func tallest(within radius: Double, east: Double, north: Double, city: CityPackage) -> Double {
        var tallest = 0.0
        var dx = -radius
        while dx <= radius {
            var dy = -radius
            while dy <= radius {
                if dx * dx + dy * dy <= radius * radius {
                    tallest = max(tallest, Double(city.obstacleHeight(east: east + dx, north: north + dy)))
                }
                dy += 5
            }
            dx += 5
        }
        return tallest
    }

    /// The largest gradient needed to clear the obstacles ahead: (height + 15 m - start altitude) / distance, over every grid cell
    /// within 800 m ahead along the heading and 6 m either side of it (lateral samples at 1 m).
    static func maxRequiredGradient(east: Double, north: Double, heading: Double, altitude: Double, city: CityPackage) -> Double {
        let cell = city.manifest.obstacleGrid.cellSizeM
        var worst = -Double.infinity
        var d = cell
        while d <= feasibilityAhead {
            var lat = -feasibilityHalfWidth
            while lat <= feasibilityHalfWidth {
                let e = east + d * sin(heading) + lat * cos(heading)
                let n = north + d * cos(heading) - lat * sin(heading)
                let h = Double(city.obstacleHeight(east: e, north: n))
                worst = max(worst, (h + requiredClearance - altitude) / d)
                lat += 1
            }
            d += cell
        }
        return worst
    }

    /// One start: the entry flown for `seconds`, one fixed step at a time.
    static func fly(_ job: Job, route: Route, city: CityPackage) -> Row {
        let t = FlightTuning()
        let roof = tallest(within: 100, east: job.east, north: job.north, city: city)
        let base = job.base ?? roof
        let heading = job.headingDeg * .pi / 180
        let start = FlightState(east: job.east, north: job.north, altitude: base + job.aboveRoof, heading: heading, speed: speed)
        var row = Row(index: job.index, east: job.east, north: job.north, aboveRoof: job.aboveRoof, headingDeg: job.headingDeg,
                      roofNear: roof, altitude: start.altitude)
        row.maxGradient = maxRequiredGradient(east: job.east, north: job.north, heading: heading, altitude: start.altitude, city: city)
        var sim = Simulation(start: start, tuning: t)
        var hb: HandBack? = HandBack(heading: start.heading)
        var hint: Int? = nil
        var endedAt: Double? = nil
        var warnPrev = false
        var edge: (east: Double, north: Double, heading: Double)? = nil
        let extent = city.manifest.extentM
        let wm = t.wingMargin
        var history: [Step] = []
        let traced = EntrySweep.traceSet.contains(job.index)
        var lastAim: Int? = nil
        let cell = city.manifest.obstacleGrid.cellSizeM

        for k in 0..<Int((seconds / t.fixedStep).rounded()) {
            let before = Double(k) * t.fixedStep
            let tNow = Double(k + 1) * t.fixedStep
            let s0 = sim.current

            // The phase this step is flown in, read before the hand-back can end.
            let phase: String
            if let w = hb {
                phase = w.phase == .climb ? (before < 3 ? "climb start" : "climb") : "join"
            } else if let e = endedAt, before - e < 60 {
                phase = "settle"
            } else {
                phase = "route"
            }

            var boostUsed = 0.0
            let hbBefore = hb
            let control: ControlInput
            let wasHandBack = hb != nil
            if hb != nil, let r = Autopilot.handBackControl(for: s0, route: route, obstacles: city, state: &hb, tuning: t) {
                hint = r.index
                control = r.control
            } else {
                // A hand-back that ended on this step: the entry boost counts from its end.
                if wasHandBack, endedAt == nil { endedAt = before; row.handBackEnd = before }
                let boost = endedAt.map { Autopilot.entryBoost(secondsSinceHandBack: before - $0) } ?? 0
                boostUsed = boost
                let r = Autopilot.control(for: s0, route: route, hint: hint, tuning: t, heightOffset: boost, obstacles: city)
                hint = r.index
                control = r.control
            }

            if let a = hbBefore?.aimIndex ?? hb?.aimIndex { lastAim = a }
            let n0 = sim.nudges
            sim.tick(control: control, obstacles: city, extent: extent)
            let s = sim.current
            row.maxAltitude = max(row.maxAltitude, s.altitude)
            if traced, k % EntrySweep.traceStride == 0 || sim.nudges > n0 {
                let text = EntrySweep.traceLine(index: job.index, t: before, phase: phase, s: s0, hb: hbBefore, lastAim: lastAim,
                                                control: control, boost: boostUsed, route: route, city: city,
                                                tag: sim.nudges > n0 ? "NUDGE" : "tick")
                row.trace.append(EntrySweep.TraceLine(t: before, text: text))
            }
            // The pilot or autopilot command before avoidance, as degrees (the command is -1 to 1 of the pitch limit).
            history.append(Step(t: tNow, phase: phase, cmdPitchDeg: control.pitch * t.pitchLimit * 180 / .pi,
                                pitchDeg: s.pitch * 180 / .pi))
            if sim.nudges > n0 {
                if row.firstNudgeT == nil {
                    row.firstNudgeT = tNow
                    row.firstNudgePhase = phase
                    // The three seconds before this nudge, nearest step to each.
                    row.preNudge = [3.0, 2.0, 1.0].compactMap { back in
                        let target = tNow - back
                        return history.dropLast().min { abs($0.t - target) < abs($1.t - target) }
                    }
                }
                row.nudgesByPhase[phase, default: 0] += sim.nudges - n0
            }

            // The warning: when it first comes on, that is where the obstacle was first predicted.
            let warn = sim.proximityWarning
            if warn && !warnPrev { edge = (s.east, s.north, s.heading) }
            if !warn { edge = nil }
            warnPrev = warn

            // Clearances: the aircraft's own point, and a wing margin either side, across the heading.
            let vs = (s.altitude - sim.previous.altitude) / t.fixedStep
            let h0 = Double(city.obstacleHeight(east: s.east, north: s.north))
            let rx = cos(s.heading) * wm, ry = -sin(s.heading) * wm
            let hL = Double(city.obstacleHeight(east: s.east + rx, north: s.north + ry))
            let hR = Double(city.obstacleHeight(east: s.east - rx, north: s.north - ry))
            let cWing = min(s.altitude - hL, s.altitude - hR)
            let hWing = (s.altitude - hL) <= (s.altitude - hR) ? hL : hR
            let c0 = s.altitude - h0
            let (cAll, hAll) = c0 <= cWing ? (c0, h0) : (cWing, hWing)

            func consider(_ x: inout Extreme, clear: Double, obstH: Double) {
                guard clear < x.clear else { return }
                x.clear = clear
                x.t = tNow
                x.phase = phase
                x.pitchDeg = s.pitch * 180 / .pi
                x.vs = vs
                x.obstH = obstH
                x.warning = warn
                if warn, let e = edge {
                    x.ahead = (s.east - e.east) * sin(e.heading) + (s.north - e.north) * cos(e.heading)
                } else {
                    x.ahead = nil
                }
            }
            consider(&row.all, clear: cAll, obstH: hAll)
            consider(&row.centre, clear: c0, obstH: h0)
            consider(&row.wing, clear: cWing, obstH: hWing)

            // The first crossing under 15 m (aircraft or wing point): the first obstacle ahead on the heading that stands above
            // altitude minus 15 m, searched out to 300 m from the aircraft at that step.
            if row.crossing == nil && cAll < EntrySweep.flagBelow {
                var dAhead: Double? = nil, hAhead: Double? = nil
                var d = 0.0
                while d <= 300 {
                    let h = Double(city.obstacleHeight(east: s.east + d * sin(s.heading), north: s.north + d * cos(s.heading)))
                    if h > s.altitude - EntrySweep.flagBelow { dAhead = d; hAhead = h; break }
                    d += cell
                }
                row.crossing = Crossing(t: tNow, phase: phase, clear: cAll, obstH: hAll,
                                        distanceAhead: dAhead, distanceObstH: hAhead)
            }
        }
        row.nudges = sim.nudges
        return row
    }

    static func tsvHeader() -> String {
        ["index", "east", "north", "above_roof_m", "heading_deg", "roof_near_m", "start_alt_m", "max_gradient", "verdict", "nudges",
         "first_nudge_t", "first_nudge_phase", "pre_nudge_3_2_1_s",
         "clear_m", "clear_t", "clear_phase", "clear_pitch_deg", "clear_vs", "clear_obst_m", "clear_warning", "clear_ahead_m",
         "centre_clear_m", "centre_t", "centre_phase", "centre_pitch_deg", "centre_obst_m",
         "wing_clear_m", "wing_t", "wing_phase", "wing_pitch_deg", "wing_vs", "wing_obst_m", "wing_warning", "wing_ahead_m",
         "cross_t", "cross_phase", "cross_clear_m", "cross_obst_m", "cross_hit_dist_ahead_m", "cross_hit_obst_m", "handback_end_t", "max_alt_m"].joined(separator: "\t")
    }

    static func tsv(_ r: Row) -> String {
        func f(_ x: Double) -> String { String(format: "%.2f", x) }
        func opt(_ x: Double?) -> String { x.map { f($0) } ?? "-" }
        let pre = r.preNudge.map { String(format: "%@:%.1f/%.1f", $0.phase, $0.cmdPitchDeg, $0.pitchDeg) }.joined(separator: ";")
        let c = r.crossing
        return [String(r.index), f(r.east), f(r.north), f(r.aboveRoof), f(r.headingDeg), f(r.roofNear), f(r.altitude),
                String(format: "%.3f", r.maxGradient), r.feasible ? "FEASIBLE" : "INFEASIBLE",
                String(r.nudges), opt(r.firstNudgeT), r.firstNudgePhase.isEmpty ? "-" : r.firstNudgePhase, pre.isEmpty ? "-" : pre,
                f(r.all.clear), f(r.all.t), r.all.phase, f(r.all.pitchDeg), f(r.all.vs), f(r.all.obstH), String(r.all.warning), opt(r.all.ahead),
                f(r.centre.clear), f(r.centre.t), r.centre.phase, f(r.centre.pitchDeg), f(r.centre.obstH),
                f(r.wing.clear), f(r.wing.t), r.wing.phase, f(r.wing.pitchDeg), f(r.wing.vs), f(r.wing.obstH), String(r.wing.warning), opt(r.wing.ahead),
                c.map { f($0.t) } ?? "-", c?.phase ?? "-", c.map { f($0.clear) } ?? "-", c.map { f($0.obstH) } ?? "-",
                c.map { opt($0.distanceAhead) } ?? "-", c.map { opt($0.distanceObstH) } ?? "-", opt(r.handBackEnd), f(r.maxAltitude)]
            .joined(separator: "\t")
    }

    static func line(_ r: Row) -> String {
        let ahead = r.all.ahead.map { String(format: "%.0f m ahead", $0) } ?? "not predicted at the minimum"
        let first = r.firstNudgeT.map { String(format: "first at %.1f s (%@)", $0, r.firstNudgePhase) } ?? "no nudge"
        return String(format: "ENTRY SWEEP %4d | %@ grad %.3f | E %6.0f N %6.0f | +%3.0f m | hdg %3.0f | alt %6.1f | nudges %2d (%@) | clearance %7.2f m at %5.1f s, %@, pitch %+5.1f deg, vs %+5.1f m/s, obstacle %5.1f m, %@ | centre %7.2f m at %5.1f s, %@ | wing %7.2f m at %5.1f s, %@",
                      r.index, r.feasible ? "FEASIBLE  " : "INFEASIBLE", r.maxGradient, r.east, r.north, r.aboveRoof, r.headingDeg, r.altitude,
                      r.nudges, first, r.all.clear, r.all.t, r.all.phase, r.all.pitchDeg, r.all.vs, r.all.obstH, ahead,
                      r.centre.clear, r.centre.t, r.centre.phase, r.wing.clear, r.wing.t, r.wing.phase)
    }

    static func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

@Suite("Entry sweep over the Loop", .enabled(if: EntrySweep.enabled && EnginePackages.available))
struct EntrySweepTests {
    @Test func sweepTheEntryFromTheGrid() async throws {
        guard let dir = EnginePackages.dirs.first else {
            print("ENTRY SWEEP skipped: Cities/Chicago is missing")
            return
        }
        let began = Date()
        let city = try CityPackage.open(directory: dir)
        var flight = try #require(EndlessFlight(city: city, seed: EntrySweep.seed))
        let made = flight.nextLoop()
        let loop = try #require(made)
        let route = loop.route
        let packageMax = EntrySweep.packageBase ? EntrySweep.packageMaximum(city: city) : nil

        var jobs = EntrySweep.jobs(packageMax: packageMax)
        if let limit = Int(ProcessInfo.processInfo.environment["GULLFIRE_ENTRY_SWEEP_LIMIT"] ?? ""), limit < jobs.count {
            jobs = Array(jobs.prefix(limit))
        }
        let baseText = packageMax.map { String(format: "package maximum %.1f m + %.0f m", $0, EntrySweep.aboveRoof[0]) }
            ?? "tallest within 100 m + \(EntrySweep.aboveRoof.map { Int($0) }) m"
        print("ENTRY SWEEP: \(jobs.count) starts (\(EntrySweep.startPoints().count) grid points at \(Int(EntrySweep.spacing)) m step within \(Int(EntrySweep.gridRadius)) m x \(EntrySweep.aboveRoof.count) heights x \(EntrySweep.headingsDeg.count) headings), start altitude \(baseText), \(Int(EntrySweep.seconds)) s each, \(EntrySweep.workers) at a time, loop from seed \(EntrySweep.seed) with \(route.count) samples")

        // Rows go to the TSV as each start completes (the test task alone writes it).
        var handle: FileHandle? = nil
        if let out = ProcessInfo.processInfo.environment["GULLFIRE_ENTRY_SWEEP_OUT"] {
            FileManager.default.createFile(atPath: out, contents: Data((EntrySweep.tsvHeader() + "\n").utf8))
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
            try handle?.seekToEnd()
        }

        var rows: [EntrySweep.Row] = []
        var next = 0
        await withTaskGroup(of: EntrySweep.Row.self) { group in
            while next < min(EntrySweep.workers, jobs.count) {
                let job = jobs[next]
                next += 1
                group.addTask { EntrySweep.fly(job, route: route, city: city) }
            }
            while let row = await group.next() {
                rows.append(row)
                try? handle?.write(contentsOf: Data((EntrySweep.tsv(row) + "\n").utf8))
                if rows.count % 50 == 0 {
                    EntrySweep.say(String(format: "ENTRY SWEEP progress %d/%d starts, %.0f s elapsed", rows.count, jobs.count, Date().timeIntervalSince(began)))
                }
                if next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask { EntrySweep.fly(job, route: route, city: city) }
                }
            }
        }
        try? handle?.close()
        rows.sort { $0.index < $1.index }
        // Traces: the 15 s before each traced start's first nudge (the whole flight if it has none).
        for r in rows where EntrySweep.traceSet.contains(r.index) {
            let end = r.firstNudgeT ?? Double.infinity
            let begin = r.firstNudgeT.map { $0 - 15 } ?? 0
            let nudgeText = r.firstNudgeT.map { String(format: "%.2f s (%@)", $0, r.firstNudgePhase) } ?? "none"
            print("TRACE START \(r.index): hdg \(Int(r.headingDeg)) +\(Int(r.aboveRoof)) m, E \(Int(r.east)) N \(Int(r.north)), start alt \(String(format: "%.1f", r.altitude)), first nudge \(nudgeText), trace window \(String(format: "%.1f", begin))-\(r.firstNudgeT.map { String(format: "%.1f", $0) } ?? "30.0") s")
            for l in r.trace where l.t >= begin && l.t <= end { print(l.text) }
        }
        let elapsed = Date().timeIntervalSince(began)

        let feasible = rows.filter { $0.feasible }
        let infeasible = rows.filter { !$0.feasible }

        // Feasible starts: one line each for a nudge or a clearance under 15 m (centre or wing).
        print("ENTRY SWEEP FEASIBLE: one line per start with a nudge or a centre or wing clearance under \(Int(EntrySweep.flagBelow)) m")
        for r in feasible where r.nudges > 0 || r.centre.clear < EntrySweep.flagBelow || r.wing.clear < EntrySweep.flagBelow {
            print(EntrySweep.line(r))
        }
        // Infeasible starts: counts only, no per-start lines.

        func count(_ rs: [EntrySweep.Row], _ p: (EntrySweep.Row) -> Bool) -> Int { rs.filter(p).count }
        let nudgedF = count(feasible) { $0.nudges > 0 }
        let centreLowF = count(feasible) { $0.centre.clear < EntrySweep.flagBelow }
        let wingLowF = count(feasible) { $0.wing.clear < EntrySweep.flagBelow }
        print("ENTRY SWEEP SUMMARY (all starts): \(rows.count) starts, FEASIBLE \(feasible.count), INFEASIBLE \(infeasible.count)")
        print("ENTRY SWEEP SUMMARY (FEASIBLE): starts \(feasible.count), with a nudge \(nudgedF), total nudges \(feasible.reduce(0) { $0 + $1.nudges }), centre-only clearance under \(Int(EntrySweep.flagBelow)) m \(centreLowF), wing clearance under \(Int(EntrySweep.flagBelow)) m \(wingLowF)")
        print(String(format: "ENTRY SWEEP SUMMARY (FEASIBLE): lowest centre-only clearance %.2f m, lowest wing clearance %.2f m",
                     feasible.map { $0.centre.clear }.min() ?? .nan, feasible.map { $0.wing.clear }.min() ?? .nan))
        print("ENTRY SWEEP SUMMARY (INFEASIBLE): starts \(infeasible.count), with a nudge \(count(infeasible) { $0.nudges > 0 }), centre-only clearance under \(Int(EntrySweep.flagBelow)) m \(count(infeasible) { $0.centre.clear < EntrySweep.flagBelow }), wing clearance under \(Int(EntrySweep.flagBelow)) m \(count(infeasible) { $0.wing.clear < EntrySweep.flagBelow })")
        func median(_ xs: [Double]) -> Double { let v = xs.sorted(); return v.isEmpty ? .nan : v[v.count / 2] }
        let endsAll = rows.compactMap { $0.handBackEnd }
        let endsFeas = feasible.compactMap { $0.handBackEnd }
        print(String(format: "ENTRY SWEEP JOIN TIME (start to end of transit, s): all starts median %.1f max %.1f (n %d); FEASIBLE median %.1f max %.1f (n %d)",
                     median(endsAll), endsAll.max() ?? .nan, endsAll.count, median(endsFeas), endsFeas.max() ?? .nan, endsFeas.count))
        print(String(format: "ENTRY SWEEP MAX ALTITUDE (m, highest over 30 s): all starts median %.1f max %.1f; FEASIBLE median %.1f max %.1f",
                     median(rows.map { $0.maxAltitude }), rows.map { $0.maxAltitude }.max() ?? .nan,
                     median(feasible.map { $0.maxAltitude }), feasible.map { $0.maxAltitude }.max() ?? .nan))
        print("ENTRY SWEEP FEASIBLE PHASE | phase | first nudges | lowest combined clearance phase | lowest centre phase | lowest wing phase")
        for p in EntrySweep.phases {
            print("ENTRY SWEEP FEASIBLE PHASE | \(p) | \(count(feasible) { $0.firstNudgePhase == p }) | \(count(feasible) { $0.all.phase == p }) | \(count(feasible) { $0.centre.phase == p }) | \(count(feasible) { $0.wing.phase == p })")
        }
        print("ENTRY SWEEP FEASIBLE NUDGED: heading, height above roof, position, first nudge (phase, time)")
        for r in feasible where r.nudges > 0 {
            print(String(format: "ENTRY SWEEP FEASIBLE NUDGED | hdg %3.0f | +%3.0f m | E %6.0f N %6.0f | first nudge %@ at %.1f s | max gradient %.3f",
                         r.headingDeg, r.aboveRoof, r.east, r.north, r.firstNudgePhase, r.firstNudgeT ?? .nan, r.maxGradient))
            for s in r.preNudge {
                print(String(format: "ENTRY SWEEP PRE-NUDGE | start %4d | at %5.1f s | phase %@ | commanded pitch %+6.2f deg | aircraft pitch %+6.2f deg",
                             r.index, s.t, s.phase, s.cmdPitchDeg, s.pitchDeg))
            }
            if let c = r.crossing {
                print(String(format: "ENTRY SWEEP HIT | start %4d | first under 15 m at %.1f s (%@), clearance %.2f m, obstacle under %.1f m | first obstacle ahead on heading: %@",
                             r.index, c.t, c.phase, c.clear, c.obstH,
                             c.distanceAhead.map { String(format: "%.0f m ahead, %.1f m tall", $0, c.distanceObstH ?? .nan) } ?? "none within 300 m"))
            }
        }
        print("ENTRY SWEEP WORST 10 FEASIBLE by combined clearance:")
        for r in feasible.sorted(by: { $0.all.clear < $1.all.clear }).prefix(10) { print(EntrySweep.line(r)) }
        print(String(format: "ENTRY SWEEP wall time %.1f s for %d starts (%.3f s per start)", elapsed, rows.count, elapsed / Double(max(rows.count, 1))))
        if let out = ProcessInfo.processInfo.environment["GULLFIRE_ENTRY_SWEEP_OUT"] {
            print("ENTRY SWEEP wrote \(rows.count) rows to \(out)")
        }

        #expect(rows.count == jobs.count)
    }
}
