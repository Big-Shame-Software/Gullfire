import Foundation
import simd

/// Maximum building height per square cell, row-major, row 0 at the south edge.
public struct ObstacleGrid: Sendable {
    public let minEast: Double
    public let minNorth: Double
    public let cellSize: Double
    public let cols: Int
    public let rows: Int
    public var heights: [Float]

    public init(minEast: Double, minNorth: Double, cellSize: Double, cols: Int, rows: Int) {
        self.minEast = minEast
        self.minNorth = minNorth
        self.cellSize = cellSize
        self.cols = cols
        self.rows = rows
        self.heights = Array(repeating: 0, count: cols * rows)
    }

    /// Index of the cell containing a point, or nil outside the grid.
    public static func index(east: Double, north: Double, minEast: Double, minNorth: Double,
                             cellSize: Double, cols: Int, rows: Int) -> Int? {
        let c = Int(((east - minEast) / cellSize).rounded(.down))
        let r = Int(((north - minNorth) / cellSize).rounded(.down))
        guard c >= 0, c < cols, r >= 0, r < rows else { return nil }
        return r * cols + c
    }

    /// Raises every cell whose centre is inside `ring` to at least `top`.
    public mutating func stamp(ring: [SIMD2<Double>], top: Float) {
        guard ring.count >= 3 else { return }
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for p in ring {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let c0 = max(0, Int(((minX - minEast) / cellSize).rounded(.down)))
        let c1 = min(cols - 1, Int(((maxX - minEast) / cellSize).rounded(.down)))
        let r0 = max(0, Int(((minY - minNorth) / cellSize).rounded(.down)))
        let r1 = min(rows - 1, Int(((maxY - minNorth) / cellSize).rounded(.down)))
        guard c0 <= c1, r0 <= r1 else { return }
        for r in r0...r1 {
            let y = minNorth + (Double(r) + 0.5) * cellSize
            for c in c0...c1 {
                let x = minEast + (Double(c) + 0.5) * cellSize
                guard Self.contains(ring, x, y) else { continue }
                let i = r * cols + c
                if top > heights[i] { heights[i] = top }
            }
        }
    }

    /// Even-odd ray casting.
    static func contains(_ ring: [SIMD2<Double>], _ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
