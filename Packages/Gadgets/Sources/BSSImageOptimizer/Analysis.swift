/// What the encoders need to know about an image's pixels.
struct Analysis: Sendable {
    var isOpaque: Bool
    var isGray: Bool
    /// Every distinct RGBA colour and how often it occurs, or `nil` when there are more than `cap`.
    var histogram: [UInt32: Int]?

    var colourCount: Int? { histogram?.count }

    /// Colours are packed as R | G<<8 | B<<16 | A<<24 (the in-memory byte order of RGBA8).
    init(_ pixels: PixelBuffer, cap: Int = 32_768) {
        var opaque = true, gray = true
        var histogram: [UInt32: Int]? = [:]
        histogram?.reserveCapacity(min(cap + 1, 4096))
        pixels.bytes.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt32.self)
            var run: UInt32 = 0, runLength = 0
            for value in px {
                let r = value & 0xFF, g = (value >> 8) & 0xFF, b = (value >> 16) & 0xFF, a = value >> 24
                if a != 0xFF { opaque = false }
                if r != g || g != b { gray = false }
                guard histogram != nil else { continue }
                if value == run, runLength > 0 { runLength += 1; continue }
                if runLength > 0 { histogram![run, default: 0] += runLength }
                run = value; runLength = 1
                if histogram!.count > cap { histogram = nil }
            }
            if runLength > 0, histogram != nil { histogram![run, default: 0] += runLength }
            if let h = histogram, h.count > cap { histogram = nil }
        }
        self.isOpaque = opaque
        self.isGray = gray
        self.histogram = histogram
    }
}
