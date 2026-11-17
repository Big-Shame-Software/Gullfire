import Foundation
import Metal
import Testing
import simd
@testable import GullfireKit

/// Level of detail. The pure tests need no package. The pixel tests
/// use Chicago and skip when it or a Metal device is missing.
@Suite("Level of detail")
struct LevelOfDetailTests {
    @Test func levelBoundaries() {
        let lod = LevelOfDetail(d1: 1500, d2: 3000)
        #expect(lod.level(distance: 0) == 1)
        #expect(lod.level(distance: 1499.9) == 1)
        #expect(lod.level(distance: 1500) == 2)
        #expect(lod.level(distance: 2000) == 2)
        #expect(lod.level(distance: 3000) == 2)
        #expect(lod.level(distance: 3000.1) == 3)
    }

    @Test func distanceInsideTheBoxIsZero() {
        let d = LevelOfDetail.distance(from: SIMD3(5, 5, 5), toBoxMin: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        #expect(d == 0)
    }

    @Test func distanceTenMetresOffAFaceIsTen() {
        let d = LevelOfDetail.distance(from: SIMD3(20, 5, 5), toBoxMin: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        #expect(abs(d - 10) < 1e-5)
    }

    @Test(.enabled(if: CullingTests.chicagoBuilt))
    func hugeDistancesMatchNoLevelOfDetailExactly() throws {
        let package = try CityPackage.open(directory: PackageTests.chicago)
        let frame = LocalFrame(lon0: package.manifest.origin.lon, lat0: package.manifest.origin.lat)
        let renderer = try Renderer(city: package, width: 1280, height: 720)
        for view in StillView.allCases {
            let camera = view.camera(in: frame)
            renderer.levelOfDetail = nil
            try renderer.render(camera: camera, palette: .standard)
            let plain = renderer.pixels()
            let plainSegments = renderer.lastSegmentsDrawn

            renderer.levelOfDetail = LevelOfDetail(d1: 1_000_000, d2: 1_000_000)
            try renderer.render(camera: camera, palette: .standard)
            let lod = renderer.pixels()
            #expect(renderer.lastSegmentsDrawn == plainSegments, "\(view.rawValue): segments differ")
            let mismatches = zip(plain, lod).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            #expect(plain.count == lod.count && mismatches == 0,
                    "\(view.rawValue): \(mismatches) bytes differ")
        }
    }

    /// Brief T4b: the cut is the largest one at or below the height; none below the first cut.
    @Test func heightCutChoosesTheLargestCutAtOrBelow() {
        let cuts: [Double] = [8, 15, 30, 60, 120]
        #expect(LevelOfDetail.heightCut(atOrBelow: 5, cuts: cuts) == nil)
        #expect(LevelOfDetail.heightCut(atOrBelow: 8, cuts: cuts) == 0)
        #expect(LevelOfDetail.heightCut(atOrBelow: 20, cuts: cuts) == 1)
        #expect(LevelOfDetail.heightCut(atOrBelow: 500, cuts: cuts) == 4)
    }

    /// Brief T4b: 0.0025 of the screen at 3 km with a 55 degree field of view is about 7.8 m.
    @Test func minHeightFromScreenFraction() throws {
        let lod = LevelOfDetail(d1: 1500, d2: 3000, minScreenFraction: 0.0025)
        let h = try #require(lod.minHeight(distance: 3000, fovDegrees: 55))
        #expect(abs(h - 7.8) < 0.05)
        #expect(LevelOfDetail(d1: 1500, d2: 3000).minHeight(distance: 3000, fovDegrees: 55) == nil)
    }

    /// Brief T4b: with the height cut on but every distance inside level 2, the picture is the same as nil.
    @Test(.enabled(if: CullingTests.chicagoBuilt))
    func hugeDistancesWithHeightCutMatchNoLevelOfDetailExactly() throws {
        let package = try CityPackage.open(directory: PackageTests.chicago)
        let frame = LocalFrame(lon0: package.manifest.origin.lon, lat0: package.manifest.origin.lat)
        let renderer = try Renderer(city: package, width: 1280, height: 720)
        for view in StillView.allCases {
            let camera = view.camera(in: frame)
            renderer.levelOfDetail = nil
            try renderer.render(camera: camera, palette: .standard)
            let plain = renderer.pixels()
            let plainSegments = renderer.lastSegmentsDrawn

            renderer.levelOfDetail = LevelOfDetail(d1: 1_000_000, d2: 1_000_000, minScreenFraction: 0.0025)
            try renderer.render(camera: camera, palette: .standard)
            let lod = renderer.pixels()
            #expect(renderer.lastSegmentsDrawn == plainSegments, "\(view.rawValue): segments differ")
            let mismatches = zip(plain, lod).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            #expect(plain.count == lod.count && mismatches == 0,
                    "\(view.rawValue): \(mismatches) bytes differ")
        }
    }

    /// Brief T4b: the height cut only ever draws fewer building segments than the far count does.
    @Test(.enabled(if: CullingTests.chicagoBuilt))
    func heightCutNeverDrawsMoreThanTheFarCount() throws {
        let package = try CityPackage.open(directory: PackageTests.chicago)
        let frame = LocalFrame(lon0: package.manifest.origin.lon, lat0: package.manifest.origin.lat)
        let camera = StillView.above.camera(in: frame)
        let renderer = try Renderer(city: package, width: 1280, height: 720)
        renderer.levelOfDetail = LevelOfDetail(d1: 0, d2: 0)
        try renderer.render(camera: camera, palette: .standard)
        let farSegments = renderer.lastSegmentsDrawn

        renderer.levelOfDetail = LevelOfDetail(d1: 0, d2: 0, minScreenFraction: 0.0025)
        try renderer.render(camera: camera, palette: .standard)
        #expect(renderer.lastSegmentsDrawn <= farSegments,
                "height cut drew \(renderer.lastSegmentsDrawn), far count drew \(farSegments)")
    }

    @Test(.enabled(if: CullingTests.chicagoBuilt))
    func zeroDistancesDrawFewerSegments() throws {
        let package = try CityPackage.open(directory: PackageTests.chicago)
        let frame = LocalFrame(lon0: package.manifest.origin.lon, lat0: package.manifest.origin.lat)
        let camera = StillView.above.camera(in: frame)
        let renderer = try Renderer(city: package, width: 1280, height: 720)
        renderer.levelOfDetail = nil
        try renderer.render(camera: camera, palette: .standard)
        let plainSegments = renderer.lastSegmentsDrawn

        renderer.levelOfDetail = LevelOfDetail(d1: 0, d2: 0)
        try renderer.render(camera: camera, palette: .standard)
        #expect(renderer.lastSegmentsDrawn < plainSegments,
                "level 3 everywhere drew \(renderer.lastSegmentsDrawn), nil drew \(plainSegments)")
    }
}
