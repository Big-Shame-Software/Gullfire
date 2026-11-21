import Foundation
import GullfireKit

// usage: gullfire-pack <city-directory>
// Reads <city-directory>/raw and writes the city package beside it.

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 3 else { fail("usage: gullfire-pack <city-directory> | gullfire-pack routes <city-directory> | gullfire-pack loops <city-directory>", status: 2) }

if arguments[1] == "routes" {
    // The River loop and its altitude profile. Reads the chains and the obstacle grid.
    guard arguments.count == 3 else { fail("usage: gullfire-pack routes <city-directory>", status: 2) }
    let city = URL(fileURLWithPath: arguments[2], isDirectory: true)
    do {
        let package = try CityPackage.open(directory: city)
        let chains = try JSONDecoder().decode(RiverChains.self, from: Data(contentsOf: city.appendingPathComponent("routes/river_chains.json")))
        let profile: RiverRoute.Profile
        if let path = chains.path, path.count > 1 {
            // A city whose config names its river: one joined path and a sideways shift for the return leg.
            profile = RiverRoute.build(path: path, returnShift: chains.returnShift ?? [0, RiverRoute.returnOffset],
                                       obstacles: package, tuning: FlightTuning())
        } else {
            let branch = chains.chains[0].points
            let fork = branch[0]
            guard let stem = chains.chains.dropFirst().first(where: { c in
                guard let end = c.points.last else { return false }
                return ((end[0] - fork[0]) * (end[0] - fork[0]) + (end[1] - fork[1]) * (end[1] - fork[1])).squareRoot() < 120
            })?.points else { fail("no main stem ends at the fork", status: 1) }
            profile = RiverRoute.build(stem: stem, branch: branch, obstacles: package, tuning: FlightTuning())
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile.route)
        try data.write(to: city.appendingPathComponent("routes/river.json"))
        print(String(format: "river: %d waypoints; gradient %.3f (tan of the %.0f deg pitch limit)",
                     profile.route.waypoints.count, profile.gradient, FlightTuning().pitchLimit * 180 / Double.pi))
        print(String(format: "low leg at 60 m for %.1f%% of its length", profile.shareAtFloor * 100))
        for (n, st) in profile.stretches.enumerated() {
            print(String(format: "stretch %d: from E %.0f N %.0f (%.0f m) to E %.0f N %.0f (%.0f m), peak %.0f m, caused by a %.0f m building at E %.0f N %.0f",
                         n + 1, st.startEast, st.startNorth, st.startDistance, st.endEast, st.endNorth, st.endDistance,
                         st.peakAltitude, st.causeHeight, st.causeEast, st.causeNorth))
        }
        print("stretches: \(profile.stretches.count)")
    } catch {
        fail("gullfire-pack routes: \(error)", status: 1)
    }
    exit(0)
}
if arguments[1] == "loops" {
    // Marks which street stretches can start a loop, in each direction, by running the walker that endless flight uses.
    // Reads and rewrites <city-directory>/streets.json (made by Tools/make_street_graph.py).
    guard arguments.count == 3 else { fail("usage: gullfire-pack loops <city-directory>", status: 2) }
    let city = URL(fileURLWithPath: arguments[2], isDirectory: true)
    do {
        let package = try CityPackage.open(directory: city)
        guard var graph = try StreetGraph.load(from: city) else { fail("gullfire-pack loops: no streets.json in \(city.path)", status: 1) }
        let settings = JoinSettings.standard(for: package.manifest)
        let count = graph.stretches.count
        let snapshot = graph
        final class Marks: @unchecked Sendable {
            let lock = NSLock()
            var values: [[Bool]]
            init(_ n: Int) { values = Array(repeating: [false, false], count: n) }
            func set(_ i: Int, _ r: Int, _ v: Bool) { lock.lock(); values[i][r] = v; lock.unlock() }
        }
        let marks = Marks(count)
        // A stretch works in a direction when the walker makes a loop from it with any of the first three seeds.
        DispatchQueue.concurrentPerform(iterations: count * 2) { job in
            let index = job / 2, reversed = job % 2 == 1
            let id = snapshot.stretches[index].id
            let works = (1...3).contains { seed in
                RouteWalker.loop(graph: snapshot, obstacles: package, seed: UInt64(seed), joinSettings: settings,
                                 startingWith: (id: id, reversed: reversed)) != nil
            }
            marks.set(index, reversed ? 1 : 0, works)
        }
        for i in 0..<count { graph.stretches[i].loops = marks.values[i] }
        try JSONEncoder().encode(graph).write(to: city.appendingPathComponent(StreetGraph.fileName))
        let any = graph.stretches.filter(\.canStartAny).count
        print("loops: \(any) of \(count) stretches can start a loop (forward \(marks.values.filter { $0[0] }.count), reversed \(marks.values.filter { $0[1] }.count))")
    } catch {
        fail("gullfire-pack loops: \(error)", status: 1)
    }
    exit(0)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)

do {
    let m = try PackageWriter.write(cityDirectory: directory, outOfCore: ProcessInfo.processInfo.environment["GULLFIRE_OUT_OF_CORE"] == "1")
    print("city \(m.name): \(m.solidCount) solids, \(m.solidTriangleCount) triangles")
    print("segments \(m.segmentCount): " + m.lineGroups.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
    print("heights: measured \(m.heights.measured), floors \(m.heights.floors), default \(m.heights.defaulted)")
    print("obstacle grid \(m.obstacleGrid.cols) x \(m.obstacleGrid.rows) at \(m.obstacleGrid.cellSizeM) m")
    if let t = m.tiles {
        print("tiles: \(t.entries.count) of \(t.cols) x \(t.rows) at \(t.sizeM) m")
    }
} catch {
    fail("gullfire-pack: \(error)", status: 1)
}

struct RiverChains: Decodable {
    struct Chain: Decodable { let points: [[Double]] }
    let chains: [Chain]
    /// Present when the city config names its river (Vienna); absent for Chicago.
    let path: [[Double]]?
    let returnShift: [Double]?
}
