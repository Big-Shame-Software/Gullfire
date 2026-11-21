import Foundation
import simd

/// Render-space segments for street stretches, for the line overlays that show streets in pick mode.
/// Render space: x east, y altitude, z = -north (the same as the city's lines and the pick ray).
public enum StreetOverlay {
    /// The centre line of a stretch at a height, as six floats per segment (ax, ay, az, bx, by, bz): consecutive points
    /// joined, so a stretch of n points gives n - 1 segments. Empty for a stretch with fewer than two points.
    public static func segments(for stretch: StreetStretch, height: Double) -> [Float] {
        let line = stretch.polyline
        guard line.count > 1 else { return [] }
        let y = Float(height)
        var out: [Float] = []
        out.reserveCapacity((line.count - 1) * 6)
        for k in 1..<line.count {
            let a = line[k - 1], b = line[k]
            out += [Float(a.x), y, Float(-a.y), Float(b.x), y, Float(-b.y)]
        }
        return out
    }

    /// The indices of the stretches whose centre line comes within `radius` metres of `p` (east, north, metres), nearest
    /// first (ties keep the lower index first). The list stops before the total segment count would exceed `maxSegments`:
    /// a stretch that would take it over is not taken, and nothing after it is either.
    public static func available(in graph: StreetGraph, near p: SIMD2<Double>, radius: Double, maxSegments: Int) -> [Int] {
        var near: [(index: Int, distance: Double)] = []
        for (index, stretch) in graph.stretches.enumerated() where stretch.canStartAny {
            let d = StreetPicker.distance(from: p, to: stretch)
            if d <= radius { near.append((index, d)) }
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
