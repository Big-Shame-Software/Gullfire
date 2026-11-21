import Foundation
import Testing
@testable import GullfireKit

/// The route checker on the shipped Chicago street routes: a route the generator wrote must pass, and the checks must
/// catch the two ways a route can be wrong that the generator did not check (joins flown low, stretches too short
/// for their climbs).
@Suite("Route checker", .enabled(if: AssemblerFiles.available))
struct RouteCheckerTests {
    /// The plan for a seed, rebuilt the way RouteAssemblerTests rebuilds it.
    static func plan(seed: Int) throws -> (RoutePlan, CityPackage, JoinSettings) {
        let city = try CityPackage.open(directory: AssemblerFiles.dir)
        let graph = try #require(try StreetGraph.load(fileAt: AssemblerFiles.vettedGraph))
        let report = try JSONDecoder().decode(AssemblerFiles.Report.self, from: Data(contentsOf: AssemblerFiles.report(seed)))
        let seq: [PlannedStretch] = try report.stretches.map { r in
            let s = try #require(graph.stretches.first { $0.id == r.id }, "stretch \(r.id) is not in the street graph")
            return PlannedStretch(stretch: s, reversed: r.reversed)
        }
        let settings = JoinSettings.standard(for: city.manifest)
        var joins: [Join] = []
        for i in seq.indices {
            let a = seq[i], b = seq[(i + 1) % seq.count]
            let j = try #require(JoinBuilder.build(from: a.end, heading: a.endHeading, to: b.start, heading: b.startHeading,
                                                   obstacles: city, settings: settings), "join \(i) is not feasible")
            joins.append(j)
        }
        let asm = RouteAssembler.assemble(seq, joins: joins, settings: .standard)
        return (RoutePlan(stretches: seq, joins: joins, assembly: asm), city, settings)
    }

    @Test(arguments: AssemblerFiles.seeds) func theShippedRoutePassesTheCheck(seed: Int) throws {
        let (plan, city, js) = try Self.plan(seed: seed)
        let fails = RouteChecker.check(plan, obstacles: city, joinSettings: js)
        print("CHECKER street-\(seed): \(fails.count) failures")
        #expect(fails.isEmpty, "street-\(seed): \(fails.prefix(5).map(\.message))")
    }

    @Test(arguments: AssemblerFiles.seeds) func joinsFlownTwentyMetresLowAreRefused(seed: Int) throws {
        let (base, city, js) = try Self.plan(seed: seed)
        var plan = base
        for k in plan.assembly.owners.indices {
            if case .join = plan.assembly.owners[k] { plan.assembly.waypoints[k].alt -= 20 }
        }
        let fails = RouteChecker.check(plan, obstacles: city, joinSettings: js)
        #expect(!fails.isEmpty, "a route with every join 20 m low passed the check")
    }

    @Test(arguments: AssemblerFiles.seeds) func aStretchTooShortForItsClimbsIsRefused(seed: Int) throws {
        let (base, city, js) = try Self.plan(seed: seed)
        var plan = base
        let first = plan.stretches[0]
        // 11 points, 10 m apart: 100 m of street, too short for the climb out and the descent in.
        let short = StreetStretch(id: first.stretch.id, streetClass: first.stretch.streetClass, names: first.stretch.names,
                                  length: 100, points: Array(first.stretch.points.prefix(22)))
        plan.stretches[0] = PlannedStretch(stretch: short, reversed: first.reversed)
        let fails = RouteChecker.check(plan, obstacles: city, joinSettings: js)
        #expect(fails.contains { $0.message.contains("stretch-length") }, "a 100 m stretch was not refused for its climbs")
    }
}
