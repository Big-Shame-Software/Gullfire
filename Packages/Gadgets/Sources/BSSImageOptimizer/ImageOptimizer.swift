import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageOptimizerError: Error, LocalizedError, Sendable {
    case unreadable
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This file isn't an image macOS can read."
        case .encodingFailed: "The optimised image couldn't be written."
        }
    }
}

/// Turns any image macOS can read into the smallest universally readable JPEG or PNG
/// that still looks like the original.
///
/// Every lossy candidate is decoded again and compared with the original pixels (see ``QualityScore``);
/// it is only kept if it passes the chosen ``Quality``. Pixels are made upright, converted to sRGB and
/// stripped of metadata, so Plex, browsers, TVs and old software all show the same thing.
///
/// Measured peak memory: ~450 MB for a 12-megapixel HEIC, ~1.2 GB for a 36-megapixel scan,
/// up to ~1.6 GB for a RAW file (Apple's RAW decoder is the heavy part).
/// Run at most two at a time; ``optimizeFiles(_:into:maxConcurrent:onFinish:)`` does that for you.
public struct ImageOptimizer: Sendable {
    public enum Format: String, Sendable {
        case jpeg, png
        public var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    }

    public enum FormatPolicy: String, Sendable, CaseIterable {
        /// JPEG for photographs, PNG for transparency and flat graphics, whichever is smallest when it's close.
        case automatic
        /// Always JPEG; transparency is flattened onto ``Options/background``.
        case jpeg
        /// Always PNG (lossless, or a palette if it passes the quality check).
        case png
    }

    public enum Quality: String, Sendable, CaseIterable {
        /// Differences are hard to find even when flipping between the two at 100 %.
        case maximum
        /// The default: no visible difference at normal viewing size.
        case high
        /// Smaller files; differences may show at 100 % in difficult areas.
        case balanced

        struct Thresholds {
            var luma, half, tile, chroma: Double
            var minQ, maxQ: Int
            /// Vision limits, relative to the same image saved as a q98 JPEG (its "invisible change" baseline):
            /// distance ≤ baseline × factor + margin, aesthetics drop ≤ baseline drop + dropMargin.
            var visionFactor, visionMargin, visionDropMargin: Float
        }

        var thresholds: Thresholds {
            switch self {
            case .maximum: Thresholds(luma: 0.990, half: 0.996, tile: 0.960, chroma: 0.985, minQ: 80, maxQ: 98, visionFactor: 1.2, visionMargin: 0.002, visionDropMargin: 0.010)
            case .high: Thresholds(luma: 0.980, half: 0.990, tile: 0.930, chroma: 0.970, minQ: 70, maxQ: 95, visionFactor: 1.5, visionMargin: 0.005, visionDropMargin: 0.020)
            case .balanced: Thresholds(luma: 0.965, half: 0.980, tile: 0.890, chroma: 0.950, minQ: 55, maxQ: 92, visionFactor: 2.0, visionMargin: 0.010, visionDropMargin: 0.040)
            }
        }

        /// The limits for one image, from Vision's reading of that image as a q98 JPEG.
        func visionLimits(baseline: VisionMatch) -> (distance: Float, drop: Float) {
            let t = thresholds
            return (baseline.distance * t.visionFactor + t.visionMargin, max(0, baseline.aestheticsDrop) + t.visionDropMargin)
        }

        func accepts(_ s: QualityScore) -> Bool {
            let t = thresholds
            return s.luma >= t.luma && s.lumaHalfSize >= t.half && s.worstTile >= t.tile && s.chroma >= t.chroma
        }
    }

    public struct Options: Sendable {
        public var format: FormatPolicy = .automatic
        public var quality: Quality = .high
        /// Longest side in pixels; larger images are downscaled (Lanczos). `nil` keeps the full size.
        public var maxPixelSize: Int? = nil
        /// When the input is already a JPEG or PNG that needs no rotation or resizing and is smaller than
        /// anything we can make, keep its bytes untouched.
        public var keepOriginalIfSmaller: Bool = true
        /// Colour behind transparent areas when writing JPEG.
        public var background: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)
        /// Second opinion from Apple Vision. A lossy result whose feature print or aesthetics score moves too
        /// far from the original is rejected, and the optimiser climbs the ladder: higher JPEG quality
        /// (up to q98), a larger palette, then lossless PNG.
        public var visionCheck: Bool = true

        public init(format: FormatPolicy = .automatic, quality: Quality = .high, maxPixelSize: Int? = nil,
                    keepOriginalIfSmaller: Bool = true) {
            self.format = format
            self.quality = quality
            self.maxPixelSize = maxPixelSize
            self.keepOriginalIfSmaller = keepOriginalIfSmaller
        }
    }

    public struct Result: Sendable {
        public var data: Data
        public var format: Format
        public var width: Int
        public var height: Int
        public var inputBytes: Int
        /// Size of the encoded output (stays valid after `data` is dropped by the batch API).
        public var outputBytes: Int
        /// Plain-English summary, e.g. "JPEG q84" or "PNG 64-colour palette (lossy)".
        public var method: String
        /// `nil` when the output is pixel-identical to the decoded original.
        public var score: QualityScore?
        public var keptOriginal: Bool
        /// Vision's comparison with the original; `nil` for lossless output or when the check is off.
        public var vision: VisionMatch? = nil
        /// Lossy candidates Vision turned down before this one was accepted.
        public var visionRejections: Int = 0
        var jpegQuality: Int? = nil

        public var savedFraction: Double { inputBytes > 0 ? 1 - Double(outputBytes) / Double(inputBytes) : 0 }
    }

    public var options: Options

    public init(options: Options = Options()) { self.options = options }

    // MARK: Entry points

    public func optimize(data: Data) throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImageOptimizerError.unreadable }
        return try optimize(source: source, inputBytes: data.count, original: { data })
    }

    public func optimize(fileAt url: URL) throws -> Result {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImageOptimizerError.unreadable }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return try optimize(source: source, inputBytes: size, original: { try? Data(contentsOf: url) })
    }

    /// Optimises an image already in memory (e.g. a freshly generated result). It is treated as upright;
    /// `maxPixelSize` still applies. `inputBytes` in the result is 0 (there is no source file).
    public func optimize(image: CGImage) throws -> Result {
        var pixels = try PixelBuffer(image: image)
        if let limit = options.maxPixelSize, max(pixels.width, pixels.height) > limit {
            pixels = try pixels.downscaled(toFit: limit)
        }
        pixels.clearInvisibleColour()
        return try bestCandidate(for: pixels)
    }

    /// Optimises `url` and writes `<name>.jpg` or `<name>.png` into `directory` atomically.
    /// Refuses to overwrite the input file itself.
    @discardableResult
    public func optimizeFile(at url: URL, into directory: URL) throws -> (result: Result, output: URL) {
        let result = try autoreleasepool { try optimize(fileAt: url) }
        let name = url.deletingPathExtension().lastPathComponent
        var output = directory.appendingPathComponent(name).appendingPathExtension(result.format.fileExtension)
        if output.standardizedFileURL == url.standardizedFileURL {
            output = directory.appendingPathComponent(name + "-optimized").appendingPathExtension(result.format.fileExtension)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try result.data.write(to: output, options: .atomic)
        return (result, output)
    }

    public struct FileOutcome: Sendable {
        public var input: URL
        public var output: URL?
        public var result: Result?
        public var error: String?
    }

    /// Optimises many files with bounded concurrency (2 by default: each job can hold a few hundred MB).
    /// Cancel the calling task to stop after the files already under way.
    /// Each result is written as soon as it finishes; only small summaries are passed to `onFinish`.
    public func optimizeFiles(_ urls: [URL], into directory: URL, maxConcurrent: Int = 2,
                              onFinish: @escaping @Sendable (FileOutcome) -> Void) async {
        let optimizer = self
        await withTaskGroup(of: Void.self) { group in
            var pending = urls.makeIterator()
            func add() -> Bool {
                // Cancelling the calling task stops new files from starting; ones under way finish and are written.
                guard !Task.isCancelled, let url = pending.next() else { return false }
                group.addTask {
                    do {
                        var (result, output) = try optimizer.optimizeFile(at: url, into: directory)
                        result.data = Data()          // already on disk; don't carry the bytes around
                        onFinish(FileOutcome(input: url, output: output, result: result))
                    } catch {
                        onFinish(FileOutcome(input: url, error: error.localizedDescription))
                    }
                }
                return true
            }
            for _ in 0..<max(1, maxConcurrent) where add() {}
            while await group.next() != nil { _ = add() }
        }
    }

    // MARK: Pipeline

    private func optimize(source: CGImageSource, inputBytes: Int, original: () -> Data?) throws -> Result {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let inputType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }

        // Decode in its own scope so the decoder's copy is released before the encoders run.
        var pixels = try autoreleasepool { () throws -> PixelBuffer in
            guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { throw ImageOptimizerError.unreadable }
            return try PixelBuffer(image: image)
        }
        if orientation != 1 { pixels = try pixels.oriented(orientation) }
        let resized: Bool
        if let limit = options.maxPixelSize, max(pixels.width, pixels.height) > limit {
            pixels = try pixels.downscaled(toFit: limit)
            resized = true
        } else {
            resized = false
        }
        pixels.clearInvisibleColour()

        var best = try bestCandidate(for: pixels)
        best.inputBytes = inputBytes

        if options.keepOriginalIfSmaller, !resized, orientation == 1, inputBytes > 0, inputBytes <= best.outputBytes,
           let type = inputType, let keep = keepableFormat(type), options.format == .automatic || options.format.rawValue == keep.rawValue,
           let data = original() {
            return Result(data: data, format: keep, width: pixels.width, height: pixels.height, inputBytes: inputBytes,
                          outputBytes: data.count, method: "original kept (already smallest)", score: nil, keptOriginal: true)
        }
        return best
    }

    private func keepableFormat(_ type: UTType) -> Format? {
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .png) { return .png }
        return nil
    }

    private func bestCandidate(for pixels: PixelBuffer) throws -> Result {
        let analysis = Analysis(pixels)
        let few = analysis.colourCount.map { $0 <= 256 } ?? false
        let graphic = analysis.colourCount != nil      // ≤ 32 768 colours: flat art, UI, screenshots
        var candidates: [Result] = []

        func make(_ data: Data, _ format: Format, _ method: String, _ score: QualityScore?) -> Result {
            Result(data: data, format: format, width: pixels.width, height: pixels.height, inputBytes: 0,
                   outputBytes: data.count, method: method, score: score, keptOriginal: false)
        }

        switch options.format {
        case .jpeg:
            let flat = analysis.isOpaque ? pixels : pixels.flattened(onto: options.background)
            candidates.append(try searchJPEG(flat, make))
        case .png:
            candidates += pngCandidates(pixels, analysis, make)
        case .automatic:
            if !analysis.isOpaque || graphic {
                candidates += pngCandidates(pixels, analysis, make)
            }
            if analysis.isOpaque, !few {
                candidates.append(try searchJPEG(pixels, make))
            }
            if candidates.isEmpty {   // transparency on a photo: PNG is the only universal option
                candidates += pngCandidates(pixels, analysis, make)
            }
        }
        return try climb(candidates, pixels: pixels, analysis: analysis)
    }

    /// Accepts the smallest candidate Vision agrees with. A rejected JPEG puts its next quality step
    /// on the ladder; lossless PNG is the last rung (except for forced JPEG, which tops out at q98).
    private func climb(_ candidates: [Result], pixels: PixelBuffer, analysis: Analysis) throws -> Result {
        let jpegSource = analysis.isOpaque ? pixels : pixels.flattened(onto: options.background)
        var queue = candidates.sorted { $0.outputBytes < $1.outputBytes }
        guard options.visionCheck else { return queue[0] }

        // Vision sees everything flattened onto the JPEG background, so PNG and JPEG candidates share one
        // reference and one baseline. Vision's distance jumps to an image-specific plateau for *any* lossy
        // change, so the limit is relative: no further from the original than the same image as a q98 JPEG,
        // plus the preset's margin. Real damage shows as a knee well above that plateau.
        var reference: VisionReference?
        var limits: (distance: Float, drop: Float) = (0, 0)
        func check(_ candidate: Result) throws -> (VisionMatch, Bool) {
            try autoreleasepool {
                if reference == nil {
                    let r = try VisionReference(jpegSource, opaque: true)
                    let baseline = try r.compare(try PixelBuffer(encoded: try JPEGEncoder.encode(jpegSource, quality: 98)))
                    limits = options.quality.visionLimits(baseline: baseline)
                    reference = r
                }
                var decoded = try PixelBuffer(encoded: candidate.data)
                if !analysis.isOpaque { decoded = decoded.flattened(onto: options.background) }
                var match = try reference!.compare(decoded)
                match.allowedDistance = limits.distance
                match.allowedDrop = limits.drop
                return (match, match.distance <= limits.distance && match.aestheticsDrop <= limits.drop)
            }
        }

        var rejected: [Result] = []
        var haveLossless = queue.contains { $0.score == nil }
        let ceiling = 98, step = 4
        while !queue.isEmpty {
            var candidate = queue.removeFirst()
            candidate.visionRejections = rejected.count
            if candidate.score == nil { return candidate }          // lossless: identical pixels

            let (match, accepted) = try check(candidate)
            candidate.vision = match
            if accepted {
                if let first = rejected.first(where: { $0.format == candidate.format }), let q = first.jpegQuality,
                   candidate.format == .jpeg {
                    candidate.method += " (Vision raised it from q\(q))"
                } else if !rejected.isEmpty {
                    candidate.method += " (Vision turned down \(rejected.count) smaller option\(rejected.count == 1 ? "" : "s"))"
                }
                return candidate
            }
            rejected.append(candidate)

            if candidate.format == .jpeg, let q = candidate.jpegQuality, q < ceiling {
                queue.append(try jpegCandidate(jpegSource, quality: min(ceiling, q + step), pixels: pixels))
            }
            if !haveLossless, options.format != .jpeg, !queue.contains(where: { $0.format == .jpeg }) {
                let lossless = PNGEncoder.encode(pixels, analysis: analysis)
                queue.append(Result(data: lossless.data, format: .png, width: pixels.width, height: pixels.height,
                                    inputBytes: 0, outputBytes: lossless.data.count,
                                    method: "PNG \(lossless.layout.description), lossless", score: nil, keptOriginal: false))
                haveLossless = true
            }
            queue.sort { $0.outputBytes < $1.outputBytes }
        }
        // Forced JPEG and even q98 isn't close enough for Vision: return the closest we have.
        var closest = rejected.min { ($0.vision?.distance ?? 1) < ($1.vision?.distance ?? 1) }!
        closest.visionRejections = rejected.count
        closest.method += " (best JPEG available; Vision limit not met)"
        return closest
    }

    private func jpegCandidate(_ source: PixelBuffer, quality q: Int, pixels: PixelBuffer) throws -> Result {
        try autoreleasepool {
            let data = try JPEGEncoder.encode(source, quality: q)
            let score = Metric.compare(source, try PixelBuffer(encoded: data), hasAlpha: false)
            var r = Result(data: data, format: .jpeg, width: pixels.width, height: pixels.height, inputBytes: 0,
                           outputBytes: data.count, method: "JPEG q\(q), progressive", score: score, keptOriginal: false)
            r.jpegQuality = q
            return r
        }
    }

    private func pngCandidates(_ pixels: PixelBuffer, _ analysis: Analysis,
                               _ make: (Data, Format, String, QualityScore?) -> Result) -> [Result] {
        let lossless = PNGEncoder.encode(pixels, analysis: analysis)
        var out = [make(lossless.data, .png, "PNG \(lossless.layout.description), lossless", nil)]
        guard let histogram = analysis.histogram, histogram.count > 16 else { return out }

        // Try ever smaller palettes while they still pass, keep the smallest file.
        for colours in [256, 128, 64, 32] where colours < histogram.count {
            let reduced = Quantizer.quantize(pixels, histogram: histogram, colours: colours)
            let score = Metric.compare(pixels, reduced, hasAlpha: !analysis.isOpaque)
            guard options.quality.accepts(score) else { break }
            let encoded = PNGEncoder.encode(reduced, analysis: Analysis(reduced))
            out.append(make(encoded.data, .png, "PNG \(encoded.layout.description) (lossy)", score))
        }
        return out
    }

    /// Lowest JPEG quality that passes, by binary search over Image I/O's quality scale.
    private func searchJPEG(_ pixels: PixelBuffer, _ make: (Data, Format, String, QualityScore?) -> Result) throws -> Result {
        let t = options.quality.thresholds
        var lo = t.minQ, hi = t.maxQ
        var best: (Data, Int, QualityScore)?
        while lo <= hi {
            let q = (lo + hi) / 2
            let (data, score) = try autoreleasepool { () throws -> (Data, QualityScore) in
                let data = try JPEGEncoder.encode(pixels, quality: q)
                return (data, Metric.compare(pixels, try PixelBuffer(encoded: data), hasAlpha: false))
            }
            if options.quality.accepts(score) { best = (data, q, score); hi = q - 1 } else { lo = q + 1 }
        }
        if best == nil {
            // Nothing in range passed (very fine grain or noise): use the ceiling.
            let data = try JPEGEncoder.encode(pixels, quality: t.maxQ)
            best = (data, t.maxQ, Metric.compare(pixels, try PixelBuffer(encoded: data), hasAlpha: false))
        }
        let (data, q, score) = best!
        var result = make(data, .jpeg, "JPEG q\(q), progressive", score)
        result.jpegQuality = q
        return result
    }
}
