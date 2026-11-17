import Foundation

/// Packs a city without holding it in memory. The writer adds geometry to a `MeshBuilder`; every so
/// often `flush` appends it to one file per tile row (a row of the tile grid), in the order it was added. `assemble` then reads one
/// row at a time, orders it exactly as `TileOrder.make` orders the whole mesh (tiles ascending, and inside a group non-base edges
/// by top, tallest first, before base edges), and writes it to its place in `solids.bin` and `lines.bin`. Tiles are row-major, so
/// tile order is row order and each group's section of `lines.bin` is its rows in turn. The result is byte for byte what the
/// in-memory path writes (a test compares them); memory is the mesh batch plus one row.
final class TileSpill {
    /// Bytes of a record: kind, tile and base (3 x Int32), then 9 floats (a triangle's vertices, or a segment's 6 and 3 spare).
    static let recordSize = 12 + 36
    let directory: URL
    let grid: TileGrid
    private(set) var triangleCountByRow: [Int]
    private(set) var segmentCountByRowGroup: [[Int]]      // [group][row]
    /// The ground quad's triangles (tile -1), kept in memory and written last.
    private var ground: [Float] = []

    init(directory: URL, grid: TileGrid) throws {
        self.directory = directory
        self.grid = grid
        triangleCountByRow = [Int](repeating: 0, count: grid.rows)
        segmentCountByRowGroup = Array(repeating: [Int](repeating: 0, count: grid.rows), count: LineGroup.allCases.count)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(row: Int) -> URL { directory.appendingPathComponent("row\(row).bin") }

    /// Appends the mesh's contents to the row files, then empties the mesh.
    func flush(_ mesh: inout MeshBuilder) throws {
        var buffers: [Int: Data] = [:]
        func append(row: Int, kind: Int32, tile: Int32, base: Int32, floats: ArraySlice<Float>, count: Int) {
            var rec = Data(capacity: Self.recordSize)
            var k = kind, t = tile, b = base
            withUnsafeBytes(of: &k) { rec.append(contentsOf: $0) }
            withUnsafeBytes(of: &t) { rec.append(contentsOf: $0) }
            withUnsafeBytes(of: &b) { rec.append(contentsOf: $0) }
            floats.withUnsafeBytes { rec.append(contentsOf: $0) }
            if count < 9 { rec.append(Data(count: (9 - count) * 4)) }
            buffers[row, default: Data()].append(rec)
        }
        for t in 0..<mesh.triangleCount {
            let tile = mesh.triangleTiles[t]
            let floats = mesh.triangles[(t * 9)..<(t * 9 + 9)]
            if tile < 0 {
                ground.append(contentsOf: floats)
            } else {
                let row = Int(tile) / grid.cols
                triangleCountByRow[row] += 1
                append(row: row, kind: 0, tile: tile, base: 0, floats: floats, count: 9)
            }
        }
        for g in 0..<LineGroup.allCases.count {
            let src = mesh.lines[g]
            for i in 0..<mesh.lineTiles[g].count {
                let tile = mesh.lineTiles[g][i]
                precondition(tile >= 0, "every segment is in a tile")
                let row = Int(tile) / grid.cols
                segmentCountByRowGroup[g][row] += 1
                append(row: row, kind: Int32(1 + g), tile: tile, base: mesh.lineBase[g][i] ? 1 : 0, floats: src[(i * 6)..<(i * 6 + 6)], count: 6)
            }
        }
        for (row, data) in buffers {
            let path = url(row: row)
            if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: path)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        }
        mesh.triangles.removeAll(keepingCapacity: true)
        mesh.triangleTiles.removeAll(keepingCapacity: true)
        for g in 0..<LineGroup.allCases.count {
            mesh.lines[g].removeAll(keepingCapacity: true)
            mesh.lineTiles[g].removeAll(keepingCapacity: true)
            mesh.lineBase[g].removeAll(keepingCapacity: true)
        }
    }

    struct Result {
        var index: TileIndex
        var triangleCount: Int
        var groupCounts: [Int]
        var solidBytes: Int
        var lineBytes: Int
    }

    /// Writes `solids.bin` and `lines.bin` into `directory` and returns the tile index and totals. The mesh must have been flushed,
    /// and the ground triangles added (tile -1) and flushed too.
    func assemble(solidsURL: URL, linesURL: URL) throws -> Result {
        let groups = LineGroup.allCases.count
        let tileCount = grid.cols * grid.rows
        let heightCuts = TileOrder.heightCutsM
        let tileTriangles = triangleCountByRow.reduce(0, +)
        let groupTotals = (0..<groups).map { segmentCountByRowGroup[$0].reduce(0, +) }
        var groupStart = [Int](repeating: 0, count: groups)
        for g in 1..<groups { groupStart[g] = groupStart[g - 1] + groupTotals[g - 1] }
        let segmentCount = groupTotals.reduce(0, +)

        FileManager.default.createFile(atPath: solidsURL.path, contents: nil)
        FileManager.default.createFile(atPath: linesURL.path, contents: nil)
        let solidsOut = try FileHandle(forWritingTo: solidsURL)
        let linesOut = try FileHandle(forWritingTo: linesURL)
        defer { try? solidsOut.close(); try? linesOut.close() }

        struct Bounds { var lo = SIMD3<Double>(repeating: .infinity); var hi = SIMD3<Double>(repeating: -.infinity) }
        var bounds: [Int: Bounds] = [:]
        func include(_ k: Int, _ x: Float, _ y: Float, _ z: Float) {
            // Render space: x = east, y = up, z = -north. The box is stored as east, north, up.
            let p = SIMD3<Double>(Double(x), -Double(z), Double(y))
            var b = bounds[k, default: Bounds()]
            b.lo = SIMD3(min(b.lo.x, p.x), min(b.lo.y, p.y), min(b.lo.z, p.z))
            b.hi = SIMD3(max(b.hi.x, p.x), max(b.hi.y, p.y), max(b.hi.z, p.z))
            bounds[k] = b
        }
        var triStart: [Int: Int] = [:], triCount: [Int: Int] = [:]
        var lineFirst: [Int: [Int]] = [:], lineCount: [Int: [Int]] = [:], lineFar: [Int: [Int]] = [:]
        var lineTall: [Int: [[Int]?]] = [:]
        func ensure(_ k: Int) {
            if lineFirst[k] == nil {
                lineFirst[k] = [Int](repeating: 0, count: groups)
                lineCount[k] = [Int](repeating: 0, count: groups)
                lineFar[k] = [Int](repeating: 0, count: groups)
                lineTall[k] = [[Int]?](repeating: nil, count: groups)
            }
        }
        var solidCursor = 0                                  // triangles written so far
        var groupCursor = groupStart                         // next segment position in each group

        for row in 0..<grid.rows where triangleCountByRow[row] > 0 || (0..<groups).contains(where: { segmentCountByRowGroup[$0][row] > 0 }) {
            let data = try Data(contentsOf: url(row: row))
            let n = data.count / Self.recordSize
            var triangles: [(tile: Int32, f: [Float])] = []
            var segments = Array(repeating: [(tile: Int32, base: Bool, f: [Float])](), count: groups)
            data.withUnsafeBytes { raw in
                for i in 0..<n {
                    let o = i * Self.recordSize
                    let kind = raw.loadUnaligned(fromByteOffset: o, as: Int32.self)
                    let tile = raw.loadUnaligned(fromByteOffset: o + 4, as: Int32.self)
                    let base = raw.loadUnaligned(fromByteOffset: o + 8, as: Int32.self)
                    let count = kind == 0 ? 9 : 6
                    var f = [Float](repeating: 0, count: count)
                    for j in 0..<count { f[j] = raw.loadUnaligned(fromByteOffset: o + 12 + j * 4, as: Float.self) }
                    if kind == 0 { triangles.append((tile, f)) } else { segments[Int(kind) - 1].append((tile, base != 0, f)) }
                }
            }
            // Solids: tiles ascending, insertion order inside a tile.
            if !triangles.isEmpty {
                let order = triangles.indices.sorted { a, b in
                    triangles[a].tile != triangles[b].tile ? triangles[a].tile < triangles[b].tile : a < b
                }
                var out = [Float]()
                out.reserveCapacity(order.count * 9)
                for i in order {
                    let tile = Int(triangles[i].tile)
                    if triStart[tile] == nil { triStart[tile] = solidCursor }
                    triCount[tile, default: 0] += 1
                    solidCursor += 1
                    ensure(tile)
                    for v in 0..<3 { include(tile, triangles[i].f[v * 3], triangles[i].f[v * 3 + 1], triangles[i].f[v * 3 + 2]) }
                    out.append(contentsOf: triangles[i].f)
                }
                try solidsOut.write(contentsOf: out.withUnsafeBytes { Data($0) })
            }
            // Lines: per group, tiles ascending; non-base edges by top (tallest first) then insertion order, then base edges.
            for g in 0..<groups where !segments[g].isEmpty {
                let segs = segments[g]
                func top(_ i: Int) -> Float { max(segs[i].f[1], segs[i].f[4]) }
                func key(_ i: Int) -> Int { Int(segs[i].tile) * 2 + (segs[i].base ? 1 : 0) }
                let order = segs.indices.sorted { a, b in
                    let ka = key(a), kb = key(b)
                    if ka != kb { return ka < kb }
                    if !segs[a].base {
                        let ta = top(a), tb = top(b)
                        if ta != tb { return ta > tb }
                    }
                    return a < b
                }
                var out = [Float]()
                out.reserveCapacity(order.count * 6)
                var position = groupCursor[g]
                var counts: [Int: Int] = [:], fars: [Int: Int] = [:], firsts: [Int: Int] = [:]
                var talls: [Int: [Int]] = [:]
                for i in order {
                    let tile = Int(segs[i].tile)
                    if firsts[tile] == nil { firsts[tile] = position }
                    counts[tile, default: 0] += 1
                    if !segs[i].base {
                        fars[tile, default: 0] += 1
                        if g <= LineGroup.buildingsDefault.rawValue {
                            var t = talls[tile] ?? [Int](repeating: 0, count: heightCuts.count)
                            let h = Double(top(i))
                            for c in heightCuts.indices where h >= heightCuts[c] { t[c] += 1 }
                            talls[tile] = t
                        }
                    }
                    include(tile, segs[i].f[0], segs[i].f[1], segs[i].f[2])
                    include(tile, segs[i].f[3], segs[i].f[4], segs[i].f[5])
                    out.append(contentsOf: segs[i].f)
                    position += 1
                }
                try linesOut.seek(toOffset: UInt64(groupCursor[g]) * 24)
                try linesOut.write(contentsOf: out.withUnsafeBytes { Data($0) })
                groupCursor[g] = position
                for (tile, c) in counts {
                    ensure(tile)
                    lineFirst[tile]![g] = firsts[tile]!
                    lineCount[tile]![g] = c
                    lineFar[tile]![g] = fars[tile] ?? 0
                    if g <= LineGroup.buildingsDefault.rawValue {
                        lineTall[tile]![g] = talls[tile] ?? [Int](repeating: 0, count: heightCuts.count)
                    }
                }
            }
            // A tile with building segments in a group but all base edges still has a tall array of zeros, as in the in-memory path.
            for g in 0..<min(groups, LineGroup.buildingsDefault.rawValue + 1) {
                for tile in Set(segments[g].map { Int($0.tile) }) where lineTall[tile]![g] == nil {
                    lineTall[tile]![g] = [Int](repeating: 0, count: heightCuts.count)
                }
            }
            try FileManager.default.removeItem(at: url(row: row))
        }
        precondition(solidCursor == tileTriangles, "every tile triangle was written")
        // Ground quad last.
        try solidsOut.write(contentsOf: ground.withUnsafeBytes { Data($0) })
        let groundTriangles = ground.count / 9

        // Groups with no segments in a tile keep first = the group's running position in the in-memory path; here only tiles that
        // have segments in a group are filled, so empty ranges take the position the in-memory path computes: the group start plus
        // the segments of all earlier tiles. Recompute them from the counts.
        var entries: [TileIndex.Entry] = []
        var usedTiles = Set(bounds.keys)
        usedTiles.formUnion(triStart.keys)
        let sortedTiles = usedTiles.sorted()
        // First positions per group for every tile (used or not): cumulative over tile order.
        var tileFirst = [[Int]](repeating: [Int](repeating: 0, count: tileCount), count: groups)
        for g in 0..<groups {
            var pos = groupStart[g]
            for k in 0..<tileCount {
                tileFirst[g][k] = pos
                pos += lineCount[k]?[g] ?? 0
            }
        }
        var solidPosition = 0
        var triFirst = [Int](repeating: 0, count: tileCount)
        for k in 0..<tileCount {
            triFirst[k] = solidPosition
            solidPosition += triCount[k] ?? 0
        }
        for k in sortedTiles {
            let b = bounds[k] ?? Bounds()
            let ranges = (0..<groups).map { g in
                TileIndex.Range(first: tileFirst[g][k], count: lineCount[k]?[g] ?? 0, farCount: lineFar[k]?[g] ?? 0,
                                tallCounts: g <= LineGroup.buildingsDefault.rawValue
                                    ? (lineTall[k]?[g] ?? [Int](repeating: 0, count: heightCuts.count)) : nil)
            }
            entries.append(TileIndex.Entry(
                col: k % grid.cols, row: k / grid.cols,
                min: [b.lo.x, b.lo.y, b.lo.z], max: [b.hi.x, b.hi.y, b.hi.z],
                solidFirst: triFirst[k] * 3, solidCount: (triCount[k] ?? 0) * 3, lines: ranges))
        }
        let index = TileIndex(sizeM: grid.sizeM, cols: grid.cols, rows: grid.rows,
                              always: TileIndex.Always(solidFirst: tileTriangles * 3, solidCount: groundTriangles * 3),
                              entries: entries, heightCutsM: heightCuts)
        try? FileManager.default.removeItem(at: directory)
        return Result(index: index, triangleCount: tileTriangles + groundTriangles, groupCounts: groupTotals,
                      solidBytes: (tileTriangles + groundTriangles) * 36, lineBytes: segmentCount * 24)
    }
}
