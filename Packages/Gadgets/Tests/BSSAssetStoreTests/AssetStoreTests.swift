import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BSSAssetStore

/// Assets are stored once by hash, images lose their metadata, and AVIF is kept only when it saves enough.
@Suite struct AssetStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "assetstore-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A noisy photo-like image, so that it does not compress to nothing, written with GPS and EXIF metadata.
    static func image(width: Int, height: Int, type: UTType, quality: Double = 1.0) -> Data {
        var rng = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x * 255) / max(width - 1, 1))
                pixels[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                pixels[i + 2] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let cg = context.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.6, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret camera note"],
        ]
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func hasGPS(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return props[kCGImagePropertyGPSDictionary] != nil
    }

    @Test func theSameBytesAreStoredOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore(root: root)
        let css = Data("body { color: red }".utf8)
        let first = try store.store(css, contentType: "text/css")
        let second = try store.store(css, contentType: "text/css")
        #expect(first.isNew && !second.isNew)
        #expect(first.path == second.path)
        #expect(first.change == .keptAsGiven)
        #expect(first.path.hasSuffix(".css") && first.path.hasPrefix(String(first.sha256.prefix(2)) + "/"))
        #expect(try Data(contentsOf: store.url(for: first)) == css)
    }

    @Test func fontsAndSVGAreKeptAsGiven() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore(root: root)
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)
        #expect(try store.store(svg, fileExtension: "svg").path.hasSuffix(".svg"))
        #expect(try store.store(Data([0, 1, 0, 0]), fileExtension: "woff2").path.hasSuffix(".woff2"))
        #expect(try store.store(Data([1, 2, 3]), fileExtension: "").path.hasSuffix(".bin"))
    }

    @Test func aLargeImageBecomesAVIFWithoutMetadata() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Self.image(width: 800, height: 600, type: .png)
        #expect(Self.hasGPS(png))
        let stored = try AssetStore(root: root).store(png)
        #expect(stored.change == .avif)
        #expect(stored.path.hasSuffix(".avif"))
        #expect(stored.bytes <= stored.originalBytes * 3 / 4)
        let saved = try Data(contentsOf: root.appending(path: stored.path))
        #expect(!Self.hasGPS(saved))
    }

    @Test func aBigImageIsScaledToTheLongSide() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Self.image(width: 1000, height: 500, type: .png)
        let stored = try AssetStore(root: root, options: .init(maxPixelSize: 400)).store(png)
        let src = CGImageSourceCreateWithURL(root.appending(path: stored.path) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 400)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 200)
    }

    @Test func anImageAVIFDoesNotShrinkEnoughKeepsItsFormatButLosesMetadata() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = Self.image(width: 300, height: 200, type: .jpeg, quality: 0.5)
        #expect(Self.hasGPS(jpeg))
        // Demand an AVIF of at most 1% of the original: never met, so the JPEG is kept with its metadata removed.
        let stored = try AssetStore(root: root, options: .init(keepIfAtMost: 0.01)).store(jpeg)
        #expect(stored.change == .metadataRemoved)
        #expect(stored.path.hasSuffix(".jpeg") || stored.path.hasSuffix(".jpg"))
        #expect(!Self.hasGPS(try Data(contentsOf: root.appending(path: stored.path))))
    }

    @Test func aSmallImageIsNotReencoded() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Self.image(width: 16, height: 16, type: .png)
        #expect(png.count < AssetStore.Options().minimumBytes)
        let stored = try AssetStore(root: root).store(png)
        #expect(stored.change == .metadataRemoved)
        #expect(stored.path.hasSuffix(".png"))
    }
}
