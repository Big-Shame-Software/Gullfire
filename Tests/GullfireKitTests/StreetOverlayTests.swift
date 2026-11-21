import Foundation
import simd
import Testing
@testable import GullfireKit

@Suite("Street overlay")
struct StreetOverlayTests {
    /// A stretch of `count` points from east `east0` going north, 10 m apart, starting at north `north0`.
    static func northRun(id: String, east: Double, north0: Double, count: Int) -> StreetStretch {
        let points = (0..<count).flatMap { [east, north0 + 10 * Double($0)] }
        return StreetStretch(id: id, streetClass: "residential", names: [id], length: 10 * Double(count - 1), points: points)
    }

    @Test func segmentsMapEastNorthToRenderSpaceWithNegativeZ() {
        // Points (east 3, north 5) then (east -2, north 7): x = east, y = height, z = -north.
        let stretch = StreetStretch(id: "a", streetClass: "", names: [], length: 0, points: [3, 5, -2, 7])
        let s = StreetOverlay.segments(for: stretch, height: 4)
        #expect(s == [3, 4, -5, -2, 4, -7])
    }

    @Test func segmentCountIsPointsMinusOne() {
        let stretch = Self.northRun(id: "a", east: 0, north0: 0, count: 6)
        let s = StreetOverlay.segments(for: stretch, height: 2)
        #expect(s.count == (6 - 1) * 6)
        // Every segment starts where the previous one ended.
        for k in 1..<5 {
            #expect(s[k * 6] == s[(k - 1) * 6 + 3])
            #expect(s[k * 6 + 2] == s[(k - 1) * 6 + 5])
        }
    }

    @Test func oneOrEmptyPointStretchGivesNoSegments() {
        let one = StreetStretch(id: "p", streetClass: "", names: [], length: 0, points: [1, 2])
        let none = StreetStretch(id: "e", streetClass: "", names: [], length: 0, points: [])
        #expect(StreetOverlay.segments(for: one, height: 4).isEmpty)
        #expect(StreetOverlay.segments(for: none, height: 4).isEmpty)
    }

    @Test func availableIsNearestFirst() {
        let far = Self.northRun(id: "far", east: 300, north0: 0, count: 5)
        let mid = Self.northRun(id: "mid", east: 100, north0: 0, count: 5)
        let near = Self.northRun(id: "near", east: 0, north0: 0, count: 5)
        let graph = StreetGraph(format: 1, altitude: 4, spacing: 10, stretches: [far, mid, near])
        let found = StreetOverlay.available(in: graph, near: SIMD2(0, 0), radius: 1000, maxSegments: 100)
        #expect(found == [2, 1, 0])
    }

    @Test func availableLeavesOutStretchesBeyondTheRadius() {
        let inside = Self.northRun(id: "in", east: 50, north0: 0, count: 5)
        let outside = Self.northRun(id: "out", east: 500, north0: 0, count: 5)
        let graph = StreetGraph(format: 1, altitude: 4, spacing: 10, stretches: [outside, inside])
        let found = StreetOverlay.available(in: graph, near: SIMD2(0, 0), radius: 100, maxSegments: 100)
        #expect(found == [1])
    }

    @Test func availableStopsAtTheSegmentCap() {
        // Each stretch has 4 segments. A cap of 10 takes two (8 segments) and stops before the third.
        let stretches = (0..<5).map { Self.northRun(id: "s\($0)", east: Double($0), north0: 0, count: 5) }
        let graph = StreetGraph(format: 1, altitude: 4, spacing: 10, stretches: stretches)
        let found = StreetOverlay.available(in: graph, near: SIMD2(0, 0), radius: 1000, maxSegments: 10)
        #expect(found == [0, 1])
    }

    @Test func availableStopsAtTheCapEvenWhenALaterStretchWouldFit() {
        // A long stretch first (9 segments) that fits, then one of 4 that does not, then one of 1 that would fit:
        // the list stops at the first that does not fit.
        let long = Self.northRun(id: "long", east: 0, north0: 0, count: 10)
        let four = Self.northRun(id: "four", east: 1, north0: 0, count: 5)
        let one = Self.northRun(id: "one", east: 2, north0: 0, count: 2)
        let graph = StreetGraph(format: 1, altitude: 4, spacing: 10, stretches: [long, four, one])
        let found = StreetOverlay.available(in: graph, near: SIMD2(0, 0), radius: 1000, maxSegments: 10)
        #expect(found == [0])
    }
}
