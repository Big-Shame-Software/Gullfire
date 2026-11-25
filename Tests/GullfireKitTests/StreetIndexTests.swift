import Foundation
import simd
import Testing
@testable import GullfireKit

/// A seeded generator, so the random hit points are the same on every run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Flat open ground: every point is at height zero.
private struct IndexOpenGround: ObstacleSource {
    func height(east: Double, north: Double) -> Float { 0 }
}

/// A camera 60 m above a hit point, looking almost straight down (so the picker's ground hit is that point, to about 1 m).
private func cameraAbove(_ hit: SIMD2<Double>) -> Camera {
    Camera(eye: SIMD3(Float(hit.x), 60, Float(-hit.y)), target: SIMD3(Float(hit.x), 0, Float(-hit.y) - 0.01))
}

@Suite("Street index")
struct StreetIndexTests {
    /// Stretches that cross cell borders (the grid is 500 m), one that only touches a cell corner, a single point, a
    /// stretch that cannot start a loop, and one that sets the grid's south-west corner.
    static func syntheticGraph() -> StreetGraph {
        func stretch(_ id: String, _ points: [SIMD2<Double>], loops: [Bool]? = nil) -> StreetStretch {
            StreetStretch(id: id, streetClass: "primary", names: [id], length: 0,
                          points: points.flatMap { [$0.x, $0.y] }, loops: loops)
        }
        let stretches = [
            stretch("east", stride(from: -1000.0, through: 1000.0, by: 100).map { SIMD2($0, 0) }),
            stretch("north", stride(from: -800.0, through: 800.0, by: 100).map { SIMD2(250, $0) }),
            stretch("bent", [SIMD2(-900, 900), SIMD2(-100, 700), SIMD2(300, 1000), SIMD2(700, 300)]),
            // The segment passes exactly through the cell corner at (-500, -500).
            stretch("corner", [SIMD2(-510, -490), SIMD2(-490, -510)]),
            stretch("single", [SIMD2(-300, 300)]),
            stretch("closed", [SIMD2(600, -900), SIMD2(900, -900)], loops: [false, false]),
            stretch("south-west", [SIMD2(-1000, -1000)]),
        ]
        return StreetGraph(format: 1, altitude: 15, spacing: 100, stretches: stretches)
    }

    static func randomHits(_ count: Int, within box: ClosedRange<Double>, seed: UInt64) -> [SIMD2<Double>] {
        var rng = SplitMix(state: seed)
        return (0..<count).map { _ in
            SIMD2(Double.random(in: box, using: &rng), Double.random(in: box, using: &rng))
        }
    }

    @Test func indexedCandidatesMatchTheLinearScan() {
        let graph = Self.syntheticGraph()
        let index = StreetIndex(graph: graph)
        for hit in Self.randomHits(500, within: -1200...1200, seed: 7) {
            for radius in [5.0, 80, 300, 1200] {
                let found = index.candidateIndices(near: hit, within: radius)
                #expect(found == found.sorted())
                #expect(Set(found).count == found.count)
                for (i, stretch) in graph.stretches.enumerated() where stretch.canStartAny {
                    if StreetPicker.distance(from: hit, to: stretch) <= radius {
                        #expect(found.contains(i), "stretch \(stretch.id) within \(radius) m of \(hit) is missing")
                    }
                }
            }
            let camera = cameraAbove(hit)
            for maxSnap in [10.0, 80, 300, 1200] {
                let linear = StreetPicker.candidates(camera: camera, ndc: SIMD2(0, 0), aspect: 1.5, aircraftHeading: 0.3,
                                                     graph: graph, obstacles: IndexOpenGround(), maxSnap: maxSnap, limit: 6)
                let indexed = StreetPicker.candidates(camera: camera, ndc: SIMD2(0, 0), aspect: 1.5, aircraftHeading: 0.3,
                                                      graph: graph, obstacles: IndexOpenGround(), maxSnap: maxSnap, limit: 6,
                                                      index: index)
                #expect(linear == indexed)
                let single = StreetPicker.pick(camera: camera, ndc: SIMD2(0, 0), aspect: 1.5, aircraftHeading: 0.3,
                                               graph: graph, obstacles: IndexOpenGround(), maxSnap: maxSnap)
                let singleIndexed = StreetPicker.pick(camera: camera, ndc: SIMD2(0, 0), aspect: 1.5, aircraftHeading: 0.3,
                                                      graph: graph, obstacles: IndexOpenGround(), maxSnap: maxSnap, index: index)
                #expect(single == singleIndexed)
            }
            for radius in [300.0, 1500] {
                let linear = StreetOverlay.available(in: graph, near: hit, radius: radius, maxSegments: 4)
                let indexed = StreetOverlay.available(in: graph, near: hit, radius: radius, maxSegments: 4, index: index)
                #expect(linear == indexed)
            }
        }
    }

    @Test func emptyGraphGivesNoCandidates() {
        let graph = StreetGraph(format: 1, altitude: 15, spacing: 100, stretches: [])
        let index = StreetIndex(graph: graph)
        #expect(index.candidateIndices(near: SIMD2(0, 0), within: 1000).isEmpty)
    }
}

/// The real-package timing run. Set GULLFIRE_ENGINE_DIRS to a package folder that holds a streets.json (the first path is used).
enum StreetIndexTimingDir {
    static let dir: URL? = {
        guard let first = ProcessInfo.processInfo.environment["GULLFIRE_ENGINE_DIRS"]?.split(separator: ":").first else { return nil }
        let url = URL(fileURLWithPath: String(first), isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(StreetGraph.fileName).path) ? url : nil
    }()
}

@Suite("Street index timing", .enabled(if: StreetIndexTimingDir.dir != nil))
struct StreetIndexTimingTests {
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test func indexedPicksAreEqualAndQuick() throws {
        let dir = try #require(StreetIndexTimingDir.dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let clock = ContinuousClock()

        var index: StreetIndex?
        let build = clock.measure { index = StreetIndex(graph: graph) }
        let streetIndex = try #require(index)

        // Random hits inside the bounding box of every stretch point.
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for stretch in graph.stretches {
            for p in stretch.polyline {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        var rng = SplitMix(state: 11)
        let hits: [SIMD2<Double>] = (0..<2000).map { _ in
            SIMD2(Double.random(in: minX...maxX, using: &rng), Double.random(in: minY...maxY, using: &rng))
        }

        func pick(_ hit: SIMD2<Double>, _ index: StreetIndex?) -> [StreetPick] {
            StreetPicker.candidates(camera: cameraAbove(hit), ndc: SIMD2(0, 0), aspect: 1.5, aircraftHeading: 0,
                                    graph: graph, obstacles: IndexOpenGround(), maxSnap: 80, limit: 6, index: index)
        }

        var indexedResults: [[StreetPick]] = []
        indexedResults.reserveCapacity(hits.count)
        let indexedTime = clock.measure {
            for hit in hits { indexedResults.append(pick(hit, streetIndex)) }
        }

        var equal = 0
        for (k, hit) in hits.enumerated() where pick(hit, nil) == indexedResults[k] {
            equal += 1
        }

        let perPick = Self.milliseconds(indexedTime) / Double(hits.count)
        let buildMs = Self.milliseconds(build)
        print(String(format: "STREET INDEX %@ | build %.1f ms | per pick %.3f ms | equal to linear: %d of %d",
                     dir.lastPathComponent, buildMs, perPick, equal, hits.count))

        #expect(equal == hits.count)
        #expect(perPick < 1.0)
    }
}
