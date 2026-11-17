import Foundation
import Testing
import simd
@testable import GullfireKit

@Suite("LocalFrame")
struct LocalFrameTests {
    let frame = LocalFrame(lon0: -87.635, lat0: 41.885)

    @Test func originMapsToZero() {
        let p = frame.metres(lon: -87.635, lat: 41.885)
        #expect(abs(p.x) < 1e-9 && abs(p.y) < 1e-9)
    }

    @Test func hundredthOfDegreeNorthIsAboutElevenHundredMetres() {
        let p = frame.metres(lon: -87.635, lat: 41.895)
        #expect(abs(p.y - 1105.7) < 0.1)
        #expect(abs(p.x) < 1e-9)
    }

    @Test func renderSpaceFlipsNorthToMinusZ() {
        let r = frame.render(east: 10, north: 20, up: 30)
        #expect(r == SIMD3<Float>(10, 30, -20))
    }
}

@Suite("EarClip")
struct EarClipTests {
    static func area(_ p: [SIMD2<Double>], _ idx: [Int]) -> Double {
        var total = 0.0
        for k in stride(from: 0, to: idx.count, by: 3) {
            let a = p[idx[k]], b = p[idx[k + 1]], c = p[idx[k + 2]]
            total += ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
        return total
    }

    @Test func squareGivesTwoTriangles() {
        let square: [SIMD2<Double>] = [[0, 0], [10, 0], [10, 10], [0, 10]]
        let idx = EarClip.triangulate(square)
        #expect(idx.count == 6)
        #expect(abs(Self.area(square, idx) - 100) < 1e-9)
    }

    @Test func lShapeGivesFourTrianglesWithFullArea() {
        let l: [SIMD2<Double>] = [[0, 0], [20, 0], [20, 10], [10, 10], [10, 20], [0, 20]]
        let idx = EarClip.triangulate(l)
        #expect(idx.count == 12)
        #expect(abs(Self.area(l, idx) - 300) < 1e-9)
    }
}

@Suite("Extruder")
struct ExtruderTests {
    @Test func tenByTenBoxGivesTenTrianglesAndTwelveEdges() {
        var mesh = MeshBuilder(frame: LocalFrame(lon0: 0, lat0: 0))
        let box: [SIMD2<Double>] = [[0, 0], [10, 0], [10, 10], [0, 10]]
        mesh.extrude(rings: [box], base: 0, top: 20, group: .buildingsMeasured)
        #expect(mesh.triangleCount == 10)   // 8 wall + 2 roof
        #expect(mesh.lines[LineGroup.buildingsMeasured.rawValue].count / 6 == 12)
    }

    @Test func closingPointIsIgnored() {
        var mesh = MeshBuilder(frame: LocalFrame(lon0: 0, lat0: 0))
        let box: [SIMD2<Double>] = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]]
        mesh.extrude(rings: [box], base: 0, top: 20, group: .buildingsMeasured)
        #expect(mesh.triangleCount == 10)
    }
}

@Suite("ObstacleGrid")
struct ObstacleGridTests {
    @Test func stampRaisesOnlyCellsInsideTheFootprint() {
        var grid = ObstacleGrid(minEast: -40, minNorth: -40, cellSize: 4, cols: 20, rows: 20)
        let square: [SIMD2<Double>] = [[0, 0], [20, 0], [20, 20], [0, 20]]
        grid.stamp(ring: square, top: 50)
        let inside = ObstacleGrid.index(east: 10, north: 10, minEast: -40, minNorth: -40, cellSize: 4, cols: 20, rows: 20)
        let outside = ObstacleGrid.index(east: 30, north: 30, minEast: -40, minNorth: -40, cellSize: 4, cols: 20, rows: 20)
        #expect(grid.heights[inside!] == 50)
        #expect(grid.heights[outside!] == 0)
    }
}
