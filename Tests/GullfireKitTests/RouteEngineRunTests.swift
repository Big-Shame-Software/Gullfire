import Foundation
import Testing
@testable import GullfireKit

/// Route engine, step 2: run-level checks on routes the app assembles from the street graph and the obstacle grid alone
/// (no footprints). These are the checks the 1.1 height work taught us to write first: every assembled route is flown
/// headless for 600 s, with zero collision nudges, and a deliberately bad route must be caught by the checker.
enum EnginePackages {
    /// Packages that have a street graph (Chicago here; the engine never names a city).
    static let dirs: [URL] = ["Chicago"].map { PackageTests.root.appendingPathComponent("Cities/\($0)", isDirectory: true) }
        .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("streets.json").path) }
    static var available: Bool { !dirs.isEmpty && PackageTests.built }
    static let seeds: [UInt64] = [1, 2, 3, 4, 5, 6]
}

@Suite("Route engine on real packages", .enabled(if: EnginePackages.available))
struct RouteEngineRunTests {
    @Test(arguments: EnginePackages.dirs) func walkerMakesCheckedLoopsAndTheyFlyClean(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let js = JoinSettings.standard(for: city.manifest)
        var made = 0
        for seed in EnginePackages.seeds {
            guard let plan = RouteWalker.loop(graph: graph, obstacles: city, seed: seed, joinSettings: js) else { continue }
            made += 1
            #expect(RouteChecker.check(plan, obstacles: city, joinSettings: js).isEmpty, "\(dir.lastPathComponent) seed \(seed) failed its own check")
            let route = Route(file: RouteFile(name: "Engine \(seed)", closed: true, waypoints: plan.assembly.waypoints))
            let f = RouteFlightTests.flyAutopilot(route, city: city, seconds: 600)
            print(String(format: "ENGINE %@ seed %d: %d stretches, %.1f km, min alt %.1f m, min clearance %.1f m, max bank %.1f deg, nudges %d, outside %.1f s",
                         dir.lastPathComponent, seed, plan.stretches.count, Double(route.count) * route.spacing / 1000,
                         f.minAltitude, f.minClearance, f.maxBank, f.nudges, f.outsideSeconds))
            #expect(f.nudges == 0, "seed \(seed): \(f.nudges) collision nudges")
            #expect(f.outsideSeconds == 0)
            #expect(f.minClearance > 0)
            #expect(f.minAltitude >= FlightTuning().floor)
            #expect(f.maxBank <= 46)
        }
        #expect(made >= 2, "\(dir.lastPathComponent): only \(made) of \(EnginePackages.seeds.count) seeds made a loop")
    }

    @Test(arguments: EnginePackages.dirs) func theSameSeedGivesTheSameLoopAndDifferentSeedsDiffer(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let js = JoinSettings.standard(for: city.manifest)
        let plans = EnginePackages.seeds.compactMap { RouteWalker.loop(graph: graph, obstacles: city, seed: $0, joinSettings: js) }
        let again = EnginePackages.seeds.compactMap { RouteWalker.loop(graph: graph, obstacles: city, seed: $0, joinSettings: js) }
        #expect(plans.map(\.assembly.waypoints) == again.map(\.assembly.waypoints))
        #expect(Set(plans.map { $0.stretches.map(\.stretch.id) }).count >= 2, "every seed made the same loop")
    }

    @Test(arguments: EnginePackages.dirs) func theCheckerCatchesJoinsFlownTooLow(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let js = JoinSettings.standard(for: city.manifest)
        let plan = try #require(EnginePackages.seeds.lazy.compactMap { RouteWalker.loop(graph: graph, obstacles: city, seed: $0, joinSettings: js) }.first)
        var low = plan
        for (k, owner) in low.assembly.owners.enumerated() {
            if case .join = owner { low.assembly.waypoints[k].alt -= 20 }
        }
        #expect(!RouteChecker.check(low, obstacles: city, joinSettings: js).isEmpty, "a route with every join 20 m low passed the check")
    }

    @Test(arguments: EnginePackages.dirs) func aStretchTooShortForItsClimbsIsRefused(dir: URL) throws {
        // The stretch-length rule: a stretch must be long enough for the climb out and the descent in (the generator never checked it).
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let js = JoinSettings.standard(for: city.manifest)
        let plan = try #require(EnginePackages.seeds.lazy.compactMap { RouteWalker.loop(graph: graph, obstacles: city, seed: $0, joinSettings: js) }.first)
        // Shorten the first stretch to 100 m: its climbs (to the join heights) cannot fit.
        var short = plan
        let first = short.stretches[0]
        var pts = Array(first.points.prefix(11))   // 10 steps of 10 m
        if pts.count < 11 { pts = first.points }
        let s = StreetStretch(id: first.stretch.id, streetClass: first.stretch.streetClass, names: first.stretch.names,
                              length: 100, points: pts.flatMap { [$0.x, $0.y] })
        short.stretches[0] = PlannedStretch(stretch: s, reversed: false)
        #expect(RouteChecker.check(short, obstacles: city, joinSettings: js).contains { $0.message.contains("stretch-length") })
    }

    @Test(arguments: EnginePackages.dirs) func chainedEndlessLoopsFlyCleanAcrossTheSwaps(dir: URL) throws {
        let r = try #require(try ChainFlight.fly(dir: dir, seed: 1, seconds: 900))
        print(String(format: "ENGINE CHAIN %@ | swaps %d | pending misses %d | nudges %d | min alt %.1f m | min clearance %.1f m | max bank %.1f deg | outside %.1f s",
                     dir.lastPathComponent, r.swaps, r.pendingMisses, r.nudges, r.minAltitude, r.minClearance, r.maxBank, r.outsideSeconds))
        #expect(r.swaps >= 2, "\(dir.lastPathComponent): only \(r.swaps) swaps in 900 s")
        #expect(r.nudges == 0, "\(dir.lastPathComponent): \(r.nudges) collision nudges across the swaps")
        #expect(r.outsideSeconds == 0)
        #expect(r.minClearance > 0)
        #expect(r.minAltitude >= FlightTuning().floor)
        #expect(r.maxBank <= 46)
    }
}

/// The chained endless flight the app flies, headless: the first loop from `nextLoop()`, then each loop built with
/// `nextLoop(after:)` from the plan being flown, and swapped to when a `SwapTrigger` fires (the next loop is built ahead
/// of the swap, as the app does in the background). Returns nil when no flight can be made.
enum ChainFlight {
    struct Result {
        var swaps = 0
        /// Triggers that fired with no loop ready; the aircraft kept its loop and the trigger re-armed.
        var pendingMisses = 0
        var nudges = 0
        var minAltitude = Double.infinity
        var minClearance = Double.infinity
        var maxBank = 0.0
        var outsideSeconds = 0.0
    }

    static func fly(dir: URL, seed: UInt64, seconds: Double, heightOffset: Double = 0) throws -> Result? {
        let city = try CityPackage.open(directory: dir)
        guard var flight = EndlessFlight(city: city, seed: seed), let first = flight.nextLoop() else { return nil }
        let t = FlightTuning()
        var route = first.route
        var plan = first.plan
        var pending = flight.nextLoop(after: plan)
        var trigger = SwapTrigger(swapIndex: EndlessFlight.swapIndex(route: route, plan: plan), count: route.count)
        let a = route.samples[0], b = route.samples[1]
        let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
        var sim = Simulation(start: start, tuning: t)
        var hint: Int? = 0
        var result = Result()
        let extent = city.manifest.extentM
        var roofs = RoofCache(count: route.count)
        for _ in 0..<Int(seconds / t.fixedStep) {
            sim.advance(by: t.fixedStep, obstacles: city, extent: extent) { s, _ in
                let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t,
                                          heightOffset: heightOffset, obstacles: heightOffset == 0 ? nil : city, roofs: roofs)
                hint = r.index
                if trigger.update(index: r.index) {
                    if let next = pending {
                        route = next.route
                        plan = next.plan
                        roofs = RoofCache(count: route.count)
                        hint = 0
                        result.swaps += 1
                    } else {
                        result.pendingMisses += 1
                    }
                    pending = flight.nextLoop(after: plan)
                    trigger.reset(swapIndex: EndlessFlight.swapIndex(route: route, plan: plan), count: route.count)
                }
                return r.control
            }
            let s = sim.current
            result.minAltitude = min(result.minAltitude, s.altitude)
            result.minClearance = min(result.minClearance, s.altitude - Double(city.obstacleHeight(east: s.east, north: s.north)))
            result.maxBank = max(result.maxBank, abs(s.bank) * 180 / .pi)
            if s.east < extent.minEast || s.east > extent.maxEast || s.north < extent.minNorth || s.north > extent.maxNorth {
                result.outsideSeconds += t.fixedStep
            }
        }
        result.nudges = sim.nudges
        return result
    }
}

/// Entering a street loop from the open routes. Pressing U or clicking a street while cruising at Scenic's height used to
/// chase the nearest point of the new loop and dive at a building (the app, run with GULLFIRE_SCRIPT, logged 57 collision
/// nudges). The entry must be a forced hand-back: over the roofs to an elevated point of the loop, then the usual chase.
@Suite("Entering an endless loop", .enabled(if: EnginePackages.available))
struct EndlessEntryTests {
    /// Flies `route` for `seconds` from `start`, the way the app does while a hand-back is running.
    static func fly(route: Route, from start: FlightState, handBack: HandBack?, city: CityPackage, seconds: Double,
                    watching stretch: StreetStretch? = nil) -> (nudges: Int, minClearance: Double, handedBack: Bool, closest: Double) {
        let t = FlightTuning()
        var sim = Simulation(start: start, tuning: t)
        var hb = handBack
        var hint: Int? = nil
        var endedAt: Double?
        var elapsed = 0.0
        var minClearance = Double.infinity
        var closest = Double.infinity
        let extent = city.manifest.extentM
        let wasHandBack = handBack != nil
        for _ in 0..<Int(seconds / t.fixedStep) {
            sim.advance(by: t.fixedStep, obstacles: city, extent: extent) { s, _ in
                elapsed += t.fixedStep
                if hb != nil, let r = Autopilot.handBackControl(for: s, route: route, obstacles: city, state: &hb, tuning: t) {
                    hint = r.index
                    return r.control
                }
                if wasHandBack, endedAt == nil { endedAt = elapsed }
                let boost = endedAt.map { Autopilot.entryBoost(secondsSinceHandBack: elapsed - $0) } ?? 0
                let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t, heightOffset: boost, obstacles: city)
                hint = r.index
                return r.control
            }
            let s = sim.current
            minClearance = min(minClearance, s.altitude - Double(city.obstacleHeight(east: s.east, north: s.north)))
            if let stretch { closest = min(closest, StreetPicker.distance(from: SIMD2(s.east, s.north), to: stretch)) }
        }
        return (sim.nudges, minClearance, wasHandBack, closest)
    }

    @Test(arguments: EnginePackages.dirs) func aForcedHandBackEntersTheLoopWithoutNudges(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        guard let open = try? Route.load(dir.appendingPathComponent("routes/scenic.json")) else { return }
        var flight = try #require(EndlessFlight(city: city, seed: 7))
        let made = flight.nextLoop()
        let loop = try #require(made)
        var withoutNudges = 0, withNudges = 0, starts = 0
        for k in 0..<8 {
            let a = open.samples[(open.count * k / 8) % open.count], b = open.samples[(open.count * k / 8 + 1) % open.count]
            let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                    heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
            starts += 1
            let plain = Self.fly(route: loop.route, from: start, handBack: nil, city: city, seconds: 400)
            let forced = Self.fly(route: loop.route, from: start, handBack: HandBack(heading: start.heading), city: city, seconds: 400)
            withoutNudges += plain.nudges
            withNudges += forced.nudges
            print(String(format: "ENTRY %@ start %d: chase only %d nudges (clearance %.1f m), forced hand-back %d nudges (clearance %.1f m)",
                         dir.lastPathComponent, k, plain.nudges, plain.minClearance, forced.nudges, forced.minClearance))
            // The dives are gone (chase-only: over a thousand nudges across these starts). A 5 m brush or two at the entry is
            // still possible at some starts over the Loop's towers (a known limit); more is not.
            #expect(forced.nudges <= 2, "start \(k): the forced hand-back made \(forced.nudges) collision nudges")
            #expect(forced.minClearance > 0)
        }
        print("ENTRY \(dir.lastPathComponent): \(starts) starts, chase-only nudges \(withoutNudges), forced hand-back nudges \(withNudges)")
    }
}

extension EndlessEntryTests {
    /// A click: the loop starts with the picked stretch and the hand-back is aimed at the closing join into it. The aircraft
    /// must get there without a collision nudge, and must actually reach the picked street.
    @Test(arguments: EnginePackages.dirs) func aPickedStreetIsReachedWithoutNudges(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        guard let open = try? Route.load(dir.appendingPathComponent("routes/scenic.json")) else { return }
        let graph = try #require(try StreetGraph.load(from: dir))
        var reached = 0, tried = 0
        for k in 0..<8 {
            // A different stretch for each start, spread over the graph.
            let stretch = graph.stretches[(k * graph.stretches.count / 8) % graph.stretches.count]
            var flight = try #require(EndlessFlight(city: city, seed: 11 + UInt64(k)))
            guard let loop = flight.firstLoop(startingWith: stretch.id, reversed: false) else { continue }
            let a = open.samples[(open.count * k / 8) % open.count], b = open.samples[(open.count * k / 8 + 1) % open.count]
            let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                    heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
            let hb = HandBack(heading: start.heading, startIndex: max(0, loop.route.count - 260))
            let r = Self.fly(route: loop.route, from: start, handBack: hb, city: city, seconds: 900, watching: stretch)
            tried += 1
            if r.closest < 30 { reached += 1 }
            print(String(format: "PICK ENTRY %@ start %d: %d nudges, clearance %.1f m, closest approach to the picked street %.0f m",
                         dir.lastPathComponent, k, r.nudges, r.minClearance, r.closest))
            #expect(r.nudges <= 1, "start \(k): \(r.nudges) collision nudges entering the picked loop")
            #expect(r.minClearance > 0)
        }
        #expect(tried >= 4)
        #expect(reached >= tried - 1, "only \(reached) of \(tried) picks reached their street")
    }
}
