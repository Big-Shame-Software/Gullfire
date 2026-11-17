import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

public enum ImageError: Error, Equatable {
    case cannotRead(String)
    case cannotWrite(String)
}

/// Textures for one offscreen frame: 4x MSAA colour and depth (both memoryless, so they live in
/// tile memory), resolving into a shared BGRA texture that can be read back.
public struct OffscreenTarget {
    public static let sampleCount = 4

    public let width: Int
    public let height: Int
    public let msaa: MTLTexture
    public let depth: MTLTexture
    public let resolve: MTLTexture?

    public init(device: MTLDevice, width: Int, height: Int, makeResolve: Bool = true) throws {
        self.width = width
        self.height = height

        func make(_ format: MTLPixelFormat, samples: Int, storage: MTLStorageMode) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = storage
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
            }
            guard let texture = device.makeTexture(descriptor: d) else {
                throw RenderError.gpu("could not create a \(width)x\(height) texture")
            }
            return texture
        }
        msaa = try make(.bgra8Unorm, samples: Self.sampleCount, storage: .memoryless)
        depth = try make(.depth32Float, samples: Self.sampleCount, storage: .memoryless)
        resolve = makeResolve ? try make(.bgra8Unorm, samples: 1, storage: .shared) : nil
    }

    /// The textures for residency sets. Only the shared resolve texture: the MSAA colour and depth
    /// are memoryless, and Metal rejects memoryless resources in a residency set
    ///.
    public var allocations: [MTLAllocation] {
        if let resolve { return [resolve] }
        return []
    }

    /// Resolved pixels, 4 bytes per pixel in B, G, R, A order, top row first.
    public func readBGRA() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let resolve else { return pixels }
        resolve.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }
}

/// PNG reading, writing and comparison sheets.
public enum Image {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Writes 8-bit sRGB PNG from BGRA pixels.
    public static func writePNG(bgra: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ImageError.cannotWrite(url.lastPathComponent)
        }
        try write(image, to: url)
    }

    /// Reads a PNG as BGRA pixels, top row first.
    public static func readBGRA(from url: URL) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let image = try load(url)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: bitmapInfo) else {
            throw ImageError.cannotRead(url.lastPathComponent)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    /// Two images at the same height, side by side, with a gap of `gap` pixels.
    public static func sideBySide(left: URL, right: URL, to url: URL, height: Int = 720, gap: Int = 24) throws {
        let a = try load(left), b = try load(right)
        let wa = a.width * height / a.height, wb = b.width * height / b.height
        let total = wa + gap + wb
        guard let context = CGContext(data: nil, width: total, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo) else {
            throw ImageError.cannotWrite(url.lastPathComponent)
        }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: total, height: height))
        context.draw(a, in: CGRect(x: 0, y: 0, width: wa, height: height))
        context.draw(b, in: CGRect(x: wa + gap, y: 0, width: wb, height: height))
        guard let image = context.makeImage() else { throw ImageError.cannotWrite(url.lastPathComponent) }
        try write(image, to: url)
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageError.cannotRead(url.lastPathComponent)
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageError.cannotWrite(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.cannotWrite(url.lastPathComponent) }
    }
}
