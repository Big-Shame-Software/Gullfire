import Foundation
import Testing
@testable import GullfireKit

/// Planner-side altitude repair (Sources/GullfireKit/Flight/ProfileRepair.swift, Spikes/LEVELING_PLAN.md Phase 2b).
/// The synthetic cases need no packages; the last case runs on the real packages where they are present and prints one
/// `REPAIR` line per engine seed.

/// A 40 m block, 150 to 170 m east and 30 m either side of the leg along the east axis.
private struct RepairBlock: ObstacleSource {
    func height(east: Double, north: Double) -> Float {
        (150...170).contains(east) && (-30...30).contains(north) ? 40 : 0
    }
}

private struct RepairFlatGround: ObstacleSource {
    func height(east: Double, north: Double) -> Float { 0 }
}

private enum RepairFixtures {
    static let extent = Manifest.Extent(minEast: -1500, maxEast: 1500, minNorth: -1000, maxNorth: 1000)

    /// A closed rectangle, 1000 m by 400 m, flown east along the bottom leg. The bottom leg has a waypoint every 25 m, the
    /// other sides every 100 m. `altitude` gives the planned altitude at each waypoint's position.
    static func rectangle(altitude: (Double, Double) -> Double = { _, _ in 15 }) -> [Waypoint] {
        var points: [(Double, Double)] = (0...40).map { (Double($0) * 25, 0) }
        points += (1...4).map { (1000, Double($0) * 100) }
        points += (1...10).map { (1000 - Double($0) * 100, 400) }
        points += (1...3).map { (0, 400 - Double($0) * 100) }
        return points.map { Waypoint(east: $0.0, north: $0.1, alt: altitude($0.0, $0.1), speedKt: 40) }
    }

    static func plan(_ waypoints: [Waypoint]) -> RoutePlan {
        RoutePlan(stretches: [], joins: [], assembly: Assembly(waypoints: waypoints, owners: waypoints.map { _ in .run(0) }))
    }

    static func route(_ waypoints: [Waypoint]) -> Route {
        Route(file: RouteFile(name: "Repair", closed: true, waypoints: waypoints))
    }

    static func inBlock(_ p: Route.Sample) -> Bool {
        (150...170).contains(p.east) && (-30...30).contains(p.north)
    }
}

@Suite("Profile repair")
struct ProfileRepairTests {
    @Test func aBlockAheadGetsAClimbThatClearsItAndNothingIsLowered() {
        let before = RepairFixtures.plan(RepairFixtures.rectangle())
        let after = ProfileRepair.raise(before, obstacles: RepairBlock())
        let a = before.assembly.waypoints, b = after.assembly.waypoints
        #expect(a.count == b.count)
        for k in a.indices {
            #expect(b[k].alt >= a[k].alt, "waypoint \(k) was lowered from \(a[k].alt) to \(b[k].alt)")
            #expect(b[k].east == a[k].east && b[k].north == a[k].north && b[k].speedKt == a[k].speedKt)
        }

        // The samples 3 s before the block: the block is at the look-ahead's 3 s point, so each needs 40 + 15 + 2.
        let route = RepairFixtures.route(b)
        var checked = 0
        for (i, s) in route.samples.enumerated() {
            let j = (i + Int((max(s.speed, 10) * 3 / route.spacing).rounded())) % route.count
            if RepairFixtures.inBlock(route.samples[j]) {
                checked += 1
                #expect(s.altitude >= 40 + 15 + 2 - 0.01, "sample \(i) is \(s.altitude) m, 3 s before the block")
            }
        }
        #expect(checked > 0, "no sample sees the block 3 s ahead")

        // Waypoint to waypoint, the gradient is within the plan's 20 degrees.
        for k in b.indices {
            let n = (k + 1) % b.count
            let d = hypot(b[n].east - b[k].east, b[n].north - b[k].north)
            #expect(abs(b[n].alt - b[k].alt) <= 0.3 * d + 1e-6, "waypoint \(k) to \(n) climbs \(b[n].alt - b[k].alt) m over \(d) m")
        }

        // The repaired route should trip the avoidance layer for less time.
        let unrepaired = DryRun.fly(route: RepairFixtures.route(a), obstacles: RepairBlock(), extent: RepairFixtures.extent)
        let repaired = DryRun.fly(route: route, obstacles: RepairBlock(), extent: RepairFixtures.extent)
        print(String(format: "REPAIR synthetic: avoidance seconds %.1f -> %.1f (events %d -> %d), nudges %d -> %d, max az %.1f -> %.1f",
                     unrepaired.avoidanceSeconds, repaired.avoidanceSeconds,
                     unrepaired.avoidanceEvents.count, repaired.avoidanceEvents.count,
                     unrepaired.nudges, repaired.nudges, unrepaired.maxVerticalAcceleration, repaired.maxVerticalAcceleration))
        #expect(unrepaired.avoidanceSeconds > 0, "the unrepaired route should trip the layer")
        #expect(repaired.avoidanceSeconds < unrepaired.avoidanceSeconds)
        #expect(repaired.nudges <= unrepaired.nudges)
    }

    @Test func anObstacleFreeRouteIsUnchanged() {
        let flat = RepairFixtures.plan(RepairFixtures.rectangle())
        #expect(ProfileRepair.raise(flat, obstacles: RepairFlatGround()).assembly.waypoints == flat.assembly.waypoints)

        // A gentle climb and descent, within the gradient, with no obstacles.
        let ramp = RepairFixtures.plan(RepairFixtures.rectangle { e, n in n == 0 ? 15 + 0.02 * e : 35 })
        #expect(ProfileRepair.raise(ramp, obstacles: RepairFlatGround()).assembly.waypoints == ramp.assembly.waypoints)
    }

    @Test func raisingTwiceIsRaisingOnce() {
        let plan = RepairFixtures.plan(RepairFixtures.rectangle())
        let once = ProfileRepair.raise(plan, obstacles: RepairBlock())
        let twice = ProfileRepair.raise(once, obstacles: RepairBlock())
        #expect(once.assembly.waypoints.count == twice.assembly.waypoints.count)
        for (x, y) in zip(once.assembly.waypoints, twice.assembly.waypoints) {
            #expect(abs(x.alt - y.alt) < 0.01, "a second repair moved a waypoint from \(x.alt) to \(y.alt) m")
        }
    }
}

@Suite("Profile repair on real packages", .enabled(if: EnginePackages.available))
struct ProfileRepairRunTests {
    @Test(arguments: EnginePackages.dirs) func realLoopsStayCheckedAndFlyNoWorse(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let js = JoinSettings.standard(for: city.manifest)
        let extent = city.manifest.extentM
        var made = 0
        for seed in EnginePackages.seeds {
            guard let plan = RouteWalker.loop(graph: graph, obstacles: city, seed: seed, joinSettings: js) else { continue }
            made += 1

            let clock = ContinuousClock()
            var repaired = plan
            let elapsed = clock.measure { repaired = ProfileRepair.raise(plan, obstacles: city) }
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("REPAIR time: seed \(seed) one raise \(String(format: "%.3f", seconds)) s")

            #expect(RouteChecker.check(repaired, obstacles: city, joinSettings: js).isEmpty, "seed \(seed): repaired route fails the checker")
            let before = plan.assembly.waypoints, after = repaired.assembly.waypoints
            #expect(before.count == after.count)
            for k in before.indices {
                #expect(after[k].alt >= before[k].alt, "seed \(seed): waypoint \(k) was lowered")
            }

            let routeA = RepairFixtures.route(before), routeB = RepairFixtures.route(after)
            let dA = DryRun.fly(route: routeA, obstacles: city, extent: extent)
            let dB = DryRun.fly(route: routeB, obstacles: city, extent: extent)
            let sA = Smoothness.fly(name: "seed \(seed) before", route: routeA, city: city, seconds: 400)
            let sB = Smoothness.fly(name: "seed \(seed) after", route: routeB, city: city, seconds: 400)
            let maxRaise = zip(before, after).map { $1.alt - $0.alt }.max() ?? 0
            print(String(format: "REPAIR seed \(seed): avoidance seconds %.1f -> %.1f (events %d -> %d), nudges %d -> %d, max az %.1f -> %.1f, spikes over 3 m/s2 per 400 s %d -> %d, max altitude raised %.1f m, route km %.2f",
                         dA.avoidanceSeconds, dB.avoidanceSeconds,
                         dA.avoidanceEvents.count, dB.avoidanceEvents.count, dA.nudges, dB.nudges,
                         dA.maxVerticalAcceleration, dB.maxVerticalAcceleration,
                         sA.spikes.count, sB.spikes.count, maxRaise, routeB.length / 1000))
            #expect(dB.nudges <= dA.nudges, "seed \(seed): repair added collision nudges")
        }
        #expect(made >= 2, "\(dir.lastPathComponent): only \(made) of \(EnginePackages.seeds.count) seeds made a loop")
    }
}
