import Foundation
import Testing
@testable import GullfireKit

/// Curvature-limited, raise-only profile smoothing (Sources/GullfireKit/Flight/ProfileSmoother.swift). The pure cases need no
/// packages. The loop cases run on the real packages where they are present and print `SMOOTHER` and `VARIANT` lines.
private enum SmootherFixtures {
    static let spacing = 10.0
    static let speed = 30.0
    /// The allowed second difference per sample at the fixed speed: 1.5 * 10^2 / 30^2.
    static let delta = 1.5 * spacing * spacing / (speed * speed)
    static let gradient = 0.29

    /// A closed loop of 1000 m (100 samples): flat 15 m for 300 m, climbs at 0.29 for 200 m, flat for 300 m, descends at 0.29
    /// for 200 m. The climb ends at 15 + 58 = 73 m, so the top is flat at 73 m rather than 74.
    static func corneredLoop() -> [Double] {
        (0..<100).map { k -> Double in
            let m = Double(k) * spacing
            if m < 300 { return 15 }
            if m <= 500 { return 15 + gradient * (m - 300) }
            if m <= 800 { return 15 + gradient * 200 }
            return 15 + gradient * (1000 - m)
        }
    }

    static func speeds(_ n: Int) -> [Double] { [Double](repeating: speed, count: n) }

    static func secondDifference(_ r: [Double], _ i: Int) -> Double {
        let n = r.count
        return r[(i - 1 + n) % n] + r[(i + 1) % n] - 2 * r[i]
    }

    static func smooth(_ alt: [Double]) -> [Double] {
        ProfileSmoother.smooth(altitudes: alt, speeds: speeds(alt.count), spacing: spacing)
    }
}

@Suite("Profile smoother")
struct ProfileSmootherTests {
    @Test func cornersAreRoundedWithoutLoweringAndWithinTheLimit() {
        let input = SmootherFixtures.corneredLoop()
        let output = SmootherFixtures.smooth(input)
        let n = input.count

        for i in 0..<n {
            #expect(output[i] >= input[i] - 1e-9, "sample \(i) was lowered from \(input[i]) to \(output[i])")
        }
        for i in 0..<n {
            let c = SmootherFixtures.secondDifference(output, i)
            #expect(abs(c) <= SmootherFixtures.delta + 0.01, "sample \(i) has second difference \(c), limit \(SmootherFixtures.delta)")
        }
        let maxRaise = zip(output, input).map { $0 - $1 }.max() ?? 0
        print(String(format: "SMOOTHER pure: maximum raise %.2f m", maxRaise))
        #expect(maxRaise < 25)

        // The gradient is limited too: no step between samples is steeper than the plan's gradient.
        let limit = ProfileSmoother.Settings().gradient * SmootherFixtures.spacing
        for i in 0..<n {
            let next = output[(i + 1) % n]
            #expect(abs(next - output[i]) <= limit + 1e-6,
                    "samples \(i) to \(i + 1) step \(next - output[i]) m")
        }
    }

    @Test func aFlatProfileIsUnchanged() {
        let flat = [Double](repeating: 15, count: 60)
        #expect(SmootherFixtures.smooth(flat) == flat)
    }

    @Test func smoothingTwiceIsSmoothingOnce() {
        let once = SmootherFixtures.smooth(SmootherFixtures.corneredLoop())
        let twice = SmootherFixtures.smooth(once)
        for (x, y) in zip(once, twice) {
            #expect(abs(x - y) < 0.01, "a second smoothing moved a sample from \(x) to \(y) m")
        }
    }

    @Test func theGradientNeverExceedsThePlanLimit() {
        // A closed triangle of 3.5 m per sample up and down, steeper than the plan's 2.9 m per sample, so the gradient pass has
        // work to do as well as the curvature sweeps.
        let steep = (0..<80).map { i in 15 + 3.5 * Double(min(i, 80 - i)) }
        let output = SmootherFixtures.smooth(steep)
        let step = ProfileSmoother.Settings().gradient * SmootherFixtures.spacing
        for i in output.indices {
            let next = output[(i + 1) % output.count]
            #expect(abs(next - output[i]) <= step + 1e-6, "samples \(i) to \(i + 1) step \(next - output[i]) m")
        }
    }
}

@Suite("Profile smoother on real packages", .enabled(if: EnginePackages.available))
struct ProfileSmootherRunTests {
    @Test(arguments: EnginePackages.dirs) func smoothingNeverLowersAndTheLoopStaysChecked(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let js = JoinSettings.standard(for: city.manifest)
        var made = 0
        for seed in EnginePackages.seeds {
            guard let plan = RouteWalker.loop(graph: graph, obstacles: city, seed: seed, joinSettings: js) else { continue }
            made += 1

            let smoothed = ProfileSmoother.smooth(ProfileRepair.raise(plan, obstacles: city))
            let before = plan.assembly.waypoints, after = smoothed.assembly.waypoints
            #expect(before.count == after.count)
            for k in before.indices {
                #expect(after[k].alt >= before[k].alt, "seed \(seed): waypoint \(k) was lowered")
            }
            #expect(RouteChecker.check(smoothed, obstacles: city, joinSettings: js).isEmpty,
                    "seed \(seed): repaired and smoothed route fails the checker")

            let raises = zip(before, after).map { $1.alt - $0.alt }
            let mean = raises.reduce(0, +) / Double(max(raises.count, 1))
            let km = Route(file: RouteFile(name: "Smoother", closed: true, waypoints: after)).length / 1000
            print(String(format: "SMOOTHER seed %d: max raise %.1f m, mean raise %.2f m, route km %.2f",
                         seed, raises.max() ?? 0, mean, km))
        }
        #expect(made >= 2, "only \(made) of \(EnginePackages.seeds.count) seeds made a loop")
    }

    /// The key measurement: printed, not asserted. Each route flies three ways, headless, for 400 s: (a) the original waypoints
    /// with the default tuning, (b) the original with the feedforward on, (c) the repaired and smoothed waypoints with the
    /// feedforward on. Only the nudge count of (c) is asserted.
    @Test func theFeedforwardMeasurement() throws {
        let dir = try #require(EnginePackages.dirs.first)
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let js = JoinSettings.standard(for: city.manifest)

        var routes: [(name: String, waypoints: [Waypoint])] = []
        for seed in [1, 3, 6] as [UInt64] {
            var flight = try #require(EndlessFlight(city: city, seed: seed))
            let next = flight.nextLoop()
            let made = try #require(next)
            routes.append(("engine \(seed)", made.plan.assembly.waypoints))
        }
        for name in ["street-1", "street-2", "street-5"] {
            let url = dir.appendingPathComponent("routes/\(name).json")
            let file = try JSONDecoder().decode(RouteFile.self, from: Data(contentsOf: url))
            routes.append((name, file.waypoints))
        }

        for (name, original) in routes {
            let repaired = ProfileSmoother.smooth(waypoints: ProfileRepair.raise(waypoints: original, obstacles: city))
            let variants: [(label: String, waypoints: [Waypoint], feedforward: Double)] = [
                ("a", original, 0), ("b", original, 1), ("c", repaired, 1),
            ]
            for variant in variants {
                var tuning = FlightTuning()
                tuning.autopilotFeedforward = variant.feedforward
                let route = Route(file: RouteFile(name: name, closed: true, waypoints: variant.waypoints))
                let s = Smoothness.fly(name: name, route: route, city: city, tuning: tuning, seconds: 400)
                let d = DryRun.fly(route: route, obstacles: city, extent: city.manifest.extentM, tuning: tuning, seconds: 400)
                print(String(format: "VARIANT %@ %@ | avoidance %.1f s | az p99 %.2f | spikes over 3 m/s2 %d | pitch rate max %.0f | roll rate p99 %.1f | nudges %d",
                             name, variant.label, d.avoidanceSeconds, s.azP99, s.spikes.count, s.pitchRateMax, s.rollRateP99, d.nudges))
                if variant.label == "c" {
                    #expect(d.nudges == 0, "\(name) variant c: \(d.nudges) collision nudges")
                }
            }
        }
    }
}
