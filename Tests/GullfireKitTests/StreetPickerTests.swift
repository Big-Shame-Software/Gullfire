import Foundation
import simd
import Testing
@testable import GullfireKit

/// Flat open ground: every point is at height zero.
private struct StreetPickerOpenGround: ObstacleSource {
    func height(east: Double, north: Double) -> Float { 0 }
}

/// A 200 x 200 m block, 40 m tall, from east -100...100 and north 20...220; open ground elsewhere.
private struct StreetPickerBlock: ObstacleSource {
    func height(east: Double, north: Double) -> Float {
        (-100...100).contains(east) && (20...220).contains(north) ? 40 : 0
    }
}

@Suite("Street picker")
struct StreetPickerTests {
    static let chicagoBuilt = FileManager.default.fileExists(
        atPath: PackageTests.chicago.appendingPathComponent(StreetGraph.fileName).path)

    /// A flat line of points from east -100 to 100 at 10 m spacing, at the given north.
    static func eastLine(north: Double) -> [Double] {
        stride(from: -100.0, through: 100.0, by: 10.0).flatMap { [$0, north] }
    }

    /// Two parallel stretches: index 0 is 30 m north, index 1 is at north 0 (the nearer one to a hit at north 10).
    static func twoParallelStreets() -> StreetGraph {
        let far = StreetStretch(id: "far", streetClass: "primary", names: ["Far Road"], length: 200, points: eastLine(north: 30))
        let near = StreetStretch(id: "near", streetClass: "primary", names: ["Near Street"], length: 200, points: eastLine(north: 0))
        return StreetGraph(format: 1, altitude: 15, spacing: 10, stretches: [far, near])
    }

    /// A camera 60 m up, over north 10, looking almost straight down (a small tilt keeps the basis defined).
    static var overNorthTen: Camera {
        Camera(eye: SIMD3(0, 60, -10), target: SIMD3(0, 0, -10.01))
    }

    @Test func rayThroughTheCentreFollowsForward() {
        let camera = Camera(eye: SIMD3(0, 10, 0), target: SIMD3(0, 10, -100))
        let ray = camera.ray(ndc: SIMD2(0, 0), aspect: 1.5)
        let forward = simd_normalize(SIMD3<Double>(0, 0, -100))
        #expect(ray.origin == SIMD3<Double>(0, 10, 0))
        #expect(simd_length(ray.direction - forward) < 1e-12)
    }

    @Test func rayAtTheRightEdgeLeansRightByTheHalfFovTimesAspect() {
        let camera = Camera(eye: SIMD3(0, 10, 0), target: SIMD3(0, 10, -100))
        let aspect = 1.5
        let ray = camera.ray(ndc: SIMD2(1, 0), aspect: aspect)
        let forward = simd_normalize(SIMD3<Double>(0, 0, -100))
        let expected = atan(tan(Double(camera.fovDegrees) * .pi / 360) * aspect)
        let angle = acos(simd_dot(ray.direction, forward))
        #expect(abs(angle - expected) < 1e-9)
        #expect(ray.direction.x > 0)
        // With roll 0 the right-hand direction is horizontal.
        #expect(abs(ray.direction.y) < 1e-12)
    }

    @Test func groundHitOnOpenGroundIsWhereTheRayMeetsZero() throws {
        // Eye 100 m up at the origin, looking north and down 45 degrees: the ground is met at north 100.
        let origin = SIMD3<Double>(0, 100, 0)
        let direction = simd_normalize(SIMD3<Double>(0, -100, -100))
        let hit = StreetPicker.groundHit(origin: origin, direction: direction, obstacles: StreetPickerOpenGround())
        let point = try #require(hit)
        #expect(abs(point.x) < 1.5)
        #expect(abs(point.y - 100) < 1.5)
    }

    @Test func groundHitStopsOnTheTopOfABlockBeforeTheGround() throws {
        // The same ray as above, now with a 40 m block north of 20: it meets the top face at north 60, not the ground at 100.
        let origin = SIMD3<Double>(0, 100, 0)
        let direction = simd_normalize(SIMD3<Double>(0, -100, -100))
        let hit = StreetPicker.groundHit(origin: origin, direction: direction, obstacles: StreetPickerBlock())
        let point = try #require(hit)
        #expect(abs(point.y - 60) < 1.5)
    }

    @Test func rayPointingUpNeverHitsTheGround() {
        let hit = StreetPicker.groundHit(
            origin: SIMD3(0, 100, 0),
            direction: SIMD3(0, 1, 0),
            obstacles: StreetPickerOpenGround())
        #expect(hit == nil)
    }

    @Test func pickSnapsToTheNearerParallelStreet() {
        let pick = StreetPicker.pick(
            camera: Self.overNorthTen,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: 0,
            graph: Self.twoParallelStreets(),
            obstacles: StreetPickerOpenGround())
        #expect(pick?.stretchIndex == 1)
        #expect(abs((pick?.distance ?? -1) - 10) < 0.1)
    }

    @Test func pickReturnsNilBeyondMaxSnap() {
        // Both streets are at least 10 m away from the hit, so a 5 m snap finds nothing.
        let pick = StreetPicker.pick(
            camera: Self.overNorthTen,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: 0,
            graph: Self.twoParallelStreets(),
            obstacles: StreetPickerOpenGround(),
            maxSnap: 5)
        #expect(pick == nil)
    }

    @Test func pickFliesTheOrientationClosestToTheAircraftHeading() {
        // The streets run east, so the forward start heading is east (pi/2) and the reverse is west (-pi/2).
        let eastbound = StreetPicker.pick(
            camera: Self.overNorthTen,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: .pi / 2,
            graph: Self.twoParallelStreets(),
            obstacles: StreetPickerOpenGround())
        #expect(eastbound?.stretchIndex == 1)
        #expect(eastbound?.reversed == false)

        let westbound = StreetPicker.pick(
            camera: Self.overNorthTen,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: -.pi / 2,
            graph: Self.twoParallelStreets(),
            obstacles: StreetPickerOpenGround())
        #expect(westbound?.stretchIndex == 1)
        #expect(westbound?.reversed == true)
    }

    @Test func candidatesAreNearestFirst() {
        let found = StreetPicker.candidates(
            camera: Self.overNorthTen,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: 0,
            graph: Self.twoParallelStreets(),
            obstacles: StreetPickerOpenGround())
        // The hit is at north 10: the near street is 10 m away, the far one 20 m.
        #expect(found.map { $0.stretchIndex } == [1, 0])
        #expect(abs(found[0].distance - 10) < 0.1)
        #expect(abs(found[1].distance - 20) < 0.1)
    }

    @Test func candidatesRespectTheLimitAndTheSnapDistance() {
        let limited = StreetPicker.candidates(
            camera: Self.overNorthTen,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: 0,
            graph: Self.twoParallelStreets(),
            obstacles: StreetPickerOpenGround(),
            limit: 1)
        #expect(limited.count == 1)
        #expect(limited.first?.stretchIndex == 1)

        // With a 15 m snap only the near street (10 m) qualifies; the far one (20 m) is left out.
        let snapped = StreetPicker.candidates(
            camera: Self.overNorthTen,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: 0,
            graph: Self.twoParallelStreets(),
            obstacles: StreetPickerOpenGround(),
            maxSnap: 15)
        #expect(snapped.map { $0.stretchIndex } == [1])
    }

    @Test func candidatesAreEmptyWhenTheRayHitsNoGround() {
        // Looking straight up from 60 m: the ray never comes down.
        let up = Camera(eye: SIMD3(0, 60, -10), target: SIMD3(0, 120, -10.01))
        let found = StreetPicker.candidates(
            camera: up,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: 0,
            graph: Self.twoParallelStreets(),
            obstacles: StreetPickerOpenGround())
        #expect(found.isEmpty)
    }

    @Test func firstCandidateIsWhatPickReturnsWithinEightyMetres() {
        let graph = Self.twoParallelStreets()
        let picked = StreetPicker.pick(
            camera: Self.overNorthTen,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: .pi / 2,
            graph: graph,
            obstacles: StreetPickerOpenGround())
        let found = StreetPicker.candidates(
            camera: Self.overNorthTen,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: .pi / 2,
            graph: graph,
            obstacles: StreetPickerOpenGround())
        #expect(picked != nil)
        #expect(found.first == picked)
    }

    @Test func labelUsesNamesThenClassThenStreet() {
        let named = StreetStretch(
            id: "a", streetClass: "primary", names: ["Main St", "", "Second Ave", "Third", "Fourth"], length: 100, points: [])
        #expect(StreetPicker.label(for: named) == "MAIN ST / SECOND AVE / THIRD")

        let classed = StreetStretch(id: "b", streetClass: "service", names: [], length: 100, points: [])
        #expect(StreetPicker.label(for: classed) == "SERVICE")

        let bare = StreetStretch(id: "c", streetClass: "", names: [], length: 100, points: [])
        #expect(StreetPicker.label(for: bare) == "STREET")
    }

    @Test func distanceIsToTheNearestSegmentOrEndpoint() {
        let near = StreetStretch(id: "near", streetClass: "primary", names: [], length: 200, points: Self.eastLine(north: 0))
        // Straight above the line: the perpendicular distance.
        #expect(abs(StreetPicker.distance(from: SIMD2(0, 5), to: near) - 5) < 1e-9)
        // Past the east end (100 m): the distance to that end point, not to the line's extension.
        #expect(abs(StreetPicker.distance(from: SIMD2(130, 40), to: near) - 50) < 1e-9)
        // On the line: zero.
        #expect(StreetPicker.distance(from: SIMD2(-37, 0), to: near) < 1e-9)
        // A one-point stretch: the distance to the point.
        let dot = StreetStretch(id: "dot", streetClass: "", names: [], length: 0, points: [3, 4])
        #expect(abs(StreetPicker.distance(from: SIMD2(0, 0), to: dot) - 5) < 1e-9)
        // No points: never close.
        let empty = StreetStretch(id: "empty", streetClass: "", names: [], length: 0, points: [])
        #expect(StreetPicker.distance(from: SIMD2(0, 0), to: empty) == .infinity)
    }

    @Test(.enabled(if: StreetPickerTests.chicagoBuilt)) func pickOnChicagoFindsTheStretchUnderTheCamera() throws {
        let graph = try #require(try StreetGraph.load(from: PackageTests.chicago))
        let obstacles = try CityPackage.open(directory: PackageTests.chicago)
        let first = try #require(graph.stretches.first)
        let line = first.polyline
        let mid = line[line.count / 2]
        let camera = Camera(
            eye: SIMD3(Float(mid.x), 60, -Float(mid.y)),
            target: SIMD3(Float(mid.x), 0, -Float(mid.y) - 0.01))
        let pick = try #require(StreetPicker.pick(
            camera: camera,
            ndc: SIMD2(0, 0),
            aspect: 1,
            aircraftHeading: 0,
            graph: graph,
            obstacles: obstacles))
        #expect(pick.stretchIndex == 0)
        #expect(pick.distance < 5)
    }
}

@Suite("Followable streets")
struct FollowableStreetTests {
    static func stretch(_ id: String, y: Double, loops: [Bool]?) -> StreetStretch {
        // A straight east-west street at north = y, 200 m long, points every 10 m.
        let pts = (0...20).flatMap { [Double($0) * 10, y] }
        return StreetStretch(id: id, streetClass: "residential", names: [id], length: 200, points: pts, loops: loops)
    }

    @Test func canStartReadsTheMarksAndTakesUncheckedPackagesAsWorking() {
        #expect(Self.stretch("a", y: 0, loops: nil).canStart(reversed: true))
        #expect(Self.stretch("a", y: 0, loops: [true, false]).canStart(reversed: false))
        #expect(!Self.stretch("a", y: 0, loops: [true, false]).canStart(reversed: true))
        #expect(!Self.stretch("a", y: 0, loops: [false, false]).canStartAny)
        #expect(Self.stretch("a", y: 0, loops: [false, true]).canStartAny)
    }

    @Test func theMarksSurviveAJSONRoundTrip() throws {
        let graph = StreetGraph(format: 1, altitude: 15, spacing: 10, stretches: [Self.stretch("a", y: 0, loops: [true, false])])
        let back = try JSONDecoder().decode(StreetGraph.self, from: JSONEncoder().encode(graph))
        #expect(back.stretches[0].loops == [true, false])
        let old = #"{"format":1,"altitude":15,"spacing":10,"stretches":[{"id":"x","class":"residential","names":[],"length":10,"points":[0,0,10,0]}]}"#
        let decoded = try JSONDecoder().decode(StreetGraph.self, from: Data(old.utf8))
        #expect(decoded.stretches[0].loops == nil && decoded.stretches[0].canStartAny)
    }

    @Test func theOverlayListsOnlyStreetsThatCanStartALoop() {
        let graph = StreetGraph(format: 1, altitude: 15, spacing: 10, stretches: [
            Self.stretch("works", y: 0, loops: [true, true]),
            Self.stretch("dead", y: 20, loops: [false, false]),
            Self.stretch("oneway", y: 40, loops: [false, true]),
        ])
        let near = StreetOverlay.available(in: graph, near: SIMD2(100, 0), radius: 500, maxSegments: 10_000)
        #expect(near.map { graph.stretches[$0].id } == ["works", "oneway"])
    }

    @Test func aPickSkipsDeadStreetsAndTakesTheDirectionThatWorks() throws {
        let graph = StreetGraph(format: 1, altitude: 15, spacing: 10, stretches: [
            Self.stretch("dead", y: 0, loops: [false, false]),
            Self.stretch("oneway", y: 60, loops: [false, true]),
        ])
        // A camera 200 m above (100, 0) looking straight at the ground just north of the aircraft, heading east.
        let camera = Camera(eye: SIMD3(100, 200, 0), target: SIMD3(100, 0, -30))
        let picks = StreetPicker.candidates(camera: camera, ndc: SIMD2(0, 0), aspect: 16.0 / 9.0, aircraftHeading: Double.pi / 2,
                                            graph: graph, obstacles: FlatGround(), maxSnap: 500, limit: 4)
        #expect(picks.map { graph.stretches[$0.stretchIndex].id } == ["oneway"])
        #expect(picks.first?.reversed == true)   // east is the aircraft's heading, but only the reversed direction works
    }
}

private struct FlatGround: ObstacleSource {
    func height(east: Double, north: Double) -> Float { 0 }
}
