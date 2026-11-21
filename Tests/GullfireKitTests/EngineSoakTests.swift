import Foundation
import Testing
@testable import GullfireKit

/// The route-engine soak: flies every loop the walker assembles from the street graph for GULLFIRE_SOAK_MINUTES of simulated
/// flight, headless, on the Swift autopilot, with zero collision nudges, the same checks as RouteSoak. Off unless the variable
/// is set (GULLFIRE_SOAK_HEIGHT also applies):
///
///     GULLFIRE_SOAK_MINUTES=60 swift test --filter EngineSoak
@Suite("EngineSoak", .serialized, .enabled(if: SoakSetting.minutes != nil && EnginePackages.available))
struct EngineSoak {
    struct Case: Sendable, CustomTestStringConvertible {
        let dir: URL
        let seed: UInt64
        var testDescription: String { "\(dir.lastPathComponent) seed \(seed)" }
    }
    static let cases: [Case] = EnginePackages.dirs.flatMap { d in EnginePackages.seeds.map { Case(dir: d, seed: $0) } }

    @Test(arguments: cases) func soak(c: Case) throws {
        let minutes = try #require(SoakSetting.minutes)
        let city = try CityPackage.open(directory: c.dir)
        let graph = try #require(try StreetGraph.load(from: c.dir))
        let js = JoinSettings.standard(for: city.manifest)
        guard let plan = RouteWalker.loop(graph: graph, obstacles: city, seed: c.seed, joinSettings: js) else {
            print("ENGINE SOAK \(c.testDescription): no loop for this seed")
            return
        }
        let route = Route(file: RouteFile(name: "Engine \(c.seed)", closed: true, waypoints: plan.assembly.waypoints))
        let t = FlightTuning()
        let a = route.samples[0], b = route.samples[1]
        let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
        var sim = Simulation(start: start, tuning: t)
        var hint: Int? = 0
        var laps = 0
        let extent = city.manifest.extentM
        let steps = Int(minutes * 60 / t.fixedStep)
        var minAltitude = Double.infinity, minClearance = Double.infinity, maxBank = 0.0, outside = 0.0
        let rss0 = RouteSoak.residentMB()
        let roofs = RoofCache(count: route.count)
        for _ in 1...steps {
            sim.advance(by: t.fixedStep, obstacles: city, extent: extent) { s, _ in
                let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t,
                                          heightOffset: SoakSetting.height, obstacles: SoakSetting.height == 0 ? nil : city, roofs: roofs)
                if let h = hint, r.index < h - route.count / 2 { laps += 1 }
                hint = r.index
                return r.control
            }
            let s = sim.current
            minAltitude = min(minAltitude, s.altitude)
            minClearance = min(minClearance, s.altitude - Double(city.obstacleHeight(east: s.east, north: s.north)))
            maxBank = max(maxBank, abs(s.bank) * 180 / .pi)
            if s.east < extent.minEast || s.east > extent.maxEast || s.north < extent.minNorth || s.north > extent.maxNorth { outside += t.fixedStep }
        }
        let rssEnd = RouteSoak.residentMB()
        print(String(format: "ENGINE SOAK %@ | minutes %.0f | height %+.0f | stretches %d | laps %d | nudges %d | min alt %.1f m | min clearance %.1f m | max bank %.1f deg | outside %.1f s | RSS %.0f to %.0f MB",
                     c.testDescription, minutes, SoakSetting.height, plan.stretches.count, laps, sim.nudges, minAltitude, minClearance, maxBank, outside, rss0, rssEnd))
        #expect(sim.nudges == 0)
        #expect(outside == 0)
        #expect(minClearance > 0)
        #expect(minAltitude >= t.floor)
        #expect(laps >= 2)
    }
}

/// The chained endless flight soak: the same loops and swaps as the app flies (see `ChainFlight`), for
/// GULLFIRE_SOAK_MINUTES of simulated flight per case, with GULLFIRE_SOAK_HEIGHT applied. Zero collision nudges is the gate:
///
///     GULLFIRE_SOAK_MINUTES=60 swift test --filter EngineChainSoak
@Suite("EngineChainSoak", .serialized, .enabled(if: SoakSetting.minutes != nil && EnginePackages.available))
struct EngineChainSoak {
    @Test(arguments: EngineSoak.cases) func chain(c: EngineSoak.Case) throws {
        let minutes = try #require(SoakSetting.minutes)
        let r = try #require(try ChainFlight.fly(dir: c.dir, seed: c.seed, seconds: minutes * 60, heightOffset: SoakSetting.height))
        print(String(format: "ENGINE CHAIN SOAK %@ | minutes %.0f | height %+.0f | swaps %d | pending misses %d | nudges %d | min alt %.1f m | min clearance %.1f m | max bank %.1f deg | outside %.1f s",
                     c.testDescription, minutes, SoakSetting.height, r.swaps, r.pendingMisses, r.nudges, r.minAltitude, r.minClearance, r.maxBank, r.outsideSeconds))
        #expect(r.nudges == 0)
        #expect(r.outsideSeconds == 0)
        #expect(r.minClearance > 0)
        #expect(r.minAltitude >= FlightTuning().floor)
        #expect(r.maxBank <= 46)
        #expect(r.swaps >= 2)
    }
}
