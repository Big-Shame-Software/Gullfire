import Foundation
import simd

/// A uniform grid over a street graph's stretches, so a query near a point reads only the stretches in nearby cells
/// instead of every stretch. Only stretches that `canStartAny` are indexed, as the pick and overlay scans only use those.
/// A stretch is filed under every cell that any of its segments' bounding boxes touches, so no stretch within a
/// query radius is ever missed (a cell corner included).
public struct StreetIndex: Sendable {
    /// Metres per grid cell.
    public static let cellSize = 500.0

    /// South-west corner of the grid, in metres (east, north).
    private let origin: SIMD2<Double>
    private let columns: Int
    private let rows: Int
    /// Compressed rows: the stretch indices of cell `c` are `items[cellStart[c]..<cellStart[c + 1]]`, with `c = row * columns + column`.
    private let cellStart: [Int]
    /// Indices into `graph.stretches`. A stretch may appear in several cells; a query removes the repeats.
    private let items: [Int]

    /// Builds the index from a graph. Cost is linear in the number of stretch points.
    public init(graph: StreetGraph) {
        let size = Self.cellSize
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for stretch in graph.stretches where stretch.canStartAny {
            for p in stretch.polyline {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        if !minX.isFinite || !minY.isFinite {
            // Nothing to index: a single empty cell.
            origin = .zero
            columns = 1
            rows = 1
            cellStart = [0, 0]
            items = []
            return
        }
        let cols = Int(((maxX - minX) / size).rounded(.down)) + 1
        let rowCount = Int(((maxY - minY) / size).rounded(.down)) + 1
        origin = SIMD2(minX, minY)
        columns = cols
        rows = rowCount

        func column(_ x: Double) -> Int { min(max(Int(((x - minX) / size).rounded(.down)), 0), cols - 1) }
        func row(_ y: Double) -> Int { min(max(Int(((y - minY) / size).rounded(.down)), 0), rowCount - 1) }

        // The cells of each stretch, once each, in stretch order.
        var perStretch: [(index: Int, cells: [Int])] = []
        for (index, stretch) in graph.stretches.enumerated() where stretch.canStartAny {
            let line = stretch.polyline
            guard !line.isEmpty else { continue }
            var cells = Set<Int>()
            // A one-point stretch is its point's bounding box; otherwise each segment's box.
            let segments = line.count == 1 ? [(line[0], line[0])] : (1..<line.count).map { (line[$0 - 1], line[$0]) }
            for (a, b) in segments {
                let c0 = column(min(a.x, b.x)), c1 = column(max(a.x, b.x))
                let r0 = row(min(a.y, b.y)), r1 = row(max(a.y, b.y))
                for r in r0...r1 {
                    for c in c0...c1 { cells.insert(r * cols + c) }
                }
            }
            perStretch.append((index, cells.sorted()))
        }

        var counts = [Int](repeating: 0, count: cols * rowCount)
        for entry in perStretch { for cell in entry.cells { counts[cell] += 1 } }
        var start = [Int](repeating: 0, count: cols * rowCount + 1)
        for cell in 0..<(cols * rowCount) { start[cell + 1] = start[cell] + counts[cell] }
        var fill = start
        var filled = [Int](repeating: 0, count: start[cols * rowCount])
        for entry in perStretch {
            for cell in entry.cells {
                filled[fill[cell]] = entry.index
                fill[cell] += 1
            }
        }
        cellStart = start
        items = filled
    }

    /// The indices (into `graph.stretches`, ascending, no repeats) of every indexed stretch that may lie within `radius`
    /// metres of `hit`. A superset: callers still measure the distance. Empty when no stretch can be that near.
    public func candidateIndices(near hit: SIMD2<Double>, within radius: Double) -> [Int] {
        let size = Self.cellSize
        func column(_ x: Double) -> Int { Int(((x - origin.x) / size).rounded(.down)) }
        func row(_ y: Double) -> Int { Int(((y - origin.y) / size).rounded(.down)) }
        let c0 = max(column(hit.x - radius), 0), c1 = min(column(hit.x + radius), columns - 1)
        let r0 = max(row(hit.y - radius), 0), r1 = min(row(hit.y + radius), rows - 1)
        guard c0 <= c1, r0 <= r1 else { return [] }

        var found: [Int] = []
        for r in r0...r1 {
            for c in c0...c1 {
                let cell = r * columns + c
                found.append(contentsOf: items[cellStart[cell]..<cellStart[cell + 1]])
            }
        }
        found.sort()
        var result: [Int] = []
        result.reserveCapacity(found.count)
        for index in found where index != result.last { result.append(index) }
        return result
    }
}

extension StreetOverlay {
    /// The same list as `available(in:near:radius:maxSegments:)`, reading the stretches within `radius` from `index` rather
    /// than scanning every stretch. Identical results: the same stretches, distances, order and segment cap.
    public static func available(in graph: StreetGraph, near p: SIMD2<Double>, radius: Double, maxSegments: Int,
                                 index: StreetIndex) -> [Int] {
        var near: [(index: Int, distance: Double)] = []
        for candidate in index.candidateIndices(near: p, within: radius) where graph.stretches[candidate].canStartAny {
            let d = StreetPicker.distance(from: p, to: graph.stretches[candidate])
            if d <= radius { near.append((candidate, d)) }
        }
        near.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.index < $1.index }

        var result: [Int] = []
        var total = 0
        for candidate in near {
            let count = max(0, graph.stretches[candidate.index].polyline.count - 1)
            if total + count > maxSegments { break }
            total += count
            result.append(candidate.index)
        }
        return result
    }
}
