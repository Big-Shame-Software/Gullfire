import Foundation

/// A forgiving one-pass reader for saved HTML. It does not build a document tree and does not need valid markup:
/// it notes elements, attributes, comments, links, feeds and text. Use `HTMLTree` when you need the structure.
/// SingleFile pages can be tens of megabytes of inlined images, so long attribute values are skipped, not copied.
public enum HTMLScanner {
    public static let textLimit = 300_000
    static let valueLimit = 200
    static let linkLimit = 600
    static let commentLimit = 2_000
    static let attributeCap = 200_000

    public static func scan(fileAt url: URL) throws -> PageFacts {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return scan(data)
    }

    public static func scan(_ html: String) -> PageFacts { scan(Data(html.utf8)) }

    public static func scan(_ data: Data) -> PageFacts {
        data.withUnsafeBytes { raw in
            var reader = Reader(bytes: raw.bindMemory(to: UInt8.self))
            reader.run()
            reader.facts.byteCount = data.count
            return reader.facts
        }
    }
}

private struct Reader {
    let b: UnsafeBufferPointer<UInt8>
    var i = 0
    var facts = PageFacts()
    var text: [UInt8] = []
    var lastWasSpace = true

    init(bytes: UnsafeBufferPointer<UInt8>) {
        b = bytes
        text.reserveCapacity(min(bytes.count / 4, HTMLScanner.textLimit))
    }

    mutating func run() {
        let n = b.count
        while i < n {
            let c = b[i]
            if c == UInt8(ascii: "<"), i + 1 < n {
                let next = b[i + 1]
                if next == UInt8(ascii: "!") {
                    if starts(with: "<!--", at: i) { comment() } else { skip(past: UInt8(ascii: ">")) }
                } else if next == UInt8(ascii: "?") {
                    skip(past: UInt8(ascii: ">"))
                } else if next == UInt8(ascii: "/") {
                    skip(past: UInt8(ascii: ">"))
                    addSpace()
                } else if isLetter(next) {
                    element()
                } else {
                    addText(c); i += 1
                }
            } else {
                if c == UInt8(ascii: "&") { entity() } else { addText(c); i += 1 }
            }
        }
        facts.text = String(decoding: text, as: UTF8.self)
    }

    // MARK: Comments

    mutating func comment() {
        let start = i + 4
        let end = find("-->", from: start) ?? b.count
        let body = string(start, min(end, start + HTMLScanner.commentLimit))
        if facts.comments.isEmpty, body.contains("Page saved with SingleFile") { readSingleFileHeader(body) }
        facts.comments.append(body)
        i = min(end + 3, b.count)
    }

    mutating func readSingleFileHeader(_ body: String) {
        facts.savedWithSingleFile = true
        for line in body.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("url:") { facts.savedURL = decodeEntities(t.dropFirst(4).trimmingCharacters(in: .whitespaces)) }
            if t.hasPrefix("saved date:") { facts.savedDate = t.dropFirst(11).trimmingCharacters(in: .whitespaces) }
        }
    }

    // MARK: Elements

    mutating func element() {
        i += 1
        let nameStart = i
        while i < b.count, isNameByte(b[i]) { i += 1 }
        let name = lowerString(nameStart, i)
        facts.tags[name, default: 0] += 1

        var attrs: [(String, String)] = []
        var selfClosing = false
        while i < b.count {
            while i < b.count, isSpace(b[i]) { i += 1 }
            guard i < b.count else { break }
            let c = b[i]
            if c == UInt8(ascii: ">") { i += 1; break }
            if c == UInt8(ascii: "/") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: ">") { selfClosing = true; i += 1; break }
                continue
            }
            let aStart = i
            while i < b.count, !isSpace(b[i]), b[i] != UInt8(ascii: "="), b[i] != UInt8(ascii: ">"), b[i] != UInt8(ascii: "/") || i == aStart { i += 1 }
            let aName = lowerString(aStart, i)
            while i < b.count, isSpace(b[i]) { i += 1 }
            var value = ""
            if i < b.count, b[i] == UInt8(ascii: "=") {
                i += 1
                while i < b.count, isSpace(b[i]) { i += 1 }
                value = readValue()
            }
            if !aName.isEmpty { attrs.append((aName, value)) }
        }
        record(name, attrs)

        guard !selfClosing else { return }
        switch name {
        case "script", "style":
            i = find(closing: name, from: i) ?? b.count
        case "title" where facts.title.isEmpty:
            let end = find(closing: "title", from: i) ?? b.count
            facts.title = decodeEntities(string(i, min(end, i + 1_000))).trimmingCharacters(in: .whitespacesAndNewlines)
            i = end
        default:
            if blockTags.contains(name) { addSpace() }
        }
    }

    /// Reads a quoted or bare attribute value. A value longer than `valueLimit` is passed over and kept only as its first part.
    mutating func readValue() -> String {
        guard i < b.count else { return "" }
        let q = b[i]
        if q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
            i += 1
            let start = i
            while i < b.count, b[i] != q { i += 1 }
            let v = string(start, min(i, start + HTMLScanner.linkLimit))
            i = min(i + 1, b.count)
            return v
        }
        let start = i
        while i < b.count, !isSpace(b[i]), b[i] != UInt8(ascii: ">") { i += 1 }
        return string(start, min(i, start + HTMLScanner.linkLimit))
    }

    mutating func record(_ tag: String, _ attrs: [(String, String)]) {
        var rel = "", type = "", href = "", titleAttr: String?, metaName: String?, content: String?
        for (name, raw) in attrs {
            let value = raw.contains("&") ? decodeEntities(raw) : raw
            switch name {
            case "class":
                for token in value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
                    facts.classes[String(token), default: 0] += 1
                }
                continue
            case "id":
                facts.ids.append(value)
                continue
            case "style":
                continue
            case "href", "src", "action":
                if !value.hasPrefix("data:"), !value.isEmpty { facts.links.append(value) }
                if name == "href" { href = value }
            case "rel": rel = value.lowercased()
            case "type": type = value.lowercased()
            case "title": titleAttr = value
            case "name", "property", "http-equiv", "itemprop": if metaName == nil { metaName = value }
            case "content": content = value
            default: break
            }
            if facts.attributes.count < HTMLScanner.attributeCap, !value.hasPrefix("data:") {
                facts.attributes.append(value.isEmpty ? name : "\(name)=\(value.prefix(HTMLScanner.valueLimit))")
            }
        }
        switch tag {
        case "meta":
            if let metaName, let content {
                facts.metas.append("\(metaName)=\(content)")
                if metaName.lowercased() == "generator" { facts.generators.append(content) }
                if metaName.lowercased() == "og:url", facts.canonicalURL == nil { facts.canonicalURL = content }
            }
        case "link":
            let rels = rel.split(separator: " ")
            if rels.contains("canonical"), !href.isEmpty { facts.canonicalURL = href }
            if rels.contains("alternate"), !href.isEmpty, type.contains("rss") || type.contains("atom") {
                let kind = type.contains("atom") ? "atom" : "rss"
                let feed = FeedLink(kind: kind, url: href, title: titleAttr)
                if !facts.feeds.contains(feed) { facts.feeds.append(feed) }
            }
        default: break
        }
    }

    // MARK: Text

    mutating func addText(_ c: UInt8) {
        guard text.count < HTMLScanner.textLimit else { return }
        if isSpace(c) { addSpace(); return }
        text.append(c)
        lastWasSpace = false
    }

    mutating func addSpace() {
        guard !lastWasSpace, text.count < HTMLScanner.textLimit else { return }
        text.append(UInt8(ascii: " "))
        lastWasSpace = true
    }

    /// Turns the few entities that matter for matching text into characters; anything else is kept as written.
    mutating func entity() {
        let end = min(i + 10, b.count)
        var j = i + 1
        while j < end, b[j] != UInt8(ascii: ";") { j += 1 }
        if j < end {
            let name = string(i + 1, j)
            let replacement: String? = switch name {
            case "nbsp", "#160": " "
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "quot": "\""
            case "#39", "apos": "'"
            case "copy": "©"
            default: nil
            }
            if let replacement {
                for byte in replacement.utf8 { addText(byte) }
                i = j + 1
                return
            }
        }
        addText(b[i]); i += 1
    }

    // MARK: Byte helpers

    func starts(with s: StaticString, at index: Int) -> Bool {
        let count = s.utf8CodeUnitCount
        guard index + count <= b.count else { return false }
        return s.withUTF8Buffer { p in (0..<count).allSatisfy { b[index + $0] == p[$0] } }
    }

    func find(_ s: StaticString, from: Int) -> Int? {
        let count = s.utf8CodeUnitCount
        return s.withUTF8Buffer { p -> Int? in
            var k = from
            while k + count <= b.count {
                if b[k] == p[0], (1..<count).allSatisfy({ b[k + $0] == p[$0] }) { return k }
                k += 1
            }
            return nil
        }
    }

    /// Finds `</name`, ignoring case, and returns where it starts.
    func find(closing name: String, from: Int) -> Int? {
        let target = Array(name.utf8)
        var k = from
        while k + target.count + 2 <= b.count {
            if b[k] == UInt8(ascii: "<"), b[k + 1] == UInt8(ascii: "/") {
                var match = true
                for (o, t) in target.enumerated() where lower(b[k + 2 + o]) != t { match = false; break }
                if match { return k }
            }
            k += 1
        }
        return nil
    }

    mutating func skip(past byte: UInt8) {
        while i < b.count, b[i] != byte { i += 1 }
        i = min(i + 1, b.count)
    }

    func string(_ from: Int, _ to: Int) -> String {
        guard from < to else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: b[from..<to]), as: UTF8.self)
    }

    func lowerString(_ from: Int, _ to: Int) -> String {
        guard from < to else { return "" }
        return String(decoding: b[from..<to].map(lower), as: UTF8.self)
    }

    func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c + 32 : c }
    func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
    func isNameByte(_ c: UInt8) -> Bool { isLetter(c) || (c >= 48 && c <= 57) || c == UInt8(ascii: "-") || c == UInt8(ascii: ":") || c == UInt8(ascii: "_") }
}

private let blockTags: Set<String> = ["p", "div", "br", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "article", "section", "header", "footer", "blockquote", "dt", "dd", "table", "ul", "ol"]

private func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var out = ""
    var rest = Substring(s)
    while let amp = rest.firstIndex(of: "&") {
        out += rest[..<amp]
        let after = rest[rest.index(after: amp)...]
        if let semi = after.prefix(12).firstIndex(of: ";"), let ch = entity(String(after[..<semi])) {
            out.append(ch)
            rest = after[after.index(after: semi)...]
        } else {
            out.append("&")
            rest = after
        }
    }
    return out + rest
}

private func entity(_ name: String) -> Character? {
    if name.hasPrefix("#x") || name.hasPrefix("#X") { return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(Character.init) }
    if name.hasPrefix("#") { return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map(Character.init) }
    return namedEntities[name]
}

private let namedEntities: [String: Character] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "middot": "·", "raquot": "»", "raquo": "»",
    "laquo": "«", "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©", "reg": "®", "trade": "™", "rsquo": "’", "lsquo": "‘",
    "rdquo": "”", "ldquo": "“", "bull": "•", "times": "×",
]
