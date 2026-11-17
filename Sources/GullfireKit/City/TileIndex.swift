import Foundation

/// A square grid of tiles over a package's extent. Points outside the
/// extent are clamped into the edge tiles, so every element gets a tile.
struct TileGrid {
    let minEast: Double
    let minNorth: Double
    let sizeM: Double
    let cols: Int
    let rows: Int

    init(extent: Manifest.Extent, sizeM: Double) {
        self.minEast = extent.minEast
        self.minNorth = extent.minNorth
        self.sizeM = sizeM
        self.cols = max(1, Int(((extent.maxEast - extent.minEast) / sizeM).rounded(.up)))
        self.rows = max(1, Int(((extent.maxNorth - extent.minNorth) / sizeM).rounded(.up)))
    }

    func colRow(east: Double, north: Double) -> (col: Int, row: Int) {
        let c = Int(((east - minEast) / sizeM).rounded(.down))
        let r = Int(((north - minNorth) / sizeM).rounded(.down))
        return (min(max(c, 0), cols - 1), min(max(r, 0), rows - 1))
    }

    /// Tile index `row * cols + col` for a point in metres east and north.
    func tile(east: Double, north: Double) -> Int32 {
        let (c, r) = colRow(east: east, north: north)
        return Int32(r * cols + c)
    }
}

/// The geometry re-ordered by tile, with its index. Only the order of the
/// records changes: the same segments and triangles, with the same bytes, as in `MeshBuilder`.
struct TileOrder {
    /// 9 floats per triangle. Tiles ascending; the ground quad (tile -1) last.
    var solids: [Float]
    /// 6 floats per segment. Groups in `LineGroup` order and contiguous; inside a group, tiles
    /// ascending, and within a tile the non-base edges (by segment top, tallest first) before the
    /// base edges.
    var lines: [Float]
    var index: TileIndex

    /// Building heights for `Range.tallCounts`.
    static let heightCutsM: [Double] = [8, 15, 30, 60, 120]

    static func make(_ mesh: MeshBuilder, grid: TileGrid) -> TileOrder {
        let tileCount = grid.cols * grid.rows
        let triCount = mesh.triangleCount

        // Solids: an index permutation, stable within a tile, with the ground quad last.
        func solidKey(_ t: Int) -> Int32 {
            let tile = mesh.triangleTiles[t]
            return tile < 0 ? Int32.max : tile
        }
        var triOrder = Array(0..<triCount)
        triOrder.sort { a, b in
            let ka = solidKey(a), kb = solidKey(b)
            return ka != kb ? ka < kb : a < b
        }
        var solids: [Float] = []
        solids.reserveCapacity(triCount * 9)
        for t in triOrder {
            solids.append(contentsOf: mesh.triangles[(t * 9)..<(t * 9 + 9)])
        }

        var triCountByTile = [Int](repeating: 0, count: tileCount)
        var groundTriangles = 0
        for tile in mesh.triangleTiles {
            if tile < 0 { groundTriangles += 1 } else { triCountByTile[Int(tile)] += 1 }
        }
        var triStart = [Int](repeating: 0, count: tileCount)
        var cursor = 0
        for k in 0..<tileCount {
            triStart[k] = cursor
            cursor += triCountByTile[k]
        }
        precondition(cursor + groundTriangles == triCount, "every triangle is in a tile or the ground")

        // Line groups: a permutation per group, then the flat floats in that order.
        var lineFloats: [Float] = []
        lineFloats.reserveCapacity(mesh.lines.reduce(0) { $0 + $1.count })
        var groupFirst: [[Int]] = []
        var groupCount: [[Int]] = []
        var groupFar: [[Int]] = []
        var groupTall: [[[Int]]?] = []
        var groupStart = 0
        for g in 0..<LineGroup.allCases.count {
            let tiles = mesh.lineTiles[g]
            let isBase = mesh.lineBase[g]
            let segs = tiles.count
            var counts = [Int](repeating: 0, count: tileCount)
            var far = [Int](repeating: 0, count: tileCount)
            for i in 0..<segs {
                let k = Int(tiles[i])
                precondition(k >= 0, "every segment is in a tile")
                counts[k] += 1
                if !isBase[i] { far[k] += 1 }
            }
            var first = [Int](repeating: 0, count: tileCount)
            var position = groupStart
            for k in 0..<tileCount {
                first[k] = position
                position += counts[k]
            }
            func lineKey(_ i: Int) -> Int {
                Int(tiles[i]) * 2 + (isBase[i] ? 1 : 0)
            }
            let src = mesh.lines[g]
            // Segment top: render y is up, so the top of an edge is the larger of its two y values.
            func top(_ i: Int) -> Float {
                max(src[i * 6 + 1], src[i * 6 + 4])
            }
            var order = Array(0..<segs)
            order.sort { a, b in
                let ka = lineKey(a), kb = lineKey(b)
                if ka != kb { return ka < kb }
                if !isBase[a] {
                    let ta = top(a), tb = top(b)
                    if ta != tb { return ta > tb }
                }
                return a < b
            }
            for i in order {
                lineFloats.append(contentsOf: src[(i * 6)..<(i * 6 + 6)])
            }
            // Building groups: per tile, how many leading non-base segments reach each height cut.
            // Because those segments are sorted by top, each count is a prefix of the range.
            var tall: [[Int]]? = nil
            if g <= LineGroup.buildingsDefault.rawValue {
                var perTile = [[Int]](repeating: [Int](repeating: 0, count: heightCutsM.count), count: tileCount)
                for i in 0..<segs where !isBase[i] {
                    let k = Int(tiles[i])
                    let t = Double(top(i))
                    for c in heightCutsM.indices where t >= heightCutsM[c] { perTile[k][c] += 1 }
                }
                tall = perTile
            }
            groupFirst.append(first)
            groupCount.append(counts)
            groupFar.append(far)
            groupTall.append(tall)
            groupStart += segs
        }

        // Bounds over every point (east, north, up) of each tile's segments and triangles.
        var lo = [Double](repeating: .infinity, count: tileCount * 3)
        var hi = [Double](repeating: -.infinity, count: tileCount * 3)
        var used = [Bool](repeating: false, count: tileCount)
        func include(_ k: Int, _ x: Float, _ y: Float, _ z: Float) {
            // Render space: x = east, y = up, z = -north. The box is stored as east, north, up.
            let p = SIMD3<Double>(Double(x), -Double(z), Double(y))
            for axis in 0..<3 {
                lo[k * 3 + axis] = min(lo[k * 3 + axis], p[axis])
                hi[k * 3 + axis] = max(hi[k * 3 + axis], p[axis])
            }
            used[k] = true
        }
        for t in 0..<triCount {
            let k = Int(mesh.triangleTiles[t])
            if k < 0 { continue }
            for v in 0..<3 {
                let i = t * 9 + v * 3
                include(k, mesh.triangles[i], mesh.triangles[i + 1], mesh.triangles[i + 2])
            }
        }
        for g in 0..<LineGroup.allCases.count {
            let src = mesh.lines[g]
            for i in 0..<mesh.lineTiles[g].count {
                let k = Int(mesh.lineTiles[g][i])
                include(k, src[i * 6], src[i * 6 + 1], src[i * 6 + 2])
                include(k, src[i * 6 + 3], src[i * 6 + 4], src[i * 6 + 5])
            }
        }

        var entries: [TileIndex.Entry] = []
        for k in 0..<tileCount where used[k] {
            let ranges = (0..<LineGroup.allCases.count).map { g in
                TileIndex.Range(first: groupFirst[g][k], count: groupCount[g][k], farCount: groupFar[g][k],
                                tallCounts: groupTall[g]?[k])
            }
            entries.append(TileIndex.Entry(
                col: k % grid.cols, row: k / grid.cols,
                min: [lo[k * 3], lo[k * 3 + 1], lo[k * 3 + 2]],
                max: [hi[k * 3], hi[k * 3 + 1], hi[k * 3 + 2]],
                solidFirst: triStart[k] * 3, solidCount: triCountByTile[k] * 3,
                lines: ranges))
        }

        let index = TileIndex(
            sizeM: grid.sizeM, cols: grid.cols, rows: grid.rows,
            always: TileIndex.Always(solidFirst: cursor * 3, solidCount: groundTriangles * 3),
            entries: entries, heightCutsM: heightCutsM)
        return TileOrder(solids: solids, lines: lineFloats, index: index)
    }
}
