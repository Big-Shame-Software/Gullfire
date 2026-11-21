import Foundation
import Testing
@testable import GullfireKit

/// The street overlay really draws. Renders Chicago headless from above a street with three overlay layers (every
/// stretch nearby, one hovered, one picked), counts pixels brighter than the city's own lines, and (with
/// GULLFIRE_OVERLAY_PNG=<file>) writes the frame so a person can look at it.
@Suite("Street overlay render", .enabled(if: StreetRouteFiles.available))
struct StreetOverlayRenderTests {
    @Test func overlayLinesAreVisible() throws {
        let dir = PackageTests.chicago
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let renderer = try Renderer(city: city, width: 1280, height: 720)
        let start = graph.stretches[0].polyline[graph.stretches[0].polyline.count / 2]
        // 450 m above and 500 m behind the middle of the first stretch, looking down at it.
        let a = graph.stretches[0].polyline.first!, b = graph.stretches[0].polyline.last!
        let heading = atan2(b.x - a.x, b.y - a.y)
        let eye = SIMD3<Float>(Float(start.x - 500 * sin(heading)), 450, Float(-(start.y - 500 * cos(heading))))
        let target = SIMD3<Float>(Float(start.x + 300 * sin(heading)), 0, Float(-(start.y + 300 * cos(heading))))
        let camera = Camera(eye: eye, target: target)

        func frame(_ overlays: [LineOverlay]) throws -> [UInt8] {
            renderer.overlays = overlays
            _ = try renderer.render(camera: camera, palette: .standard)
            return renderer.pixels()
        }
        func bright(_ px: [UInt8]) -> Int {   // BGRA: count the overlay's yellow pixels (a lit red channel; the green city lines have almost none)
            stride(from: 0, to: px.count, by: 4).filter { px[$0 + 2] > 160 && px[$0 + 1] > 140 && px[$0] < 130 }.count
        }
        let plain = try frame([])
        let near = StreetOverlay.available(in: graph, near: start, radius: 4000, maxSegments: 30_000)
        var all: [Float] = [], hover: [Float] = [], picked: [Float] = []
        for i in near { all += StreetOverlay.segments(for: graph.stretches[i], height: 4) }
        hover = StreetOverlay.segments(for: graph.stretches[near.count > 1 ? near[1] : near[0]], height: 5)
        picked = StreetOverlay.segments(for: graph.stretches[near[0]], height: 6)
        let lit = try frame([LineOverlay(segments: all, widthPx: 4, brightness: 0.7),
                             LineOverlay(segments: hover, widthPx: 7, brightness: 1),
                             LineOverlay(segments: picked, widthPx: 12, brightness: 1)])
        print("OVERLAY RENDER: plain frame \(bright(plain)) bright pixels, with overlays \(bright(lit)); \(near.count) stretches, \(all.count / 6) segments")
        if let path = ProcessInfo.processInfo.environment["GULLFIRE_OVERLAY_PNG"] {
            try renderer.writePNG(to: URL(fileURLWithPath: path))
        }
        #expect(bright(lit) > bright(plain) + 200)
    }
}
