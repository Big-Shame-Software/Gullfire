import Foundation
import Metal
import Testing
import simd
@testable import GullfireKit

/// Frustum culling. The pure tests need no package. The pixel tests render
/// Chicago with and without culling and require identical pixels; they skip when Chicago or a Metal
/// device is missing.
@Suite("Frustum culling")
struct CullingTests {
    /// Looks down -z from the origin, 16:9, 55 degrees, as the renderer's uniforms do.
    static let frustum = Frustum(viewProjection: Camera(eye: SIMD3(0, 0, 0), target: SIMD3(0, 0, -1))
        .viewProjection(aspect: 16.0 / 9.0))

    @Test func boxStraightAheadIsVisible() {
        #expect(Self.frustum.intersects(min: SIMD3(-1, -1, -101), max: SIMD3(1, 1, -99)))
    }

    @Test func boxBehindTheEyeIsCulled() {
        #expect(!Self.frustum.intersects(min: SIMD3(-1, -1, 5), max: SIMD3(1, 1, 10)))
    }

    /// At depth 100 the half-width is about 92.6 m, so x in -300...-200 is well outside.
    @Test func boxFarLeftOutsideTheFieldIsCulled() {
        #expect(!Self.frustum.intersects(min: SIMD3(-300, -1, -101), max: SIMD3(-200, 1, -99)))
    }

    /// x from 85 to 120 at depth 100 crosses the right plane at about 92.6 m.
    @Test func boxStraddlingTheSidePlaneIsVisible() {
        #expect(Self.frustum.intersects(min: SIMD3(85, -1, -101), max: SIMD3(120, 1, -99)))
    }

    /// The projection has an infinite far plane, so 100 km ahead is still visible.
    @Test func boxOneHundredKilometresAheadIsVisible() {
        #expect(Self.frustum.intersects(min: SIMD3(-1, -1, -100_001), max: SIMD3(1, 1, -99_999)))
    }

    static var chicagoBuilt: Bool {
        FileManager.default.fileExists(atPath: PackageTests.chicago.appendingPathComponent("manifest.json").path)
            && MTLCreateSystemDefaultDevice() != nil
    }

    /// Chicago at 1280 x 720: the three named views and two orbit frames. Every pair must match exactly,
    /// and at least one frame must have drawn fewer tiles than the total, so culling is really on.
    @Test(.enabled(if: CullingTests.chicagoBuilt))
    func culledFramesMatchUnculledPixelForPixel() throws {
        let package = try CityPackage.open(directory: PackageTests.chicago)
        let frame = LocalFrame(lon0: package.manifest.origin.lon, lat0: package.manifest.origin.lat)
        var cameras = StillView.allCases.map { $0.camera(in: frame) }
        cameras.append(Orbit.camera(frame: 0, of: 8))
        cameras.append(Orbit.camera(frame: 3, of: 8))

        let renderer = try Renderer(city: package, width: 1280, height: 720)
        var someFrameCulled = false
        for (index, camera) in cameras.enumerated() {
            renderer.culling = false
            try renderer.render(camera: camera, palette: .standard)
            let full = renderer.pixels()

            renderer.culling = true
            try renderer.render(camera: camera, palette: .standard)
            let culled = renderer.pixels()
            #expect(renderer.lastTilesTotal == (package.manifest.tiles?.entries.count ?? -1))
            if renderer.lastTilesDrawn < renderer.lastTilesTotal { someFrameCulled = true }

            let mismatches = zip(full, culled).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            #expect(full.count == culled.count && mismatches == 0,
                    "camera \(index): \(mismatches) of \(full.count) bytes differ")
        }
        #expect(someFrameCulled, "no frame drew fewer tiles than the total, so culling was not exercised")
    }

    /// The smallest size the app uses, where the margin matters most.
    @Test(.enabled(if: CullingTests.chicagoBuilt))
    func culledFramesMatchAtSmallestSize() throws {
        let package = try CityPackage.open(directory: PackageTests.chicago)
        let frame = LocalFrame(lon0: package.manifest.origin.lon, lat0: package.manifest.origin.lat)
        let renderer = try Renderer(city: package, width: 640, height: 360)
        for view in StillView.allCases {
            let camera = view.camera(in: frame)
            renderer.culling = false
            try renderer.render(camera: camera, palette: .standard)
            let full = renderer.pixels()
            renderer.culling = true
            try renderer.render(camera: camera, palette: .standard)
            let culled = renderer.pixels()
            let mismatches = zip(full, culled).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            #expect(full.count == culled.count && mismatches == 0,
                    "\(view.rawValue) at 640x360: \(mismatches) bytes differ")
        }
    }
}
