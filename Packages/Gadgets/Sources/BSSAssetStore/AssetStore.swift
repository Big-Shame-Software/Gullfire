import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A folder of assets (images, stylesheets, fonts) where each one is stored once, under the SHA-256 of what is stored:
/// `ab/ab12….avif`. Storing the same thing twice writes nothing the second time.
///
/// Still images are shrunk to AVIF when that saves enough (25% by default); an image that is not shrunk still loses its
/// EXIF, GPS, XMP and IPTC metadata. Animated images, SVG, CSS and fonts are kept exactly as given. If this Mac cannot
/// write AVIF, images are kept in their own format with the metadata removed.
public struct AssetStore: Sendable {
    public struct Options: Sendable, Equatable {
        /// The long side of an AVIF image, at most. Smaller images are not enlarged.
        public var maxPixelSize: Int
        /// AVIF quality, 0 to 1.
        public var quality: Double
        /// The AVIF is kept only when it is at most this fraction of the original's size.
        public var keepIfAtMost: Double
        /// Images smaller than this many bytes are not re-encoded.
        public var minimumBytes: Int

        public init(maxPixelSize: Int = 1600, quality: Double = 0.8, keepIfAtMost: Double = 0.75, minimumBytes: Int = 4_096) {
            self.maxPixelSize = maxPixelSize
            self.quality = quality
            self.keepIfAtMost = keepIfAtMost
            self.minimumBytes = minimumBytes
        }
    }

    /// What was done with the bytes before they were stored.
    public enum Change: String, Sendable, Equatable {
        case avif, metadataRemoved, keptAsGiven, keptAnimated
    }

    public struct Stored: Sendable, Equatable {
        /// Relative to the store's root, for example `ab/ab12….avif`.
        public var path: String
        /// The SHA-256 of the stored bytes, lowercase hex.
        public var sha256: String
        public var bytes: Int
        public var originalBytes: Int
        /// False when the same bytes were already in the store.
        public var isNew: Bool
        public var change: Change
    }

    public let root: URL
    public let options: Options

    public init(root: URL, options: Options = Options()) {
        self.root = root
        self.options = options
    }

    /// Stores the bytes. `contentType` (a MIME type) and `fileExtension` are hints for things that are not images;
    /// images are recognised from their bytes.
    public func store(_ data: Data, contentType: String? = nil, fileExtension: String? = nil) throws -> Stored {
        let (body, ext, change) = Self.prepare(data, contentType: contentType, fileExtension: fileExtension ?? "", options: options)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let dir = root.appending(path: String(hash.prefix(2)), directoryHint: .isDirectory)
        let file = dir.appending(path: "\(hash).\(ext)")
        let isNew = !FileManager.default.fileExists(atPath: file.path)
        if isNew {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: file, options: .atomic)
        }
        return Stored(path: "\(hash.prefix(2))/\(hash).\(ext)", sha256: hash, bytes: body.count, originalBytes: data.count,
                      isNew: isNew, change: change)
    }

    /// The URL of a stored asset.
    public func url(for stored: Stored) -> URL { root.appending(path: stored.path) }

    static func prepare(_ data: Data, contentType: String?, fileExtension: String, options: Options) -> (Data, String, Change) {
        let type = (contentType ?? "").lowercased()
        let pathExt = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if type.contains("css") || pathExt == "css" { return (data, "css", .keptAsGiven) }
        if type.contains("svg") || pathExt == "svg" { return (data, "svg", .keptAsGiven) }
        if type.contains("font") || ["woff", "woff2", "ttf", "otf"].contains(pathExt) {
            return (data, pathExt.isEmpty ? "font" : pathExt, .keptAsGiven)
        }

        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let uti = CGImageSourceGetType(src) as String?,
              let utType = UTType(uti), utType.conforms(to: .image) else {
            return (data, pathExt.isEmpty ? "bin" : pathExt, .keptAsGiven)
        }
        let ext = utType.preferredFilenameExtension ?? "img"
        if CGImageSourceGetCount(src) > 1 { return (data, ext, .keptAnimated) }
        if data.count >= options.minimumBytes, let avif = encodeAVIF(src, options: options),
           Double(avif.count) <= Double(data.count) * options.keepIfAtMost {
            return (avif, "avif", .avif)
        }
        if let clean = stripMetadata(src, type: uti) { return (clean, ext, .metadataRemoved) }
        return (data, ext, .keptAsGiven)
    }

    /// Downscales so the long side is at most `maxPixelSize`, applies the orientation, then writes AVIF. Metadata is not
    /// carried over. Nil when this Mac cannot write AVIF.
    static func encodeAVIF(_ src: CGImageSource, options: Options) -> Data? {
        let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: options.maxPixelSize,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.avif" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: options.quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Copies the image without EXIF, GPS, XMP or IPTC, without re-encoding the pixels where the format allows.
    static func stripMetadata(_ src: CGImageSource, type: String) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                                        kCGImageDestinationMergeMetadata: false,
                                        kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else { return nil }
        return out as Data
    }
}
