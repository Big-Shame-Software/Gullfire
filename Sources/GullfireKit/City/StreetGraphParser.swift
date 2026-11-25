import Foundation

/// Reads `streets.json` (the schema `StreetGraph` encodes) straight from the bytes into the final arrays, with no
/// intermediate object tree. `JSONDecoder` builds that tree first, which costs a large transient allocation on a big
/// package (over 100 MB for a 21 MB file, held by the allocator for minutes). Anything this parser does not accept
/// throws `ParseFailure`, and `StreetGraph.load` then falls back to `JSONDecoder`, so no file that loaded before stops loading.
enum StreetGraphParser {
    struct ParseFailure: Error, CustomStringConvertible {
        let offset: Int
        let reason: String
        var description: String { "streets.json, byte \(offset): \(reason)" }
    }

    static func parse(_ bytes: UnsafeRawBufferPointer) throws -> StreetGraph {
        var parser = Parser(bytes: bytes)
        return try parser.document()
    }
}

private struct Parser {
    let bytes: UnsafeRawBufferPointer
    let count: Int
    var i = 0
    /// Reused for every point list, so a stretch's array is copied once at its exact size.
    var numbers: [Double] = []
    /// Reused for strings that contain escapes.
    var utf8: [UInt8] = []

    init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        self.count = bytes.count
    }

    /// The byte at the cursor, or 0 at the end. JSON outside a string never contains 0, so 0 never reads as valid.
    var cur: UInt8 { i < count ? bytes[i] : 0 }

    func fail(_ reason: String) -> StreetGraphParser.ParseFailure {
        StreetGraphParser.ParseFailure(offset: i, reason: reason)
    }

    mutating func skipSpace() {
        while i < count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    mutating func expect(_ c: UInt8) throws {
        guard cur == c else { throw fail("expected \(Character(UnicodeScalar(c)))") }
        i += 1
    }

    mutating func word(_ w: StaticString) throws {
        let n = w.utf8CodeUnitCount
        for k in 0..<n {
            guard i < count, bytes[i] == w.utf8Start[k] else { throw fail("expected a literal") }
            i += 1
        }
    }

    // MARK: Document

    mutating func document() throws -> StreetGraph {
        skipSpace()
        try expect(UInt8(ascii: "{"))
        var format: Int?
        var altitude: Double?
        var spacing: Double?
        var stretches: [StreetStretch]?
        skipSpace()
        if cur == UInt8(ascii: "}") {
            i += 1
        } else {
            while true {
                skipSpace()
                let key = try string()
                skipSpace()
                try expect(UInt8(ascii: ":"))
                skipSpace()
                switch key {
                case "format": format = try integer()
                case "altitude": altitude = try number()
                case "spacing": spacing = try number()
                case "stretches": stretches = try stretchArray()
                default: try skipValue(depth: 0)
                }
                skipSpace()
                if cur == UInt8(ascii: ",") { i += 1; continue }
                if cur == UInt8(ascii: "}") { i += 1; break }
                throw fail("expected , or } in the file")
            }
        }
        skipSpace()
        guard i == count else { throw fail("data after the document") }
        guard let format, let altitude, let spacing, let stretches else {
            throw fail("a key is missing or has the wrong type")
        }
        return StreetGraph(format: format, altitude: altitude, spacing: spacing, stretches: stretches)
    }

    // MARK: Stretches

    mutating func stretchArray() throws -> [StreetStretch] {
        try expect(UInt8(ascii: "["))
        skipSpace()
        if cur == UInt8(ascii: "]") { i += 1; return [] }
        var out: [StreetStretch] = []
        while true {
            skipSpace()
            out.append(try stretch())
            skipSpace()
            if cur == UInt8(ascii: ",") { i += 1; continue }
            if cur == UInt8(ascii: "]") { i += 1; break }
            throw fail("expected , or ] in stretches")
        }
        // Copy to an exact-size array so the outer array keeps no spare capacity.
        return out.withUnsafeBufferPointer { Array($0) }
    }

    mutating func stretch() throws -> StreetStretch {
        try expect(UInt8(ascii: "{"))
        var id: String?
        var streetClass: String?
        var names: [String]?
        var length: Double?
        var points: [Double]?
        var loops: [Bool]?
        skipSpace()
        if cur == UInt8(ascii: "}") {
            i += 1
        } else {
            while true {
                skipSpace()
                let key = try string()
                skipSpace()
                try expect(UInt8(ascii: ":"))
                skipSpace()
                switch key {
                case "id": id = try string()
                case "class": streetClass = try string()
                case "names": names = try stringArray()
                case "length": length = try number()
                case "points": points = try numberArray()
                case "loops": loops = try boolArrayOrNull()
                default: try skipValue(depth: 0)
                }
                skipSpace()
                if cur == UInt8(ascii: ",") { i += 1; continue }
                if cur == UInt8(ascii: "}") { i += 1; break }
                throw fail("expected , or } in a stretch")
            }
        }
        guard let id, let streetClass, let names, let length, let points else {
            throw fail("a stretch key is missing or has the wrong type")
        }
        return StreetStretch(id: id, streetClass: streetClass, names: names, length: length, points: points, loops: loops)
    }

    // MARK: Arrays

    mutating func numberArray() throws -> [Double] {
        try expect(UInt8(ascii: "["))
        skipSpace()
        if cur == UInt8(ascii: "]") { i += 1; return [] }
        numbers.removeAll(keepingCapacity: true)
        while true {
            skipSpace()
            numbers.append(try number())
            skipSpace()
            if cur == UInt8(ascii: ",") { i += 1; continue }
            if cur == UInt8(ascii: "]") { i += 1; break }
            throw fail("expected , or ] in points")
        }
        let n = numbers.count
        return numbers.withUnsafeBufferPointer { src in
            Array(unsafeUninitializedCapacity: n) { dst, initialized in
                if n > 0 { dst.baseAddress!.initialize(from: src.baseAddress!, count: n) }
                initialized = n
            }
        }
    }

    mutating func stringArray() throws -> [String] {
        try expect(UInt8(ascii: "["))
        skipSpace()
        if cur == UInt8(ascii: "]") { i += 1; return [] }
        var out: [String] = []
        while true {
            skipSpace()
            out.append(try string())
            skipSpace()
            if cur == UInt8(ascii: ",") { i += 1; continue }
            if cur == UInt8(ascii: "]") { i += 1; break }
            throw fail("expected , or ] in names")
        }
        return out.withUnsafeBufferPointer { Array($0) }
    }

    mutating func boolArrayOrNull() throws -> [Bool]? {
        if cur == UInt8(ascii: "n") {
            try word("null")
            return nil
        }
        try expect(UInt8(ascii: "["))
        skipSpace()
        if cur == UInt8(ascii: "]") { i += 1; return [] }
        var out: [Bool] = []
        while true {
            skipSpace()
            out.append(try boolean())
            skipSpace()
            if cur == UInt8(ascii: ",") { i += 1; continue }
            if cur == UInt8(ascii: "]") { i += 1; break }
            throw fail("expected , or ] in loops")
        }
        return out.withUnsafeBufferPointer { Array($0) }
    }

    mutating func boolean() throws -> Bool {
        if cur == UInt8(ascii: "t") { try word("true"); return true }
        if cur == UInt8(ascii: "f") { try word("false"); return false }
        throw fail("expected true or false")
    }

    // MARK: Scalars

    /// A JSON number, read as `strtod` reads a correctly-rounded decimal, so the Double is the one `JSONDecoder` gives.
    mutating func number() throws -> Double {
        let start = i
        _ = try numberSpan()
        return try convert(start: start, length: i - start)
    }

    /// A JSON integer (no fraction or exponent) that fits an Int.
    mutating func integer() throws -> Int {
        let (start, integerForm) = try numberSpan()
        guard integerForm else { throw fail("format must be an integer") }
        let v = try convert(start: start, length: i - start)
        guard let n = Int(exactly: v) else { throw fail("format is out of range") }
        return n
    }

    /// Advances over one number token in the JSON grammar and reports whether it has no fraction or exponent.
    mutating func numberSpan() throws -> (start: Int, integerForm: Bool) {
        let start = i
        if cur == UInt8(ascii: "-") { i += 1 }
        guard isDigit(cur) else { throw fail("expected a number") }
        if cur == UInt8(ascii: "0") {
            i += 1
        } else {
            while isDigit(cur) { i += 1 }
        }
        var integerForm = true
        if cur == UInt8(ascii: ".") {
            integerForm = false
            i += 1
            guard isDigit(cur) else { throw fail("expected digits after .") }
            while isDigit(cur) { i += 1 }
        }
        if cur == UInt8(ascii: "e") || cur == UInt8(ascii: "E") {
            integerForm = false
            i += 1
            if cur == UInt8(ascii: "+") || cur == UInt8(ascii: "-") { i += 1 }
            guard isDigit(cur) else { throw fail("expected digits in the exponent") }
            while isDigit(cur) { i += 1 }
        }
        return (start, integerForm)
    }

    func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    /// `strtod` on a null-terminated copy of the token, on the stack. The token must be consumed whole and finite.
    func convert(start: Int, length: Int) throws -> Double {
        guard length > 0, length < 128 else { throw fail("number too long") }
        let source = bytes
        let value: Double? = withUnsafeTemporaryAllocation(of: CChar.self, capacity: length + 1) { buf -> Double? in
            for k in 0..<length { buf[k] = CChar(bitPattern: source[start + k]) }
            buf[length] = 0
            var end: UnsafeMutablePointer<CChar>?
            let v = strtod(buf.baseAddress!, &end)
            guard end == buf.baseAddress! + length, v.isFinite else { return nil }
            return v
        }
        guard let value else { throw fail("number out of range or malformed") }
        return value
    }

    /// A JSON string as a Swift String. Escapes are decoded, including \uXXXX and surrogate pairs; a lone surrogate is a failure.
    mutating func string() throws -> String {
        try expect(UInt8(ascii: "\""))
        let start = i
        while i < count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                let s = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
                i += 1
                return s
            }
            if c == UInt8(ascii: "\\") { break }
            if c < 0x20 { throw fail("control character in a string") }
            i += 1
        }
        utf8.removeAll(keepingCapacity: true)
        utf8.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[start..<i]))
        while true {
            guard i < count else { throw fail("unterminated string") }
            let c = bytes[i]
            i += 1
            if c == UInt8(ascii: "\"") {
                return String(decoding: utf8, as: UTF8.self)
            }
            if c < 0x20 { throw fail("control character in a string") }
            if c != UInt8(ascii: "\\") {
                utf8.append(c)
                continue
            }
            guard i < count else { throw fail("unterminated escape") }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(e)
            case UInt8(ascii: "b"): utf8.append(0x08)
            case UInt8(ascii: "f"): utf8.append(0x0C)
            case UInt8(ascii: "n"): utf8.append(0x0A)
            case UInt8(ascii: "r"): utf8.append(0x0D)
            case UInt8(ascii: "t"): utf8.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4()
                if (0xD800...0xDBFF).contains(scalar) {
                    guard i + 1 < count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                        throw fail("lone high surrogate")
                    }
                    i += 2
                    let low = try hex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw fail("bad low surrogate") }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    throw fail("lone low surrogate")
                }
                guard let u = UnicodeScalar(scalar) else { throw fail("bad scalar") }
                utf8.append(contentsOf: Array(String(Character(u)).utf8))
            default:
                throw fail("bad escape")
            }
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= count else { throw fail("short \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw fail("bad hex digit")
            }
            v = v * 16 + d
            i += 1
        }
        return v
    }

    // MARK: Unknown values

    /// Steps over any JSON value, validating it, without keeping it.
    mutating func skipValue(depth: Int) throws {
        guard depth < 256 else { throw fail("nested too deeply") }
        skipSpace()
        switch cur {
        case UInt8(ascii: "\""):
            _ = try string()
        case UInt8(ascii: "{"):
            i += 1
            skipSpace()
            if cur == UInt8(ascii: "}") { i += 1; return }
            while true {
                skipSpace()
                _ = try string()
                skipSpace()
                try expect(UInt8(ascii: ":"))
                try skipValue(depth: depth + 1)
                skipSpace()
                if cur == UInt8(ascii: ",") { i += 1; continue }
                if cur == UInt8(ascii: "}") { i += 1; return }
                throw fail("expected , or } in an object")
            }
        case UInt8(ascii: "["):
            i += 1
            skipSpace()
            if cur == UInt8(ascii: "]") { i += 1; return }
            while true {
                try skipValue(depth: depth + 1)
                skipSpace()
                if cur == UInt8(ascii: ",") { i += 1; continue }
                if cur == UInt8(ascii: "]") { i += 1; return }
                throw fail("expected , or ] in an array")
            }
        case UInt8(ascii: "t"):
            try word("true")
        case UInt8(ascii: "f"):
            try word("false")
        case UInt8(ascii: "n"):
            try word("null")
        default:
            _ = try number()
        }
    }
}
