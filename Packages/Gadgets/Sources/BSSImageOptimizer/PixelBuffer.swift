import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// 8-bit sRGB RGBA, straight (not premultiplied) alpha, tightly packed rows.
struct PixelBuffer: Sendable, Equatable {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    var pixelCount: Int { width * height }

    init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init(width: Int, height: Int) {
        self.init(width: width, height: height, bytes: [UInt8](repeating: 0, count: width * height * 4))
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Decoding

    /// Converts any CGImage (any colour space, depth or alpha layout) to straight-alpha sRGB RGBA8.
    init(image: CGImage) throws {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { throw ImageOptimizerError.unreadable }
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: Self.sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), renderingIntent: .perceptual)
        else { throw ImageOptimizerError.unreadable }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let status = bytes.withUnsafeMutableBytes { raw -> vImage_Error in
            var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            return vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoAllocate))
        }
        guard status == kvImageNoError else { throw ImageOptimizerError.unreadable }
        self.init(width: w, height: h, bytes: bytes)
    }

    /// Decodes encoded bytes (used to score an encoded candidate). Orientation is ignored.
    init(encoded data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ImageOptimizerError.unreadable }
        try self.init(image: image)
    }

    func makeCGImage(opaque: Bool) -> CGImage? {
        let info: CGImageAlphaInfo = opaque ? .noneSkipLast : .last
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Self.sRGB, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .perceptual)
    }

    // MARK: Pixel operations

    /// Fully transparent pixels have invisible colour; zeroing it costs nothing visually and compresses better.
    mutating func clearInvisibleColour() {
        bytes.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                if p[i + 3] == 0 { p[i] = 0; p[i + 1] = 0; p[i + 2] = 0 }
                i += 4
            }
        }
    }

    /// Composites onto an opaque background colour (for JPEG output of an image with transparency).
    func flattened(onto background: (r: UInt8, g: UInt8, b: UInt8)) -> PixelBuffer {
        var out = self
        out.bytes.withUnsafeMutableBufferPointer { p in
            var i = 0
            let bg = [Int(background.r), Int(background.g), Int(background.b)]
            while i < p.count {
                let a = Int(p[i + 3])
                if a != 255 {
                    for c in 0..<3 { p[i + c] = UInt8((Int(p[i + c]) * a + bg[c] * (255 - a) + 127) / 255) }
                    p[i + 3] = 255
                }
                i += 4
            }
        }
        return out
    }

    /// Applies an EXIF orientation (1–8) so the pixels are upright and the file needs no orientation tag.
    func oriented(_ orientation: Int) throws -> PixelBuffer {
        switch orientation {
        case 2: return try reflected(horizontal: true)
        case 3: return try rotated(UInt8(kRotate180DegreesClockwise))
        case 4: return try reflected(horizontal: false)
        case 5: return try reflected(horizontal: true).rotated(UInt8(kRotate90DegreesCounterClockwise))
        case 6: return try rotated(UInt8(kRotate90DegreesClockwise))
        case 7: return try reflected(horizontal: true).rotated(UInt8(kRotate90DegreesClockwise))
        case 8: return try rotated(UInt8(kRotate90DegreesCounterClockwise))
        default: return self
        }
    }

    private func rotated(_ constant: UInt8) throws -> PixelBuffer {
        let quarter = constant == UInt8(kRotate90DegreesClockwise) || constant == UInt8(kRotate90DegreesCounterClockwise)
        var out = quarter ? PixelBuffer(width: height, height: width) : PixelBuffer(width: width, height: height)
        let ow = out.width, oh = out.height
        var src = self.bytes
        var background: [UInt8] = [0, 0, 0, 0]
        let status = src.withUnsafeMutableBytes { s in
            out.bytes.withUnsafeMutableBytes { d in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(oh), width: vImagePixelCount(ow), rowBytes: ow * 4)
                return vImageRotate90_ARGB8888(&sb, &db, constant, &background, vImage_Flags(kvImageNoFlags))
            }
        }
        guard status == kvImageNoError else { throw ImageOptimizerError.unreadable }
        return out
    }

    private func reflected(horizontal: Bool) throws -> PixelBuffer {
        var out = PixelBuffer(width: width, height: height)
        var src = self.bytes
        let status = src.withUnsafeMutableBytes { s in
            out.bytes.withUnsafeMutableBytes { d in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                return horizontal
                    ? vImageHorizontalReflect_ARGB8888(&sb, &db, vImage_Flags(kvImageNoFlags))
                    : vImageVerticalReflect_ARGB8888(&sb, &db, vImage_Flags(kvImageNoFlags))
            }
        }
        guard status == kvImageNoError else { throw ImageOptimizerError.unreadable }
        return out
    }

    /// High-quality (Lanczos) downscale so the longer side is at most `maxPixelSize`.
    /// Resampled in premultiplied space so transparent edges don't grow dark halos.
    func downscaled(toFit maxPixelSize: Int) throws -> PixelBuffer {
        let longest = max(width, height)
        guard maxPixelSize > 0, longest > maxPixelSize else { return self }
        let scale = Double(maxPixelSize) / Double(longest)
        let nw = max(1, Int((Double(width) * scale).rounded()))
        let nh = max(1, Int((Double(height) * scale).rounded()))
        var src = self.bytes
        var out = PixelBuffer(width: nw, height: nh)
        let status = src.withUnsafeMutableBytes { s -> vImage_Error in
            var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            var e = vImagePremultiplyData_RGBA8888(&sb, &sb, vImage_Flags(kvImageNoFlags))
            guard e == kvImageNoError else { return e }
            return out.bytes.withUnsafeMutableBytes { d in
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(nh), width: vImagePixelCount(nw), rowBytes: nw * 4)
                e = vImageScale_ARGB8888(&sb, &db, nil, vImage_Flags(kvImageHighQualityResampling))
                guard e == kvImageNoError else { return e }
                return vImageUnpremultiplyData_RGBA8888(&db, &db, vImage_Flags(kvImageNoFlags))
            }
        }
        guard status == kvImageNoError else { throw ImageOptimizerError.unreadable }
        return out
    }
}
