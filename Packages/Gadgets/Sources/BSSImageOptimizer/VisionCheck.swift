import CoreGraphics
import Foundation
import Vision

/// How Apple Vision sees a finished image compared with the original.
///
/// Both sides are scored from the same decoded pixels (never the original *file*), because Vision reads
/// some containers — TIFF, WebP, RAW — differently from the identical pixels in a PNG, which would make
/// an untouched copy look "different".
public struct VisionMatch: Sendable, Equatable, CustomStringConvertible {
    /// Feature-print distance (0 = Vision sees the same image).
    public var distance: Float
    public var aestheticsOriginal: Float
    public var aestheticsOutput: Float
    /// Limits this image had to meet (relative to its own q98 JPEG); 0 when not set.
    public var allowedDistance: Float = 0
    public var allowedDrop: Float = 0
    /// Positive when the output scores lower than the original.
    public var aestheticsDrop: Float { aestheticsOriginal - aestheticsOutput }

    public var description: String {
        String(format: "Vision distance %.4f (limit %.4f) · aesthetics %+.3f → %+.3f (drop limit %.3f)",
               distance, allowedDistance, aestheticsOriginal, aestheticsOutput, allowedDrop)
    }
}

/// Vision's view of the reference pixels, computed once per image and reused for every candidate.
final class VisionReference {
    let featurePrint: VNFeaturePrintObservation
    let aesthetics: Float
    let opaque: Bool

    init(_ pixels: PixelBuffer, opaque: Bool) throws {
        (featurePrint, aesthetics) = try VisionReference.observe(pixels, opaque: opaque)
        self.opaque = opaque
    }

    func compare(_ candidate: PixelBuffer) throws -> VisionMatch {
        let (print, aesthetics) = try Self.observe(candidate, opaque: opaque)
        var distance: Float = 0
        try print.computeDistance(&distance, to: featurePrint)
        return VisionMatch(distance: distance, aestheticsOriginal: self.aesthetics, aestheticsOutput: aesthetics)
    }

    private static func observe(_ pixels: PixelBuffer, opaque: Bool) throws -> (VNFeaturePrintObservation, Float) {
        guard let image = pixels.makeCGImage(opaque: opaque) else { throw ImageOptimizerError.unreadable }
        let printRequest = VNGenerateImageFeaturePrintRequest()
        let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([printRequest, aestheticsRequest])
        guard let print = printRequest.results?.first, let score = aestheticsRequest.results?.first
        else { throw ImageOptimizerError.unreadable }
        return (print, score.overallScore)
    }
}

/// Calibration hook for the Vision limits: Vision's reading of JPEG at each quality, from pixels.
@_spi(Calibration)
public func visionCalibration(fileAt url: URL, qualities: [Int]) throws -> [(quality: Int, ssim: Double, worstTile: Double, distance: Float, drop: Float)] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageOptimizerError.unreadable }
    let pixels = try PixelBuffer(image: image).flattened(onto: (255, 255, 255))
    let reference = try VisionReference(pixels, opaque: true)
    var rows: [(Int, Double, Double, Float, Float)] = []
    // q 0 = the reference itself, decoded again from a lossless PNG (noise floor).
    for q in qualities {
        let decoded: PixelBuffer
        if q == 0 {
            decoded = try PixelBuffer(encoded: PNGEncoder.encode(pixels, analysis: Analysis(pixels), thorough: false).data)
        } else {
            decoded = try PixelBuffer(encoded: try JPEGEncoder.encode(pixels, quality: q))
        }
        let s = Metric.compare(pixels, decoded, hasAlpha: false)
        let v = try reference.compare(decoded)
        rows.append((q, s.luma, s.worstTile, v.distance, v.aestheticsDrop))
    }
    return rows
}
