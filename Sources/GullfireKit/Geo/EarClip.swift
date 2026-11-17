import simd

/// Ear-clipping triangulation of a simple polygon.
public enum EarClip {
    /// `p` is a counter-clockwise simple polygon with no repeated closing point.
    /// Returns triples of indices into `p`. Degenerate input yields fewer triangles.
    public static func triangulate(_ p: [SIMD2<Double>]) -> [Int] {
        var idx = Array(p.indices)
        var out: [Int] = []
        var guardCount = 0

        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        while idx.count > 3 && guardCount < 100_000 {
            var clipped = false
            for i in 0..<idx.count {
                let ia = idx[(i + idx.count - 1) % idx.count]
                let ib = idx[i]
                let ic = idx[(i + 1) % idx.count]
                let a = p[ia], b = p[ib], c = p[ic]
                if cross(a, b, c) <= 1e-9 { continue }   // reflex or flat: not an ear
                var isEar = true
                for j in idx where j != ia && j != ib && j != ic {
                    let q = p[j]
                    if cross(a, b, q) >= 0 && cross(b, c, q) >= 0 && cross(c, a, q) >= 0 {
                        isEar = false
                        break
                    }
                }
                if isEar {
                    out += [ia, ib, ic]
                    idx.remove(at: i)
                    clipped = true
                    break
                }
            }
            guardCount += 1
            if !clipped { break }
        }
        if idx.count >= 3 {
            for i in 1..<(idx.count - 1) { out += [idx[0], idx[i], idx[i + 1]] }
        }
        return out
    }
}
