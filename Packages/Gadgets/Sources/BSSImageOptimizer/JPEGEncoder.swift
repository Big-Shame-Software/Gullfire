import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Baseline-compatible progressive JPEG via Image I/O: sRGB pixels, no EXIF, no orientation tag.
enum JPEGEncoder {
    static func encode(_ pixels: PixelBuffer, quality: Int) throws -> Data {
        guard let image = pixels.makeCGImage(opaque: true) else { throw ImageOptimizerError.encodingFailed }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ImageOptimizerError.encodingFailed }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Double(quality) / 100,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageOptimizerError.encodingFailed }
        return out as Data
    }
}
