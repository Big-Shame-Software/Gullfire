import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BSSImageOptimizer

// MARK: Fixtures

private func image(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> PixelBuffer {
    var p = PixelBuffer(width: w, height: h)
    for y in 0..<h { for x in 0..<w {
        let (r, g, b, a) = pixel(x, y)
        let i = (y * w + x) * 4
        p.bytes[i] = r; p.bytes[i + 1] = g; p.bytes[i + 2] = b; p.bytes[i + 3] = a
    } }
    return p
}

/// A smooth, textured "photograph": gradients plus deterministic noise, far more than 32 768 colours.
private func photo(_ w: Int = 320, _ h: Int = 240) -> PixelBuffer {
    var seed: UInt64 = 42
    return image(w, h) { x, y in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let n = Int((seed >> 33) % 24) - 12
        func c(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v + n))) }
        return (c(x * 255 / w), c(y * 255 / h), c(128 + Int(60 * sin(Double(x + y) / 15))), 255)
    }
}

private func encodedFile(_ p: PixelBuffer, type: UTType, orientation: Int = 1) throws -> Data {
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
    let opaque = !p.bytes.enumerated().contains { $0.offset % 4 == 3 && $0.element != 255 }
    let props: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1.0]
    CGImageDestinationAddImage(dest, try #require(p.makeCGImage(opaque: opaque)), props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

// MARK: PNG writer

@Suite struct PNGEncoderTests {
    func roundTrip(_ p: PixelBuffer, expect kind: PNGEncoder.Layout.Kind, depth: Int? = nil) throws {
        var source = p
        source.clearInvisibleColour()
        let (data, layout) = PNGEncoder.encode(source, analysis: Analysis(source))
        #expect(layout.kind == kind)
        if let depth { #expect(layout.bitDepth == depth) }
        let decoded = try PixelBuffer(encoded: data)
        #expect(decoded == source, "\(kind) round-trips pixel for pixel")
    }

    @Test func rgbaIsLossless() throws {
        try roundTrip(photo(97, 61).mapAlpha { x, _ in UInt8((x * 7) % 256) }, expect: .rgba)
    }

    @Test func rgbIsLossless() throws { try roundTrip(photo(101, 33), expect: .rgb) }

    @Test func oneBitGray() throws {
        try roundTrip(image(37, 19) { x, y in let v: UInt8 = (x ^ y) & 1 == 0 ? 0 : 255; return (v, v, v, 255) }, expect: .gray, depth: 1)
    }

    @Test func eightBitGray() throws {
        try roundTrip(image(64, 9) { x, _ in let v = UInt8(x * 3); return (v, v, v, 255) }, expect: .gray, depth: 8)
    }

    @Test func translucentPalette() throws {
        let colours: [(UInt8, UInt8, UInt8, UInt8)] = [(255, 0, 0, 255), (0, 0, 255, 128), (0, 0, 0, 0), (9, 200, 30, 255), (1, 2, 3, 40)]
        try roundTrip(image(33, 17) { x, y in colours[(x + 2 * y) % colours.count] }, expect: .palette, depth: 4)
    }

    @Test func eightBitPalette() throws {
        try roundTrip(image(50, 50) { x, y in (UInt8(x * 5), UInt8(y * 5), 7, 255) }.limitedTo(200), expect: .palette, depth: 8)
    }
}

// MARK: Pipeline

@Suite struct ImageOptimizerTests {
    let optimizer = ImageOptimizer(options: .init(keepOriginalIfSmaller: false))

    @Test func photographsBecomeJPEGThatPassesTheCheck() throws {
        let result = try optimizer.optimize(data: try encodedFile(photo(), type: .png))
        #expect(result.format == .jpeg)
        let score = try #require(result.score)
        #expect(ImageOptimizer.Quality.high.accepts(score))
        #expect(result.outputBytes < 320 * 240 * 3 / 2)
    }

    @Test func transparencyStaysPNG() throws {
        let p = photo(120, 80).mapAlpha { x, _ in x < 60 ? 255 : 0 }
        let result = try optimizer.optimize(data: try encodedFile(p, type: .png))
        #expect(result.format == .png)
    }

    @Test func flatGraphicsBecomeSmallPalettePNG() throws {
        let p = image(400, 300) { x, y in x < 200 ? (230, 30, 30, 255) : y < 150 ? (20, 20, 200, 255) : (250, 250, 250, 255) }
        let result = try optimizer.optimize(data: try encodedFile(p, type: .png))
        #expect(result.format == .png)
        #expect(result.method.contains("palette"))
        #expect(result.score == nil, "three colours fit a lossless palette")
        #expect(result.outputBytes < 400)
    }

    @Test func forcedJPEGFlattensOntoTheBackground() throws {
        let p = image(16, 16) { _, _ in (0, 0, 0, 0) }
        var options = ImageOptimizer.Options(format: .jpeg, keepOriginalIfSmaller: false)
        options.background = (255, 255, 255)
        let result = try ImageOptimizer(options: options).optimize(data: try encodedFile(p, type: .png))
        #expect(result.format == .jpeg)
        let decoded = try PixelBuffer(encoded: result.data)
        #expect(decoded.bytes[0] > 250 && decoded.bytes[1] > 250 && decoded.bytes[2] > 250)
    }

    @Test(arguments: 1...8) func everyOrientationIsMadeUpright(orientation: Int) throws {
        // Image I/O's own transform is the reference for what "upright" means.
        let stored = image(5, 3) { x, y in (UInt8(x * 50), UInt8(y * 100), UInt8(x * 10 + y), 255) }.limitedTo(256)
        let file = try encodedFile(stored, type: .png, orientation: orientation)
        let source = try #require(CGImageSourceCreateWithData(file as CFData, nil))
        let reference = try PixelBuffer(image: try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 5,
        ] as CFDictionary)))
        let result = try ImageOptimizer(options: .init(format: .png, keepOriginalIfSmaller: false)).optimize(data: file)
        #expect(try PixelBuffer(encoded: result.data) == reference)
    }

    @Test func downscalesToTheLimit() throws {
        let result = try ImageOptimizer(options: .init(maxPixelSize: 100)).optimize(data: try encodedFile(photo(), type: .png))
        #expect(result.width == 100 && result.height == 75)
    }

    @Test func keepsASmallerOriginal() throws {
        let tiny = try encodedFile(photo(64, 64), type: .jpeg)
        let result = try ImageOptimizer().optimize(data: tiny)
        if result.keptOriginal { #expect(result.data == tiny) } else { #expect(result.outputBytes < tiny.count) }
    }

    @Test func neverOverwritesItsInput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("flat.png")
        let original = try encodedFile(image(40, 40) { _, _ in (1, 2, 3, 255) }, type: .png)
        try original.write(to: input)
        let (_, output) = try optimizer.optimizeFile(at: input, into: dir)
        #expect(output != input)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func lossyResultsCarryAVisionVerdictWithinTheirLimit() throws {
        let result = try optimizer.optimize(data: try encodedFile(photo(), type: .png))
        let vision = try #require(result.vision)
        #expect(vision.allowedDistance > 0)
        #expect(vision.distance <= vision.allowedDistance)
        #expect(vision.aestheticsDrop <= vision.allowedDrop)
    }

    @Test func visionCanBeSwitchedOff() throws {
        var options = ImageOptimizer.Options(keepOriginalIfSmaller: false)
        options.visionCheck = false
        let result = try ImageOptimizer(options: options).optimize(data: try encodedFile(photo(), type: .png))
        #expect(result.vision == nil && result.visionRejections == 0)
    }

    @Test func visionLimitsAreRelativeToTheImagesOwnBaseline() {
        let baseline = VisionMatch(distance: 0.07, aestheticsOriginal: 0.6, aestheticsOutput: 0.59)
        let high = ImageOptimizer.Quality.high.visionLimits(baseline: baseline)
        let max = ImageOptimizer.Quality.maximum.visionLimits(baseline: baseline)
        #expect(abs(high.distance - 0.11) < 0.0001)
        #expect(max.distance < high.distance && max.drop < high.drop)
    }

    @Test func optimizesAnImageInMemory() throws {
        let image = try #require(photo().makeCGImage(opaque: true))
        let result = try ImageOptimizer().optimize(image: image)
        #expect(result.format == .jpeg && result.width == 320 && result.inputBytes == 0)
    }

    @Test func identicalImagesScorePerfectly() {
        let p = photo(80, 60)
        #expect(Metric.compare(p, p, hasAlpha: false) == .identical)
    }
}

private extension PixelBuffer {
    func mapAlpha(_ f: (Int, Int) -> UInt8) -> PixelBuffer {
        var out = self
        for y in 0..<height { for x in 0..<width { out.bytes[(y * width + x) * 4 + 3] = f(x, y) } }
        return out
    }

    /// Folds colours onto at most `n` distinct values (keeps fixtures in palette territory).
    func limitedTo(_ n: Int) -> PixelBuffer {
        var seen: [UInt32: Int] = [:]
        var out = self
        out.bytes.withUnsafeMutableBytes { raw in
            let px = raw.bindMemory(to: UInt32.self)
            for i in px.indices {
                if seen[px[i]] == nil, seen.count < n { seen[px[i]] = seen.count }
                if seen[px[i]] == nil { px[i] = seen.first!.key }
            }
        }
        return out
    }
}

@Suite struct GadgetTests {
    @Test(arguments: [1, 2, 4, 8]) func iconShipsAtEveryScale(scale: Int) throws {
        let url = try #require(ImageOptimizerGadget.iconURL(scale: scale))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 32 * scale && image.height == 32 * scale)
    }
}
