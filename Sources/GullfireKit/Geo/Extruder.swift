import Foundation
import simd

/// The five line groups in `lines.bin`, in file order.
public enum LineGroup: Int, CaseIterable, Sendable {
    case buildingsMeasured, buildingsFloors, buildingsDefault, water, roads
}

/// Collects depth-pass triangles and line segments in render space.
public struct MeshBuilder: Sendable {
    public let frame: LocalFrame
    /// 9 floats (three vertices of x, y, z) per triangle, tightly packed.
    public var triangles: [Float] = []
    /// One array per `LineGroup`, 6 floats (ax ay az bx by bz) per segment.
    public var lines: [[Float]] = Array(repeating: [], count: LineGroup.allCases.count)
    /// The tile the next added elements belong to (-1 for the ground quad). Set by the writer.
    public var tile: Int32 = -1
    /// One entry per triangle, from `tile` when it was added.
    public var triangleTiles: [Int32] = []
    /// One array per `LineGroup`, one entry per segment, from `tile` when it was added.
    public var lineTiles: [[Int32]] = Array(repeating: [], count: LineGroup.allCases.count)
    /// One array per `LineGroup`, one entry per segment: true for a building's base edge.
    public var lineBase: [[Bool]] = Array(repeating: [], count: LineGroup.allCases.count)

    public init(frame: LocalFrame) {
        self.frame = frame
    }

    public var triangleCount: Int { triangles.count / 9 }

    public mutating func addTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        triangles.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z])
        triangleTiles.append(tile)
    }

    public mutating func addSegment(_ group: LineGroup, _ a: SIMD3<Float>, _ b: SIMD3<Float>, base: Bool = false) {
        lines[group.rawValue].append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z])
        lineTiles[group.rawValue].append(tile)
        lineBase[group.rawValue].append(base)
    }

    /// Walls, top and base edges, corner verticals, and the roof cap (outer ring only).
    /// `rings` are metres east/north; `rings[0]` is the outer ring. Holes get walls and
    /// edges but no cap, a known shortcut.
    public mutating func extrude(rings: [[SIMD2<Double>]], base: Double, top: Double, group: LineGroup) {
        let cosTurn = cos(20 * Double.pi / 180)
        for (ringIndex, raw) in rings.enumerated() {
            var r = raw
            if r.count > 1, r.first == r.last { r.removeLast() }
            if r.count < 3 { continue }
            if signedArea(r) < 0 { r.reverse() }   // counter-clockwise
            let n = r.count
            for i in 0..<n {
                let a = r[i], b = r[(i + 1) % n], prev = r[(i + n - 1) % n]
                let aBase = point(a, base), bBase = point(b, base)
                let aTop = point(a, top), bTop = point(b, top)
                addTriangle(aBase, bBase, bTop)
                addTriangle(aBase, bTop, aTop)
                addSegment(group, aTop, bTop)
                addSegment(group, aBase, bBase, base: true)
                // A vertical edge only where the footprint turns by more than 20 degrees.
                if let d1 = unit(a - prev), let d2 = unit(b - a), simd_dot(d1, d2) < cosTurn {
                    addSegment(group, aBase, aTop)
                }
            }
            if ringIndex == 0 {
                let idx = EarClip.triangulate(r)
                var k = 0
                while k + 2 < idx.count {
                    addTriangle(point(r[idx[k]], top), point(r[idx[k + 1]], top), point(r[idx[k + 2]], top))
                    k += 3
                }
            }
        }
    }

    private func point(_ xy: SIMD2<Double>, _ up: Double) -> SIMD3<Float> {
        frame.render(east: xy.x, north: xy.y, up: up)
    }
}

/// Shoelace area: positive for counter-clockwise rings.
func signedArea(_ p: [SIMD2<Double>]) -> Double {
    var area = 0.0
    for i in 0..<p.count {
        let q = p[(i + 1) % p.count]
        area += p[i].x * q.y - q.x * p[i].y
    }
    return area / 2
}

private func unit(_ v: SIMD2<Double>) -> SIMD2<Double>? {
    let length = (v.x * v.x + v.y * v.y).squareRoot()
    return length > 1e-9 ? v / length : nil
}
