import Foundation
import zlib

/// A lossless PNG writer that picks the smallest colour type and bit depth the pixels allow
/// (palette, grayscale, 1/2/4/8-bit), tries several filter and deflate strategies, and keeps
/// only an `sRGB` chunk — no metadata, no gamma or ICC baggage.
enum PNGEncoder {
    struct Layout: Sendable {
        enum Kind: Sendable { case gray, grayAlpha, rgb, rgba, palette }
        var kind: Kind
        var bitDepth: Int
        var palette: [UInt32] = []   // RGBA packed, transparent entries first

        var colourType: UInt8 {
            switch kind { case .gray: 0; case .rgb: 2; case .palette: 3; case .grayAlpha: 4; case .rgba: 6 }
        }
        var channels: Int {
            switch kind { case .gray, .palette: 1; case .grayAlpha: 2; case .rgb: 3; case .rgba: 4 }
        }
        var description: String {
            switch kind {
            case .palette: "\(palette.count)-colour palette"
            case .gray: "\(bitDepth)-bit grayscale"
            case .grayAlpha: "grayscale + alpha"
            case .rgb: "RGB"
            case .rgba: "RGBA"
            }
        }
    }

    enum Filter: Sendable { case none, adaptive, fixed(UInt8) }

    static func layout(for pixels: PixelBuffer, analysis: Analysis) -> Layout {
        if analysis.isGray, analysis.isOpaque {
            var levels = Set<UInt8>()
            for i in stride(from: 0, to: pixels.bytes.count, by: 4) { levels.insert(pixels.bytes[i]); if levels.count > 16 { break } }
            let depth = levels.allSatisfy({ $0 == 0 || $0 == 255 }) ? 1
                : levels.allSatisfy({ $0 % 85 == 0 }) ? 2
                : levels.allSatisfy({ $0 % 17 == 0 }) ? 4 : 8
            return Layout(kind: .gray, bitDepth: depth)
        }
        if let histogram = analysis.histogram, histogram.count <= 256 {
            // Translucent entries first keeps tRNS short; then most frequent first (helps deflate a little).
            let palette = histogram.sorted { a, b in
                let ta = a.key >> 24 != 0xFF, tb = b.key >> 24 != 0xFF
                if ta != tb { return ta }
                return a.value != b.value ? a.value > b.value : a.key < b.key
            }.map(\.key)
            let n = palette.count
            let depth = n <= 2 ? 1 : n <= 4 ? 2 : n <= 16 ? 4 : 8
            return Layout(kind: .palette, bitDepth: depth, palette: palette)
        }
        if analysis.isGray { return Layout(kind: .grayAlpha, bitDepth: 8) }
        return Layout(kind: analysis.isOpaque ? .rgb : .rgba, bitDepth: 8)
    }

    /// Encodes losslessly. `thorough` tries more filter/deflate combinations (slower, a few % smaller).
    static func encode(_ pixels: PixelBuffer, analysis: Analysis, thorough: Bool = true) -> (data: Data, layout: Layout) {
        let layout = layout(for: pixels, analysis: analysis)
        let rows = rawRows(pixels, layout: layout)
        let rowBytes = (pixels.width * layout.channels * layout.bitDepth + 7) / 8
        let bpp = max(1, layout.channels * layout.bitDepth / 8)

        var filters: [Filter] = layout.kind == .palette || layout.bitDepth < 8 ? [.none, .adaptive] : [.adaptive, .none, .fixed(4)]
        var strategies: [Int32] = [Z_DEFAULT_STRATEGY, Z_FILTERED]
        let rawSize = rows.count
        if !thorough || rawSize > 24 << 20 { filters = [layout.bitDepth < 8 ? .none : .adaptive]; strategies = [Z_DEFAULT_STRATEGY] }
        if rawSize > 96 << 20 { strategies = [Z_DEFAULT_STRATEGY] }

        var best: Data?
        for filter in filters {
            let filtered = applyFilter(filter, rows: rows, height: pixels.height, rowBytes: rowBytes, bpp: bpp)
            for strategy in strategies {
                guard let z = deflate(filtered, strategy: strategy) else { continue }
                if best == nil || z.count < best!.count { best = z }
            }
        }
        return (container(width: pixels.width, height: pixels.height, layout: layout, idat: best ?? Data()), layout)
    }

    // MARK: Scanlines

    /// Unfiltered scanlines in the target layout, without the leading filter byte.
    static func rawRows(_ p: PixelBuffer, layout: Layout) -> [UInt8] {
        let w = p.width, h = p.height
        let rowBytes = (w * layout.channels * layout.bitDepth + 7) / 8
        var out = [UInt8](repeating: 0, count: rowBytes * h)
        var index: [UInt32: UInt8] = [:]
        for (i, c) in layout.palette.enumerated() { index[c] = UInt8(i) }
        p.bytes.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt32.self)
            out.withUnsafeMutableBufferPointer { o in
                var lastKey: UInt32 = 0, lastIndex: UInt8 = 0, haveLast = false
                for y in 0..<h {
                    let rowStart = y * rowBytes
                    for x in 0..<w {
                        let v = px[y * w + x]
                        let r = UInt8(v & 0xFF), g = UInt8((v >> 8) & 0xFF), b = UInt8((v >> 16) & 0xFF), a = UInt8(v >> 24)
                        switch layout.kind {
                        case .rgba:
                            let j = rowStart + x * 4; o[j] = r; o[j + 1] = g; o[j + 2] = b; o[j + 3] = a
                        case .rgb:
                            let j = rowStart + x * 3; o[j] = r; o[j + 1] = g; o[j + 2] = b
                        case .grayAlpha:
                            let j = rowStart + x * 2; o[j] = r; o[j + 1] = a
                        case .gray, .palette:
                            let value: UInt8
                            if layout.kind == .gray {
                                value = layout.bitDepth == 8 ? r : r / UInt8(255 / ((1 << layout.bitDepth) - 1))
                            } else {
                                if !(haveLast && v == lastKey) { lastKey = v; lastIndex = index[v] ?? 0; haveLast = true }
                                value = lastIndex
                            }
                            if layout.bitDepth == 8 {
                                o[rowStart + x] = value
                            } else {
                                let perByte = 8 / layout.bitDepth
                                let shift = (perByte - 1 - x % perByte) * layout.bitDepth
                                o[rowStart + x / perByte] |= value << UInt8(shift)
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    static func applyFilter(_ filter: Filter, rows: [UInt8], height: Int, rowBytes: Int, bpp: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (rowBytes + 1) * height)
        var scratch = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowBytes), count: 5)
        let zeroRow = [UInt8](repeating: 0, count: rowBytes)
        rows.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let cur = UnsafeBufferPointer(rebasing: src[(y * rowBytes)..<((y + 1) * rowBytes)])
                let prevBase = y == 0 ? nil : y - 1
                let o = y * (rowBytes + 1)
                func emit(_ type: UInt8, _ bytes: [UInt8]) {
                    out[o] = type
                    out.withUnsafeMutableBufferPointer { d in
                        bytes.withUnsafeBufferPointer { b in
                            (d.baseAddress! + o + 1).update(from: b.baseAddress!, count: rowBytes)
                        }
                    }
                }
                zeroRow.withUnsafeBufferPointer { zero in
                    let prev = prevBase.map { UnsafeBufferPointer(rebasing: src[($0 * rowBytes)..<(($0 + 1) * rowBytes)]) } ?? zero
                    switch filter {
                    case .none:
                        emit(0, Array(cur))
                    case .fixed(let t):
                        filterRow(t, cur, prev, bpp, &scratch[0]); emit(t, scratch[0])
                    case .adaptive:
                        var bestType: UInt8 = 0, bestSum = Int.max
                        for t: UInt8 in 0...4 {
                            filterRow(t, cur, prev, bpp, &scratch[Int(t)])
                            var sum = 0
                            for v in scratch[Int(t)] { sum += v < 128 ? Int(v) : 256 - Int(v) }
                            if sum < bestSum { bestSum = sum; bestType = t }
                        }
                        emit(bestType, scratch[Int(bestType)])
                    }
                }
            }
        }
        return out
    }

    @inline(__always)
    static func filterRow(_ type: UInt8, _ cur: UnsafeBufferPointer<UInt8>, _ prev: UnsafeBufferPointer<UInt8>, _ bpp: Int, _ out: inout [UInt8]) {
        let n = cur.count
        out.withUnsafeMutableBufferPointer { o in
            switch type {
            case 0: for i in 0..<n { o[i] = cur[i] }
            case 1: for i in 0..<n { o[i] = cur[i] &- (i >= bpp ? cur[i - bpp] : 0) }
            case 2: for i in 0..<n { o[i] = cur[i] &- prev[i] }
            case 3:
                for i in 0..<n {
                    let left = i >= bpp ? Int(cur[i - bpp]) : 0
                    o[i] = cur[i] &- UInt8((left + Int(prev[i])) >> 1)
                }
            default:
                for i in 0..<n {
                    let a = i >= bpp ? Int(cur[i - bpp]) : 0, b = Int(prev[i]), c = i >= bpp ? Int(prev[i - bpp]) : 0
                    let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    let pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
                    o[i] = cur[i] &- UInt8(pred)
                }
            }
        }
    }

    // MARK: Deflate and container

    static func deflate(_ input: [UInt8], strategy: Int32) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, 9, Z_DEFLATED, MAX_WBITS, 9, strategy, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        let bound = Int(deflateBound(&stream, uLong(input.count)))
        var out = [UInt8](repeating: 0, count: bound)
        let status: Int32 = input.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                stream.next_in = UnsafeMutablePointer(mutating: i.baseAddress)
                stream.avail_in = uInt(i.count)
                stream.next_out = o.baseAddress
                stream.avail_out = uInt(o.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        return Data(out[0..<Int(stream.total_out)])
    }

    static func container(width: Int, height: Int, layout: Layout, idat: Data) -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.appendBE(UInt32(width)); ihdr.appendBE(UInt32(height))
        ihdr.append(contentsOf: [UInt8(layout.bitDepth), layout.colourType, 0, 0, 0])
        png.appendChunk("IHDR", ihdr)
        png.appendChunk("sRGB", Data([0]))   // perceptual; tells every viewer the pixels are sRGB in 13 bytes
        if layout.kind == .palette {
            var plte = Data(), trns = Data()
            for c in layout.palette {
                plte.append(contentsOf: [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF)])
                if c >> 24 != 0xFF { trns.append(UInt8(c >> 24)) }
            }
            png.appendChunk("PLTE", plte)
            if !trns.isEmpty { png.appendChunk("tRNS", trns) }
        }
        png.appendChunk("IDAT", idat)
        png.appendChunk("IEND", Data())
        return png
    }
}

extension PNGEncoder.Filter: Equatable {}

private extension Data {
    mutating func appendBE(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }

    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBE(UInt32(body.count))
        var chunk = Data(type.utf8)
        chunk.append(body)
        append(chunk)
        let crc = chunk.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        appendBE(UInt32(crc))
    }
}
