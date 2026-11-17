import Foundation

/// Reduces an image with a few thousand colours (logos, UI, screenshots, flat art) to a palette,
/// so it can be written as an 8-bit (or smaller) palette PNG. Weighted median cut, refined by k-means,
/// in premultiplied RGBA so transparent edges match well. No dithering: the result is only used if it
/// passes the quality check, and undithered palettes compress far better.
enum Quantizer {
    private struct Entry { var v: SIMD4<Float>; var weight: Float; var key: UInt32 }

    static func quantize(_ pixels: PixelBuffer, histogram: [UInt32: Int], colours: Int) -> PixelBuffer {
        let entries = histogram.map { Entry(v: vector($0.key), weight: Float($0.value), key: $0.key) }
        var palette = medianCut(entries, colours: colours)
        palette = refine(entries, palette: palette, iterations: 6)

        var mapping: [UInt32: UInt32] = [:]
        mapping.reserveCapacity(entries.count)
        for e in entries { mapping[e.key] = pack(palette[nearest(e.v, palette)]) }

        var out = pixels
        out.bytes.withUnsafeMutableBytes { raw in
            let px = raw.bindMemory(to: UInt32.self)
            var last: UInt32 = 0, lastMapped: UInt32 = 0, have = false
            for i in px.indices {
                let v = px[i]
                if !(have && v == last) { last = v; lastMapped = mapping[v] ?? v; have = true }
                px[i] = lastMapped
            }
        }
        return out
    }

    private static func vector(_ c: UInt32) -> SIMD4<Float> {
        let a = Float(c >> 24)
        let f = a / 255
        return SIMD4(Float(c & 0xFF) * f, Float((c >> 8) & 0xFF) * f, Float((c >> 16) & 0xFF) * f, a)
    }

    private static func pack(_ v: SIMD4<Float>) -> UInt32 {
        let a = min(255, max(0, v.w.rounded()))
        guard a > 0 else { return 0 }
        func ch(_ x: Float) -> UInt32 { UInt32(min(255, max(0, (x * 255 / a).rounded()))) }
        return ch(v.x) | ch(v.y) << 8 | ch(v.z) << 16 | UInt32(a) << 24
    }

    private static func nearest(_ v: SIMD4<Float>, _ palette: [SIMD4<Float>]) -> Int {
        var best = 0, bestD = Float.greatestFiniteMagnitude
        for (i, p) in palette.enumerated() {
            let d = v - p
            let dist = (d * d).sum()
            if dist < bestD { bestD = dist; best = i; if dist == 0 { break } }
        }
        return best
    }

    private static func medianCut(_ entries: [Entry], colours: Int) -> [SIMD4<Float>] {
        var boxes: [[Entry]] = [entries]
        while boxes.count < colours {
            // Split the box with the largest weighted spread along its widest channel.
            var pick = -1, pickScore: Float = 0, pickChannel = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let (channel, spread) = widest(box)
                let weight = box.reduce(0) { $0 + $1.weight }
                let score = spread * spread * weight
                if score > pickScore { pickScore = score; pick = i; pickChannel = channel }
            }
            guard pick >= 0 else { break }
            let sorted = boxes[pick].sorted { $0.v[pickChannel] < $1.v[pickChannel] }
            let half = sorted.reduce(0) { $0 + $1.weight } / 2
            var acc: Float = 0, cut = 1
            for (i, e) in sorted.enumerated() {
                acc += e.weight
                if acc >= half { cut = max(1, min(sorted.count - 1, i + 1)); break }
            }
            boxes[pick] = Array(sorted[..<cut])
            boxes.append(Array(sorted[cut...]))
        }
        return boxes.map(mean)
    }

    private static func widest(_ box: [Entry]) -> (Int, Float) {
        var lo = SIMD4<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD4<Float>(repeating: -.greatestFiniteMagnitude)
        for e in box { lo = pointwiseMin(lo, e.v); hi = pointwiseMax(hi, e.v) }
        let r = hi - lo
        var c = 0
        for i in 1..<4 where r[i] > r[c] { c = i }
        return (c, r[c])
    }

    private static func mean(_ box: [Entry]) -> SIMD4<Float> {
        var s = SIMD4<Float>(), w: Float = 0
        for e in box { s += e.v * e.weight; w += e.weight }
        return w > 0 ? s / w : s
    }

    private static func refine(_ entries: [Entry], palette: [SIMD4<Float>], iterations: Int) -> [SIMD4<Float>] {
        var palette = palette
        for _ in 0..<iterations {
            var sums = [SIMD4<Float>](repeating: .zero, count: palette.count)
            var weights = [Float](repeating: 0, count: palette.count)
            for e in entries {
                let i = nearest(e.v, palette)
                sums[i] += e.v * e.weight; weights[i] += e.weight
            }
            var moved = false
            for i in palette.indices where weights[i] > 0 {
                let m = sums[i] / weights[i]
                if m != palette[i] { palette[i] = m; moved = true }
            }
            if !moved { break }
        }
        return palette
    }
}
