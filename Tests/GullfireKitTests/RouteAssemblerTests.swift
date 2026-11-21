import Foundation
import Testing
@testable import GullfireKit

/// Route engine, step 2: the Swift assembler must write the same waypoints as the generator (`assemble` in
/// Tools/make_street_routes.py). The shipped street routes come with a report that names the stretches each one uses, so the
/// test rebuilds the joins in Swift from the street graph and compares the result with the route file the generator wrote.
enum AssemblerFiles {
    static let dir = PackageTests.chicago
    static func route(_ seed: Int) -> URL { dir.appendingPathComponent("routes/street-\(seed).json") }
    static func report(_ seed: Int) -> URL { dir.appendingPathComponent("routes/street-\(seed).report.json") }
    static let seeds = [1, 2, 3]
    /// The shipped street routes were made from the vetted graph (stretches of 600 m or more, bends of 12 m), which is not the
    /// graph the app flies now (300 m, 30 m). `Tools/make_street_graph.py --min-run 600 --bend 12 --out <city>/spike/streets-vetted.json`.
    static let vettedGraph = dir.appendingPathComponent("spike/streets-vetted.json")
    static var available: Bool {
        PackageTests.built
            && FileManager.default.fileExists(atPath: vettedGraph.path)
            && seeds.allSatisfy { FileManager.default.fileExists(atPath: route($0).path) && FileManager.default.fileExists(atPath: report($0).path) }
    }
    struct Report: Decodable {
        struct Stretch: Decodable { let id: String; let reversed: Bool }
        let stretches: [Stretch]
    }
}

@Suite("Route assembler", .enabled(if: AssemblerFiles.available))
struct RouteAssemblerTests {
    /// The generator wrote its route in float64; the Swift joins agree with the generator's to under a millimetre
    /// (JoinBuilderTests), so the waypoints agree to a few centimetres.
    static let tolerance = 0.05

    @Test(arguments: AssemblerFiles.seeds) func assembledWaypointsMatchTheShippedRoute(seed: Int) throws {
        let city = try CityPackage.open(directory: AssemblerFiles.dir)
        let graph = try #require(try StreetGraph.load(fileAt: AssemblerFiles.vettedGraph))
        let report = try JSONDecoder().decode(AssemblerFiles.Report.self, from: Data(contentsOf: AssemblerFiles.report(seed)))
        let shipped = try JSONDecoder().decode(RouteFile.self, from: Data(contentsOf: AssemblerFiles.route(seed)))
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
        #expect(asm.waypoints.count == shipped.waypoints.count, "\(asm.waypoints.count) waypoints, generator \(shipped.waypoints.count)")
        guard asm.waypoints.count == shipped.waypoints.count else { return }
        var worst = 0.0
        for (k, w) in asm.waypoints.enumerated() {
            let s = shipped.waypoints[k]
            worst = max(worst, abs(w.east - s.east), abs(w.north - s.north), abs(w.alt - s.alt), abs(w.speedKt - s.speedKt))
        }
        print(String(format: "ASSEMBLER PARITY street-%d: %d waypoints, worst difference %.4f", seed, asm.waypoints.count, worst))
        #expect(worst < Self.tolerance)
        #expect(asm.owners.count == asm.waypoints.count)
    }
}
