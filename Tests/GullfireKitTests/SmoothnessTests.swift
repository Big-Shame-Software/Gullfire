import Foundation
import Testing
@testable import GullfireKit

/// Bumpiness measurement (Spikes/LEVELING_PLAN.md, Phase 0). Flies routes headless on the real simulator and autopilot,
/// samples every 0.1 s, and attributes each vertical-acceleration spike to a cause: avoidance warning, collision nudge,
/// boundary guard, floor or ceiling clamp, route seam, or none.
///
/// The unit tests on `Smoothness.analyze` are always on. The report is a measurement, not a gate: it prints one
/// `SMOOTH` line per flight and its worst spikes, and never fails on the numbers. Off unless the variable is set:
///
///     GULLFIRE_SMOOTHNESS=1 swift test --filter SmoothnessTests
///
/// GULLFIRE_SMOOTH_SECONDS sets the simulated length per flight (default 420). GULLFIRE_SMOOTH_OUT, if set, also
/// writes the table as Markdown to that path. GULLFIRE_SMOOTH_DUMP=<route name or all> prints one DUMP line per spike on
/// that route (time, position, route slope and curvature, commanded pitch and roll, flags, speed limit).
enum Smoothness {
    struct Sample {
        var t: Double
        var altitude: Double
        var pitchDeg: Double
        var bankDeg: Double
        var routeIndex: Int
        var avoidance: Bool
        var boundary: Bool
        var nudged: Bool
        var clamped: Bool
        // Filled in by fly() only, for the spike dump (GULLFIRE_SMOOTH_DUMP). Zero or nil in the unit tests.
        var east: Double = 0
        var north: Double = 0
        var speed: Double = 0
        /// The autopilot's own command, before the avoidance and boundary layers change it, in degrees.
        var commandedPitchDeg: Double = 0
        var commandedBankDeg: Double = 0
        /// The curve cap on speed (m/s) when it is below the waypoint speed the autopilot aims at; nil otherwise.
        var speedLimit: Double? = nil
    }

    enum Cause: String, CaseIterable {
        case start, nudge, avoidance, boundary, clamp, seam, none
    }

    struct Spike {
        var t: Double
        var az: Double
        var routeIndex: Int
        var cause: Cause
        /// The sample index of the peak, into the report's `samples`.
        var index = 0
    }

    struct Report {
        var name: String
        var seconds: Double
        var azP50, azP95, azP99, azMax: Double
        var pitchRateP95, pitchRateMax: Double
        var rollRateP95, rollRateP99, rollRateMax: Double
        var verticalSpeedP95: Double
        var spikes: [Spike]
        var startSpikes: [Spike]
        var samples: [Sample] = []
    }

    /// Samples are taken this often, seconds.
    static let sampleInterval = 0.1
    /// A spike is a vertical acceleration above this, m/s2.
    static let spikeThreshold = 3.0
    /// Spikes earlier than this are the simulator starting level, not flight.
    static let startWindow = 1.5
    /// The window either side of a spike that decides its cause: 0.8 s.
    static let windowSamples = 8
    /// Route indices this close to either end count as a seam.
    static let seamSamples = 12

    /// The p-th percentile of the values: the sorted value at index Int(count * p), clamped to the last value.
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    /// Measures a series of samples taken every `dt` seconds on a route of `routeCount` samples.
    static func analyze(name: String, samples: [Sample], dt: Double, routeCount: Int) -> Report {
        let n = samples.count
        var az = [Double](repeating: 0, count: n)
        var pitchRate: [Double] = [], rollRate: [Double] = [], vz: [Double] = []
        var azAbs: [Double] = []
        if n >= 3 {
            for i in 1..<(n - 1) {
                let a = (samples[i + 1].altitude - 2 * samples[i].altitude + samples[i - 1].altitude) / (dt * dt)
                az[i] = a
                azAbs.append(abs(a))
                vz.append(abs(samples[i + 1].altitude - samples[i - 1].altitude) / (2 * dt))
                pitchRate.append(abs(samples[i + 1].pitchDeg - samples[i - 1].pitchDeg) / (2 * dt))
                rollRate.append(abs(samples[i + 1].bankDeg - samples[i - 1].bankDeg) / (2 * dt))
            }
        }

        func cause(at p: Int) -> Cause {
            let t = samples[p].t
            if t < startWindow { return .start }
            let lo = max(0, p - windowSamples), hi = min(n - 1, p + windowSamples)
            let window = samples[lo...hi]
            if window.contains(where: { $0.nudged }) { return .nudge }
            if window.contains(where: { $0.avoidance }) { return .avoidance }
            if window.contains(where: { $0.boundary }) { return .boundary }
            if window.contains(where: { $0.clamped }) { return .clamp }
            if routeCount > 0 {
                let half = routeCount / 2
                let wrapped = (lo..<hi).contains { samples[$0].routeIndex - samples[$0 + 1].routeIndex > half }
                let r = samples[p].routeIndex
                if wrapped || min(r, routeCount - 1 - r) <= seamSamples { return .seam }
            }
            return .none
        }

        // A spike is a run of consecutive samples over the threshold, reported at its peak. A single altitude step
        // therefore gives one spike, not the two samples either side of it.
        var spikes: [Spike] = [], startSpikes: [Spike] = []
        var i = 1
        while i < n - 1 {
            guard abs(az[i]) > spikeThreshold else { i += 1; continue }
            var j = i
            while j + 1 < n - 1 && abs(az[j + 1]) > spikeThreshold { j += 1 }
            var peak = i
            for k in i...j where abs(az[k]) > abs(az[peak]) { peak = k }
            let spike = Spike(t: samples[peak].t, az: az[peak], routeIndex: samples[peak].routeIndex, cause: cause(at: peak), index: peak)
            if spike.cause == .start { startSpikes.append(spike) } else { spikes.append(spike) }
            i = j + 1
        }

        return Report(name: name, seconds: Double(n) * dt,
                      azP50: percentile(azAbs, 0.5), azP95: percentile(azAbs, 0.95), azP99: percentile(azAbs, 0.99),
                      azMax: azAbs.max() ?? 0,
                      pitchRateP95: percentile(pitchRate, 0.95), pitchRateMax: pitchRate.max() ?? 0,
                      rollRateP95: percentile(rollRate, 0.95), rollRateP99: percentile(rollRate, 0.99),
                      rollRateMax: rollRate.max() ?? 0,
                      verticalSpeedP95: percentile(vz, 0.95),
                      spikes: spikes, startSpikes: startSpikes, samples: samples)
    }

    /// One line per spike on `route`: what the aircraft, the autopilot and the route were doing at the spike's peak sample.
    /// The route's slope and curvature are read from its own samples at the nearest index.
    static func dumpLines(name: String, route: Route, report r: Report) -> [String] {
        let s = r.samples
        let n = s.count
        let rc = route.count
        guard rc > 0, n > 2 else { return ["DUMP \(name): no samples"] }
        func wrap(_ i: Int) -> Int { ((i % rc) + rc) % rc }
        func slope(_ i: Int) -> Double {
            (route.samples[wrap(i + 1)].altitude - route.samples[wrap(i - 1)].altitude) / (2 * route.spacing)
        }
        func heading(_ i: Int) -> Double {
            let sm = route.samples[wrap(i)]
            return atan2(sm.tangentEast, sm.tangentNorth)
        }
        func curvatureDegPerM(_ i: Int) -> Double {
            wrapPi(heading(i + 1) - heading(i - 1)) / (2 * route.spacing) * 180 / Double.pi
        }
        let hundredM = Int((100 / route.spacing).rounded())
        func f(_ x: Double, _ fmt: String) -> String { String(format: fmt, x) }
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }

        var lines = ["DUMP \(name): \(r.spikes.count) spikes (route \(rc) samples, \(f(route.length, "%.0f")) m)"]
        for sp in r.spikes {
            let p = sp.index
            let x = s[p]
            let idx = x.routeIndex
            let lo = max(0, p - windowSamples), hi = min(n - 1, p + windowSamples)
            let win = s[lo...hi]
            let pitchRate = (s[p + 1].pitchDeg - s[p - 1].pitchDeg) / (2 * sampleInterval)
            let limit = x.speedLimit.map { "curve cap \(f($0, "%.1f")) m/s" } ?? "none"
            let parts: [String] = [
                "DUMP \(name) t=\(f(x.t, "%.1f")) s",
                "route index \(idx)/\(rc)",
                "pos E \(f(x.east, "%.1f")) N \(f(x.north, "%.1f"))",
                "alt \(f(x.altitude, "%.2f")) m",
                "speed \(f(x.speed, "%.2f")) m/s",
                "az \(f(sp.az, "%+.2f")) m/s2",
                "pitch \(f(x.pitchDeg, "%+.2f")) deg, bank \(f(x.bankDeg, "%+.2f")) deg",
                "pitch rate \(f(pitchRate, "%+.1f")) deg/s",
                "route slope \(f(slope(idx), "%+.4f")) (-100 m \(f(slope(idx - hundredM), "%+.4f")), +100 m \(f(slope(idx + hundredM), "%+.4f")))",
                "route curvature \(f(curvatureDegPerM(idx), "%+.3f")) deg/m",
                "cmd pitch \(f(x.commandedPitchDeg, "%+.1f")) deg, roll \(f(x.commandedBankDeg, "%+.1f")) deg",
                "at peak: avoidance \(yn(x.avoidance)), boundary \(yn(x.boundary)), nudge \(yn(x.nudged)), clamp \(yn(x.clamped))",
                "in window: avoidance \(yn(win.contains { $0.avoidance })), boundary \(yn(win.contains { $0.boundary })), nudge \(yn(win.contains { $0.nudged })), clamp \(yn(win.contains { $0.clamped }))",
                "speed limit \(limit)",
                "speed change over window \(f(s[hi].speed - s[lo].speed, "%+.2f")) m/s",
                "cause \(sp.cause.rawValue)",
            ]
            lines.append(parts.joined(separator: " | "))
        }
        return lines
    }

    /// Flies `route` headless for `seconds` on the real simulator and autopilot, as the soak tests do, and measures it.
    static func fly(name: String, route: Route, city: CityPackage, tuning: FlightTuning = FlightTuning(), seconds: Double) -> Report {
        let t = tuning
        let a = route.samples[0], b = route.samples[1]
        let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
        var sim = Simulation(start: start, tuning: t)
        var hint: Int? = 0
        var lastIdx = 0
        var nudgesSeen = sim.nudges
        var lastCmd = ControlInput()
        var lastLimit: Double?
        var samples: [Sample] = []
        let every = Int((sampleInterval / t.fixedStep).rounded())
        let extent = city.manifest.extentM
        let total = Int((seconds / t.fixedStep).rounded())
        for step in 1...max(1, total) {
            sim.advance(by: t.fixedStep, obstacles: city, extent: extent) { s, _ in
                let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t)
                hint = r.index
                lastIdx = r.index
                lastCmd = r.control
                // The speed the autopilot is held to: the curve cap over the next 300 m (Autopilot.control). Recomputed here
                // only to report it; it counts as a limit in force when it is below the waypoint speed it aims at.
                lastLimit = nil
                if route.count > 0 {
                    var tightest = route.samples[r.index].radius
                    for k in 0...Int(300 / route.spacing) {
                        tightest = min(tightest, route.samples[(r.index + k) % route.count].radius)
                    }
                    let cap = (t.gravity * tightest * tan(30 * Double.pi / 180)).squareRoot()
                    let ahead = Int((Autopilot.lookahead(speed: s.speed) / route.spacing).rounded())
                    if cap < route.samples[(r.index + ahead) % route.count].speed { lastLimit = cap }
                }
                return r.control
            }
            if step % every == 0 {
                let s = sim.current
                samples.append(Sample(t: Double(step) * t.fixedStep,
                                      altitude: s.altitude,
                                      pitchDeg: s.pitch * 180 / .pi,
                                      bankDeg: s.bank * 180 / .pi,
                                      routeIndex: lastIdx,
                                      avoidance: sim.proximityWarning,
                                      boundary: sim.boundaryWarning,
                                      nudged: sim.nudges > nudgesSeen,
                                      clamped: abs(s.altitude - t.floor) < 0.5 || abs(s.altitude - t.ceiling) < 0.5,
                                      east: s.east, north: s.north, speed: s.speed,
                                      commandedPitchDeg: lastCmd.pitch * t.pitchLimit * 180 / .pi,
                                      commandedBankDeg: lastCmd.roll * t.rollLimit * 180 / .pi,
                                      speedLimit: lastLimit))
                nudgesSeen = sim.nudges
            }
        }
        return analyze(name: name, samples: samples, dt: sampleInterval, routeCount: route.count)
    }
}

@Suite("Smoothness")
struct SmoothnessTests {
    // MARK: Unit tests on the analysis (always on)

    /// A flat series of samples: 200 samples (20 s) at altitude 100 m, on a route of 200 samples.
    static func flat(count: Int = 200, routeIndex: Int = 100) -> [Smoothness.Sample] {
        (0..<count).map { i in
            Smoothness.Sample(t: Double(i + 1) * 0.1, altitude: 100, pitchDeg: 0, bankDeg: 0, routeIndex: routeIndex,
                              avoidance: false, boundary: false, nudged: false, clamped: false)
        }
    }

    /// Raises the altitude by `metres` from sample `k` on: a single step, which makes a pair of over-threshold
    /// accelerations on adjacent samples.
    static func step(_ s: inout [Smoothness.Sample], at k: Int, metres: Double = 20) {
        for i in k..<s.count { s[i].altitude += metres }
    }

    @Test func aSteadyClimbHasNoAcceleration() {
        var s = Self.flat()
        for i in s.indices { s[i].altitude = 100 + 0.5 * s[i].t }
        let r = Smoothness.analyze(name: "climb", samples: s, dt: 0.1, routeCount: 200)
        #expect(r.azP99 < 0.01)
        #expect(r.azMax < 0.01)
        #expect(r.spikes.isEmpty)
        #expect(abs(r.verticalSpeedP95 - 0.5) < 1e-6)
    }

    @Test func aSingleAltitudeStepIsOneSpike() {
        var s = Self.flat()
        Self.step(&s, at: 100)
        let r = Smoothness.analyze(name: "step", samples: s, dt: 0.1, routeCount: 200)
        #expect(r.spikes.count == 1)
        #expect(r.startSpikes.isEmpty)
        #expect(r.spikes.first?.cause == Smoothness.Cause.none)
        #expect(abs((r.spikes.first?.az ?? 0)) > 1000, "a 20 m step in 0.1 s is about 2000 m/s2")
    }

    @Test func aSpikeWithAvoidanceInTheWindowIsAvoidance() {
        var s = Self.flat()
        Self.step(&s, at: 100)
        for i in 95...105 { s[i].avoidance = true }
        let r = Smoothness.analyze(name: "avoid", samples: s, dt: 0.1, routeCount: 200)
        #expect(r.spikes.map(\.cause) == [.avoidance])
    }

    @Test func aNudgeWinsOverAvoidance() {
        var s = Self.flat()
        Self.step(&s, at: 100)
        for i in 95...105 { s[i].avoidance = true }
        s[98].nudged = true
        let r = Smoothness.analyze(name: "nudge", samples: s, dt: 0.1, routeCount: 200)
        #expect(r.spikes.map(\.cause) == [.nudge])
    }

    @Test func aSpikeAtHalfASecondIsStartNotFlight() {
        var s = Self.flat()
        Self.step(&s, at: 5)
        let r = Smoothness.analyze(name: "start", samples: s, dt: 0.1, routeCount: 200)
        #expect(r.spikes.isEmpty)
        #expect(r.startSpikes.map(\.cause) == [.start])
        #expect(abs((r.startSpikes.first?.t ?? 0) - 0.5) < 0.11)
    }

    @Test func aRouteIndexWrapNearASpikeIsSeam() {
        var s = Self.flat()
        for i in 0..<100 { s[i].routeIndex = 195 }
        for i in 100..<s.count { s[i].routeIndex = 3 }
        Self.step(&s, at: 100)
        let r = Smoothness.analyze(name: "seam", samples: s, dt: 0.1, routeCount: 200)
        #expect(r.spikes.map(\.cause) == [.seam])
    }

    @Test func aSpikeWithNoFlagsIsNone() {
        var s = Self.flat()
        Self.step(&s, at: 100)
        let r = Smoothness.analyze(name: "none", samples: s, dt: 0.1, routeCount: 200)
        #expect(r.spikes.map(\.cause) == [.none])
    }

    @Test func aSpikeWithTheClampFlagIsClamp() {
        var s = Self.flat()
        Self.step(&s, at: 100)
        for i in 100...105 { s[i].clamped = true }
        let r = Smoothness.analyze(name: "clamp", samples: s, dt: 0.1, routeCount: 200)
        #expect(r.spikes.map(\.cause) == [.clamp])
    }

    @Test func percentilesOfAKnownSeries() {
        // Pitch of i squared degrees, sampled every 0.1 s: the central difference at sample i is 20 i deg/s,
        // for i = 1 ... 99 (101 samples, so 99 interior values).
        let s: [Smoothness.Sample] = (0..<101).map { i in
            Smoothness.Sample(t: Double(i) * 0.1, altitude: 100, pitchDeg: Double(i * i), bankDeg: 0, routeIndex: 50,
                              avoidance: false, boundary: false, nudged: false, clamped: false)
        }
        let r = Smoothness.analyze(name: "known", samples: s, dt: 0.1, routeCount: 200)
        #expect(abs(r.pitchRateMax - 1980) < 1e-6)
        #expect(abs(r.pitchRateP95 - 1900) < 1e-6)
        #expect(Smoothness.percentile((1...99).map { Double($0) }, 0.5) == 50)
        #expect(Smoothness.percentile((0..<100).map { Double($0) }, 0.99) == 99)
        #expect(Smoothness.percentile([], 0.5) == 0)
    }

    // MARK: Report (measurement only; never fails on the numbers)

    static var reportEnabled: Bool {
        ProcessInfo.processInfo.environment["GULLFIRE_SMOOTHNESS"] != nil && PackageTests.built
    }

    @Test(.enabled(if: SmoothnessTests.reportEnabled)) func bumpinessReport() throws {
        let seconds = ProcessInfo.processInfo.environment["GULLFIRE_SMOOTH_SECONDS"].flatMap(Double.init) ?? 420
        // GULLFIRE_SMOOTH_DIRS: colon-separated package folders (default Chicago). With more than one, names start with the folder name.
        let dirs = ProcessInfo.processInfo.environment["GULLFIRE_SMOOTH_DIRS"].map {
            $0.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        } ?? [PackageTests.chicago]

        var results: [(name: String, route: Route, report: Smoothness.Report)] = []
        for dir in dirs {
            let city = try CityPackage.open(directory: dir)
            let routes = dir.appendingPathComponent("routes", isDirectory: true)
            let tag = dirs.count > 1 ? dir.lastPathComponent + " " : ""
            var flights: [(name: String, route: Route)] = []
            flights.append((tag + "scenic", try Route.load(routes.appendingPathComponent("scenic.json"))))
            flights.append((tag + "river", try Route.load(routes.appendingPathComponent("river.json"))))
            for n in 1...6 where FileManager.default.fileExists(atPath: routes.appendingPathComponent("street-\(n).json").path) {
                flights.append((tag + "street-\(n)", try Route.load(routes.appendingPathComponent("street-\(n).json")).preparedIfStreet(obstacles: city)))
            }
            for seed in 1...6 {
                var endless = try #require(EndlessFlight(city: city, seed: UInt64(seed)))
                guard let loop = endless.nextLoop() else { continue }
                flights.append((tag + "engine seed \(seed)", loop.route))
            }
            for f in flights {
                results.append((f.name, f.route, Smoothness.fly(name: f.name, route: f.route, city: city, seconds: seconds)))
            }
        }

        func f2(_ x: Double) -> String { String(format: "%.2f", x) }
        func f1(_ x: Double) -> String { String(format: "%.1f", x) }
        func count(_ r: Smoothness.Report, _ c: Smoothness.Cause) -> Int { r.spikes.filter { $0.cause == c }.count }

        for (name, _, r) in results {
            print("SMOOTH \(name) | az p50 \(f2(r.azP50)) p95 \(f2(r.azP95)) p99 \(f2(r.azP99)) max \(f2(r.azMax)) | pitch rate p95 \(f1(r.pitchRateP95)) max \(f1(r.pitchRateMax)) | roll rate p95 \(f1(r.rollRateP95)) p99 \(f1(r.rollRateP99)) max \(f1(r.rollRateMax)) | spikes \(r.spikes.count) (avoidance \(count(r, .avoidance)), boundary \(count(r, .boundary)), nudge \(count(r, .nudge)), clamp \(count(r, .clamp)), seam \(count(r, .seam)), none \(count(r, .none))) | start artefacts \(r.startSpikes.count)")
        }
        for (name, route, r) in results {
            for sp in r.spikes.sorted(by: { abs($0.az) > abs($1.az) }).prefix(6) {
                print("SPIKE \(name) t=\(f1(sp.t)) az=\(String(format: "%+.1f", sp.az)) route index \(sp.routeIndex)/\(route.count) cause=\(sp.cause.rawValue)")
            }
        }

        // GULLFIRE_SMOOTH_DUMP=<route name, e.g. River, or all>: one DUMP line per spike on that route.
        if let want = ProcessInfo.processInfo.environment["GULLFIRE_SMOOTH_DUMP"], !want.isEmpty {
            for (name, route, r) in results where want.lowercased() == "all" || want.lowercased() == name.lowercased() {
                for line in Smoothness.dumpLines(name: name, route: route, report: r) { print(line) }
            }
        }

        // GULLFIRE_SMOOTH_ROLL=<route name or all>: the worst roll-rate moments on that route, at least 5 s apart (ROLL lines:
        // time, roll rate, bank, route index of the route's waypoints, position, speed).
        if let want = ProcessInfo.processInfo.environment["GULLFIRE_SMOOTH_ROLL"], !want.isEmpty {
            for (name, route, r) in results where want.lowercased() == "all" || name.lowercased().hasSuffix(want.lowercased()) {
                var rates: [(i: Int, rate: Double)] = []
                for i in 1..<max(1, r.samples.count) {
                    rates.append((i, abs(r.samples[i].bankDeg - r.samples[i - 1].bankDeg) / Smoothness.sampleInterval))
                }
                var picked: [Int] = []
                for x in rates.sorted(by: { $0.rate > $1.rate }) where picked.count < 8 {
                    if picked.allSatisfy({ abs(r.samples[$0].t - r.samples[x.i].t) >= 5 }) { picked.append(x.i) }
                }
                // Where the fast-rolling samples (over 25 deg/s) fall: route index bucket of 20, count of samples, first east/north.
                var buckets: [Int: (n: Int, e: Double, nn: Double)] = [:]
                for x in rates where x.rate > 25 {
                    let sm = r.samples[x.i]
                    let b = sm.routeIndex / 20
                    if let cur = buckets[b] { buckets[b] = (cur.n + 1, cur.e, cur.nn) } else { buckets[b] = (1, sm.east, sm.north) }
                }
                for (b, v) in buckets.sorted(by: { $0.value.n > $1.value.n }).prefix(8) {
                    print("ROLLZONE \(name) index \(b * 20)...\(b * 20 + 19)/\(route.count): \(v.n) samples over 25 deg/s, near east=\(f1(v.e)) north=\(f1(v.nn))")
                }
                for i in picked {
                    let sm = r.samples[i]
                    print("ROLL \(name) t=\(f1(sm.t)) rate=\(f1(abs(sm.bankDeg - r.samples[i - 1].bankDeg) / Smoothness.sampleInterval)) bank=\(f1(sm.bankDeg)) index \(sm.routeIndex)/\(route.count) east=\(f1(sm.east)) north=\(f1(sm.north)) speed=\(f1(sm.speed)) avoid=\(sm.avoidance) boundary=\(sm.boundary)")
                }
            }
        }

        if let out = ProcessInfo.processInfo.environment["GULLFIRE_SMOOTH_OUT"] {
            var md = "| Flight | Vertical accel p50 | p95 | p99 | max (m/s2) | Pitch rate p95 | max (deg/s) | Roll rate p95 | p99 | max (deg/s) | Spikes | Avoidance | Boundary | Nudge | Clamp | Seam | None | Start artefacts |\n"
            md += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
            for (name, _, r) in results {
                md += "| \(name) | \(f2(r.azP50)) | \(f2(r.azP95)) | \(f2(r.azP99)) | \(f2(r.azMax)) | \(f1(r.pitchRateP95)) | \(f1(r.pitchRateMax)) | \(f1(r.rollRateP95)) | \(f1(r.rollRateP99)) | \(f1(r.rollRateMax)) | \(r.spikes.count) | \(count(r, .avoidance)) | \(count(r, .boundary)) | \(count(r, .nudge)) | \(count(r, .clamp)) | \(count(r, .seam)) | \(count(r, .none)) | \(r.startSpikes.count) |\n"
            }
            try md.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        }
    }
}
