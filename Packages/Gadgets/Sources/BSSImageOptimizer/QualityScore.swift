import Accelerate
import Foundation

/// How close a candidate is to the original, on SSIM scales (1 = identical).
///
/// One average hides local damage (a blocky sky, ringing around text), so a candidate must pass
/// several checks: average luma SSIM at full and half size, the worst 64 × 64 tile, and colour (chroma) SSIM.
/// Images with transparency are compared composited over both black and white, and the worse result counts.
public struct QualityScore: Sendable, Equatable, CustomStringConvertible {
    public var luma: Double
    public var lumaHalfSize: Double
    public var worstTile: Double
    public var chroma: Double

    public static let identical = QualityScore(luma: 1, lumaHalfSize: 1, worstTile: 1, chroma: 1)

    public var description: String {
        String(format: "SSIM %.4f · half %.4f · worst tile %.4f · colour %.4f", luma, lumaHalfSize, worstTile, chroma)
    }

    static func worse(_ a: QualityScore, _ b: QualityScore) -> QualityScore {
        QualityScore(luma: min(a.luma, b.luma), lumaHalfSize: min(a.lumaHalfSize, b.lumaHalfSize),
                     worstTile: min(a.worstTile, b.worstTile), chroma: min(a.chroma, b.chroma))
    }
}

enum Metric {
    static let tile = 64
    private static let band = 256                 // rows per strip; bounds memory on huge images
    private static let radius = 5
    private static let kernel: [Float] = {
        let sigma: Float = 1.5
        let k = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let s = k.reduce(0, +)
        return k.map { $0 / s }
    }()

    static func compare(_ reference: PixelBuffer, _ candidate: PixelBuffer, hasAlpha: Bool) -> QualityScore {
        precondition(reference.width == candidate.width && reference.height == candidate.height)
        if !hasAlpha { return score(reference, candidate, background: nil) }
        return QualityScore.worse(score(reference, candidate, background: 0), score(reference, candidate, background: 255))
    }

    private static func score(_ a: PixelBuffer, _ b: PixelBuffer, background: Float?) -> QualityScore {
        let w = a.width, h = a.height
        let hw = max(1, w / 2), hh = max(1, h / 2)
        // Only luma is kept at full size; chroma is built straight at half size (that is how JPEG stores it).
        var ya = luma(a, background: background), yb = luma(b, background: background)
        let full = ssim(ya, yb, w, h, trackTiles: true)
        ya = halve(ya, w, h); yb = halve(yb, w, h)
        let half = ssim(ya, yb, hw, hh, trackTiles: false)
        ya = []; yb = []
        let (cba, cra) = halfChroma(a, background: background)
        let (cbb, crb) = halfChroma(b, background: background)
        let chroma = min(ssim(cba, cbb, hw, hh, trackTiles: false).mean, ssim(cra, crb, hw, hh, trackTiles: false).mean)
        return QualityScore(luma: full.mean, lumaHalfSize: half.mean, worstTile: full.worstTile, chroma: chroma)
    }

    @inline(__always)
    private static func rgb(_ s: UnsafeBufferPointer<UInt8>, _ i: Int, _ background: Float?) -> (Float, Float, Float) {
        var r = Float(s[i * 4]), g = Float(s[i * 4 + 1]), b = Float(s[i * 4 + 2])
        if let bg = background {
            let a = Float(s[i * 4 + 3]) / 255
            r = r * a + bg * (1 - a); g = g * a + bg * (1 - a); b = b * a + bg * (1 - a)
        }
        return (r, g, b)
    }

    /// BT.601 luma (0–255), optionally composited over a gray level.
    private static func luma(_ p: PixelBuffer, background: Float?) -> [Float] {
        var y = [Float](repeating: 0, count: p.pixelCount)
        p.bytes.withUnsafeBufferPointer { s in
            for i in 0..<p.pixelCount {
                let (r, g, b) = rgb(s, i, background)
                y[i] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }
        return y
    }

    /// BT.601 Cb and Cr from 2 × 2 averaged pixels.
    private static func halfChroma(_ p: PixelBuffer, background: Float?) -> ([Float], [Float]) {
        let w = p.width, h = p.height
        let hw = max(1, w / 2), hh = max(1, h / 2)
        let step = w >= 2 && h >= 2 ? 2 : 1
        var cb = [Float](repeating: 0, count: hw * hh), cr = cb
        p.bytes.withUnsafeBufferPointer { s in
            for y in 0..<hh {
                for x in 0..<hw {
                    var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
                    for dy in 0..<step { for dx in 0..<step {
                        let (pr, pg, pb) = rgb(s, (y * step + dy) * w + x * step + dx, background)
                        r += pr; g += pg; b += pb; n += 1
                    } }
                    r /= n; g /= n; b /= n
                    cb[y * hw + x] = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
                    cr[y * hw + x] = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
                }
            }
        }
        return (cb, cr)
    }

    private static func halve(_ src: [Float], _ w: Int, _ h: Int) -> [Float] {
        let hw = max(1, w / 2), hh = max(1, h / 2)
        guard w >= 2, h >= 2 else { return src }
        var out = [Float](repeating: 0, count: hw * hh)
        for y in 0..<hh {
            for x in 0..<hw {
                let i = 2 * y * w + 2 * x
                out[y * hw + x] = (src[i] + src[i + 1] + src[i + w] + src[i + w + 1]) * 0.25
            }
        }
        return out
    }

    /// Gaussian-window SSIM, computed in horizontal strips so memory stays at a few strip-sized buffers.
    static func ssim(_ x: [Float], _ y: [Float], _ w: Int, _ h: Int, trackTiles: Bool) -> (mean: Double, worstTile: Double) {
        let c1: Float = 6.5025, c2: Float = 58.5225   // (0.01·255)², (0.03·255)²
        let tilesAcross = (w + tile - 1) / tile
        var total = 0.0
        var worst = 1.0
        var tileSums = [Double](repeating: 0, count: tilesAcross)
        var tileCounts = [Int](repeating: 0, count: tilesAcross)

        var b0 = 0
        while b0 < h {
            let b1 = min(h, b0 + band)
            let e0 = max(0, b0 - radius), e1 = min(h, b1 + radius)
            let rows = e1 - e0, n = rows * w
            let xs = Array(x[(e0 * w)..<(e1 * w)]), ys = Array(y[(e0 * w)..<(e1 * w)])
            var xx = [Float](repeating: 0, count: n), yy = xx, xy = xx
            vDSP.multiply(xs, xs, result: &xx)
            vDSP.multiply(ys, ys, result: &yy)
            vDSP.multiply(xs, ys, result: &xy)
            let mx = blur(xs, w, rows), my = blur(ys, w, rows)
            let sxx = blur(xx, w, rows), syy = blur(yy, w, rows), sxy = blur(xy, w, rows)

            for row in b0..<b1 {
                let r = row - e0
                for col in 0..<w {
                    let i = r * w + col
                    let ux = mx[i], uy = my[i]
                    let vx = sxx[i] - ux * ux, vy = syy[i] - uy * uy, cov = sxy[i] - ux * uy
                    let s = ((2 * ux * uy + c1) * (2 * cov + c2)) / ((ux * ux + uy * uy + c1) * (vx + vy + c2))
                    total += Double(s)
                    if trackTiles { tileSums[col / tile] += Double(s); tileCounts[col / tile] += 1 }
                }
                if trackTiles, (row + 1) % tile == 0 || row == h - 1 {
                    for t in 0..<tilesAcross where tileCounts[t] > 0 {
                        worst = min(worst, tileSums[t] / Double(tileCounts[t]))
                        tileSums[t] = 0; tileCounts[t] = 0
                    }
                }
            }
            b0 = b1
        }
        return (total / Double(w * h), trackTiles ? worst : 1)
    }

    private static func blur(_ src: [Float], _ w: Int, _ h: Int) -> [Float] {
        guard w > 2 * radius, h > 2 * radius else { return boxFallback(src, w, h) }
        var source = src
        var tmp = [Float](repeating: 0, count: w * h), out = tmp
        source.withUnsafeMutableBytes { s in
            tmp.withUnsafeMutableBytes { t in
                out.withUnsafeMutableBytes { o in
                    var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var tb = vImage_Buffer(data: t.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var ob = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    kernel.withUnsafeBufferPointer { k in
                        _ = vImageConvolve_PlanarF(&sb, &tb, nil, 0, 0, k.baseAddress!, 1, UInt32(k.count), 0, vImage_Flags(kvImageEdgeExtend))
                        _ = vImageConvolve_PlanarF(&tb, &ob, nil, 0, 0, k.baseAddress!, UInt32(k.count), 1, 0, vImage_Flags(kvImageEdgeExtend))
                    }
                }
            }
        }
        return out
    }

    /// Tiny images: plain mean, enough for a meaningful score.
    private static func boxFallback(_ src: [Float], _ w: Int, _ h: Int) -> [Float] {
        let mean = src.reduce(0, +) / Float(max(1, src.count))
        return [Float](repeating: mean, count: src.count)
    }
}
