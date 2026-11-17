import CoreGraphics
import Foundation

/// A top-down track plot: the flown path in the line colour, on black. Used by `gullfire-render fly`
/// to check a flight by eye.
public enum TrackPlot {
    /// BGRA pixels, top row first. `centre` and `halfSize` are in metres east and north.
    public static func render(track: [(east: Double, north: Double)], centre: (east: Double, north: Double),
                              halfSize: Double, marker: (east: Double, north: Double)?, size: Int) -> [UInt8] {
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: size * bytesPerRow)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: Image.bitmapInfo) else { return }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            // Metres to pixels; north is up, so the image is flipped vertically.
            func point(_ e: Double, _ n: Double) -> CGPoint {
                let x = (e - centre.east + halfSize) / (2 * halfSize) * Double(size)
                let y = (n - centre.north + halfSize) / (2 * halfSize) * Double(size)
                return CGPoint(x: x, y: y)
            }
            context.setStrokeColor(CGColor(red: 0.15, green: 1, blue: 0.35, alpha: 1))
            context.setLineWidth(max(1, Double(size) / 900))
            if let first = track.first {
                context.move(to: point(first.east, first.north))
                for p in track.dropFirst() { context.addLine(to: point(p.east, p.north)) }
                context.strokePath()
            }
            if let m = marker {
                let c = point(m.east, m.north)
                context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.strokeEllipse(in: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
                context.strokePath()
            }
        }
        return pixels
    }
}
