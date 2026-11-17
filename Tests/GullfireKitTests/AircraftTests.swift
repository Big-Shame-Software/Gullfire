import Foundation
import Testing
import simd
@testable import GullfireKit

/// The wireframe aircraft's pose matrix and its drawing. A tiny synthetic model stands in for the private glider, so these run
/// without it.
@Suite("Aircraft")
struct AircraftTests {
    static func column(_ m: simd_float4x4, _ i: Int) -> SIMD3<Float> { SIMD3(m[i].x, m[i].y, m[i].z) }

    /// A fresh, empty stand-in for the home folder, so no real model is found through `~`.
    static func emptyHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("gullfire-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// No glider model (it is private and not in the repository): `locate()` finds nothing, so the app
    /// never loads an aircraft and the G key does nothing. The environment names a file that does not exist,
    /// and the home folder is empty.
    @Test func noModelFileMeansNoAircraftToLocate() throws {
        let home = try Self.emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AircraftModel.locate(environment: ["GULLFIRE_MODEL": "/nonexistent/gullfire-test/Models/gullfire.json"], home: home) == nil)
    }

    /// With a model file in place, `GULLFIRE_MODEL` points `locate()` at it, so the G legend row and the View menu
    /// item appear (KeyLegendTests.gliderRowIsHiddenWithoutAModel covers the legend's side of this).
    @Test func aModelFileIsLocatedThroughGullfireModel() throws {
        let home = try Self.emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gullfire-test-\(UUID().uuidString).json")
        try Data(#"{"name":"test","spanM":1,"lengthM":1,"triangles":[],"lines":[0,0,0,1,0,0]}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(AircraftModel.locate(environment: ["GULLFIRE_MODEL": file.path], home: home)?.path == file.path)
    }

    /// The model-level gate for the glider (the G legend row and the View menu's glider item both depend on it):
    /// with GULLFIRE_MODEL on the example, `installed()` loads it; with no file, it is nil.
    @Test func installedModelIsTheOneTheLegendAndMenuDependOn() throws {
        let home = try Self.emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let example = ExampleGliderTests.root.appendingPathComponent("Examples/example-glider.json")
        #expect(AircraftModel.installed(environment: ["GULLFIRE_MODEL": example.path], home: home)?.name == "Example sailplane (generic)")
        #expect(AircraftModel.installed(environment: ["GULLFIRE_MODEL": "/nonexistent/gullfire-test/Models/gullfire.json"], home: home) == nil)
    }

    /// A model file that is present but not a valid model fails to load, so the app also draws no glider.
    @Test func aBrokenModelFileDoesNotLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gullfire-broken-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gullfire.json")
        try Data("{ not a model".utf8).write(to: url)
        #expect(throws: (any Error).self) { try AircraftModel.load(from: url) }
    }

    @Test func headingNorthPutsTheNoseAlongMinusZAndTheRightWingEast() {
        let m = AircraftPose(east: 100, north: 200, altitude: 50, heading: 0, pitch: 0, bank: 0).matrix()
        let nose = Self.column(m, 0), up = Self.column(m, 1), right = Self.column(m, 2)
        #expect(simd_length(nose - SIMD3(0, 0, -1)) < 1e-5)
        #expect(simd_length(up - SIMD3(0, 1, 0)) < 1e-5)
        #expect(simd_length(right - SIMD3(1, 0, 0)) < 1e-5)
        #expect(m[3].x == 100 && m[3].y == 50 && m[3].z == -200)
        // Right-handed: nose x up = right.
        #expect(simd_length(simd_cross(nose, up) - right) < 1e-5)
    }

    @Test func headingEastPutsTheNoseEast() {
        let m = AircraftPose(east: 0, north: 0, altitude: 0, heading: .pi / 2, pitch: 0, bank: 0).matrix()
        #expect(simd_length(Self.column(m, 0) - SIMD3(1, 0, 0)) < 1e-5)
    }

    @Test func pitchRaisesTheNoseAndBankLowersTheRightWing() {
        let pitched = AircraftPose(east: 0, north: 0, altitude: 0, heading: 0, pitch: 0.3, bank: 0).matrix()
        #expect(Self.column(pitched, 0).y > 0.25)
        let banked = AircraftPose(east: 0, north: 0, altitude: 0, heading: 0, pitch: 0, bank: 0.5).matrix()
        #expect(Self.column(banked, 2).y < -0.4)            // the right wing is down
        #expect(Self.column(banked, 1).x > 0.4)             // the top tips toward the right
        // Still a rotation: unit columns, right-handed.
        let n = Self.column(banked, 0), u = Self.column(banked, 1), r = Self.column(banked, 2)
        #expect(abs(simd_length(n) - 1) < 1e-5 && abs(simd_length(u) - 1) < 1e-5 && abs(simd_length(r) - 1) < 1e-5)
        #expect(simd_length(simd_cross(n, u) - r) < 1e-5)
    }

    @Test func theCloseChaseCameraIsBehindAndAboveTheGlider() {
        var chase = ChaseCamera.close
        let s = FlightState(east: 0, north: 0, altitude: 100, heading: 0, speed: 40)
        let cam = chase.update(s, dt: 1, reduceMotion: false)
        #expect(abs(cam.eye.z - 16) < 1e-4)                  // 16 m south of the aircraft: +z in render space
        #expect(abs(cam.eye.y - 104.5) < 1e-4)
        #expect(cam.target.z < cam.eye.z)
    }

    /// Drawing the aircraft changes the picture, and drawing none changes nothing.
    @Test(.enabled(if: PackageTests.built)) func drawingTheAircraftChangesThePicture() throws {
        let city = try CityPackage.open(directory: PackageTests.chicago)
        let renderer = try Renderer(city: city, width: 320, height: 180)
        let camera = Camera(eye: SIMD3(0, 420, 25), target: SIMD3(0, 412, -40))
        try renderer.render(camera: camera, palette: .standard)
        let without = renderer.pixels()
        // A synthetic model: one big triangle and its three edges, 6 m long.
        let tri: [Float] = [0, 0, 0,  6, 0, -2,  6, 0, 2]
        let lines: [Float] = [0, 0, 0,  6, 0, -2,   6, 0, -2,  6, 0, 2,   6, 0, 2,  0, 0, 0]
        try renderer.loadAircraft(AircraftModel(name: "test", spanM: 4, lengthM: 6, triangles: tri, lines: lines))
        renderer.aircraft = AircraftPose(east: 0, north: 0, altitude: 413, heading: 0, pitch: 0, bank: 0)
        try renderer.render(camera: camera, palette: .standard)
        let with = renderer.pixels()
        #expect(with != without)
        renderer.aircraft = nil
        try renderer.render(camera: camera, palette: .standard)
        #expect(renderer.pixels() == without)
    }
}

@Suite("Draw distance")
struct DrawDistanceTests {
    /// A draw distance skips tiles far from the eye, and none draws every tile in view.
    @Test(.enabled(if: PackageTests.built)) func aDrawDistanceDrawsFewerTiles() throws {
        let city = try CityPackage.open(directory: PackageTests.chicago)
        let renderer = try Renderer(city: city, width: 320, height: 180)
        let camera = Camera(eye: SIMD3(0, 600, 2500), target: SIMD3(0, 50, -500))     // the whole box in view
        try renderer.render(camera: camera, palette: .standard)
        let all = renderer.lastTilesDrawn
        renderer.drawDistance = 700
        try renderer.render(camera: camera, palette: .standard)
        let near = renderer.lastTilesDrawn
        renderer.drawDistance = nil
        try renderer.render(camera: camera, palette: .standard)
        #expect(near < all && near > 0)
        #expect(renderer.lastTilesDrawn == all)
    }
}
