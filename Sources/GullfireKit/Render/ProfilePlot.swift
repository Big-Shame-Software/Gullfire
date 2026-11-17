import CoreGraphics
import Foundation

/// A side view: altitude against distance along the route, with the building heights underneath
///. Buildings are the tallest obstacle within 20 m of the aircraft at each point.
public enum ProfilePlot {
    /// BGRA pixels, top row first. `points` are (distance metres, altitude metres, building metres).
    public static func render(points: [(distance: Double, altitude: Double, building: Double)],
                              width: Int, height: Int) -> [UInt8] {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: Image.bitmapInfo) else { return }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let last = points.last, last.distance > 0 else { return }
            let top = max(points.map { max($0.altitude, $0.building) }.max() ?? 1, 1) * 1.1
            func point(_ d: Double, _ h: Double) -> CGPoint {
                CGPoint(x: d / last.distance * Double(width), y: h / top * Double(height))
            }
            // Buildings: filled to their height, under the flight line.
            context.setFillColor(CGColor(gray: 0.35, alpha: 1))
            context.move(to: CGPoint(x: 0, y: 0))
            for p in points { context.addLine(to: point(p.distance, p.building)) }
            context.addLine(to: CGPoint(x: Double(width), y: 0))
            context.closePath()
            context.fillPath()
            // Altitude.
            context.setStrokeColor(CGColor(red: 0.15, green: 1, blue: 0.35, alpha: 1))
            context.setLineWidth(max(1, Double(width) / 800))
            if let first = points.first {
                context.move(to: point(first.distance, first.altitude))
                for p in points.dropFirst() { context.addLine(to: point(p.distance, p.altitude)) }
                context.strokePath()
            }
        }
        return pixels
    }
}
