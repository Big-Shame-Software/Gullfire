import Foundation

public enum GeoJSONError: Error, Equatable {
    case badLine(offset: Int)
}

/// Reads a GeoJSON Text Sequence (one feature per line) without holding the file in memory.
public enum GeoJSONLines {
    /// Calls `body` once per feature. The file is read in 1 MB chunks, so only the lines
    /// in progress are held at any time.
    public static func forEachFeature(at url: URL, _ body: ([String: Any]) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var carry = Data()
        var consumed = 0
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            carry.append(chunk)
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: 0x0A) {
                try emit(carry[start..<newline], offset: consumed, body)
                consumed += newline - start + 1
                start = newline + 1
            }
            carry.removeSubrange(carry.startIndex..<start)
        }
        if !carry.isEmpty { try emit(carry[...], offset: consumed, body) }
    }

    private static func emit(_ line: Data.SubSequence, offset: Int, _ body: ([String: Any]) throws -> Void) throws {
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return }
        guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            throw GeoJSONError.badLine(offset: offset)
        }
        try body(object)
    }
}
