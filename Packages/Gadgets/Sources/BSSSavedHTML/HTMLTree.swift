import Foundation

/// A tolerant HTML tree for saved pages. It keeps elements, attributes, text and the common entities. It skips
/// comments, the doctype, and the contents of script and style. It closes what a page leaves open and ignores end tags
/// with no match. It is not a browser: nothing in the page runs, and nothing is fetched.
public final class HTMLNode {
    /// The lowercased tag name, or "#document" for the root and "#text" for text.
    public let name: String
    public var attributes: [String: String]
    /// The text of a "#text" node.
    public var text: String
    public var children: [HTMLNode] = []

    init(name: String, attributes: [String: String] = [:], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.text = text
    }

    public var classes: Set<String> {
        Set((attributes["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    public func hasClass(_ name: String) -> Bool { classes.contains(name) }

    /// Every element below this node that the test accepts, in document order. The depth is capped by the parser, so
    /// this recursion is bounded by `HTMLTree.maxDepth`.
    public func elements(where test: (HTMLNode) -> Bool) -> [HTMLNode] {
        var found: [HTMLNode] = []
        func visit(_ node: HTMLNode) {
            for child in node.children where child.name != "#text" {
                if test(child) { found.append(child) }
                visit(child)
            }
        }
        visit(self)
        return found
    }

    /// The markup of this node and everything below it, written back out with its text and attributes escaped.
    public var outerHTML: String {
        var out = ""
        serialize(into: &out)
        return out
    }

    private func serialize(into out: inout String) {
        if name == "#text" {
            out += text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return
        }
        guard name != "#document" else {
            for child in children { child.serialize(into: &out) }
            return
        }
        out += "<" + name
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            let escaped = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
            out += " \(key)=\"\(escaped)\""
        }
        out += ">"
        if HTMLTree.voidElements.contains(name) { return }
        for child in children { child.serialize(into: &out) }
        out += "</\(name)>"
    }

    /// The text below this node, with runs of white space folded to one space and the ends trimmed.
    public var textContent: String {
        var pieces: [String] = []
        func visit(_ node: HTMLNode) {
            if node.name == "#text" { pieces.append(node.text) }
            for child in node.children { visit(child) }
        }
        visit(self)
        return pieces.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// The result of parsing. When `limit` is set, parsing stopped early at a cap and `root` holds only what was read
/// before the stop; it must not be used.
public struct HTMLDocument {
    public let root: HTMLNode
    public let limit: String?
}

public enum HTMLTree {
    /// Caps. A page that reaches one stops parsing, and `HTMLDocument.limit` says which cap it hit.
    public static let maxDepth = 512
    public static let maxNodes = 200_000
    public static let maxAttributes = 256
    public static let maxAttributeBytes = 2_097_152   // 2 MiB: saved pages carry inline images in attributes up to about 500 KB

    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    static let rawTextElements: Set<String> = ["script", "style"]

    public static func parse(_ html: String) -> HTMLDocument {
        let bytes = Array(html.utf8)
        let count = bytes.count
        let root = HTMLNode(name: "#document")
        var stack: [HTMLNode] = [root]
        var text: [UInt8] = []
        var index = 0
        var nodeCount = 0
        var limit: String?

        func append(_ node: HTMLNode) -> Bool {
            guard nodeCount < maxNodes else {
                if limit == nil { limit = "the page has more than \(maxNodes) nodes" }
                return false
            }
            nodeCount += 1
            stack[stack.count - 1].children.append(node)
            return true
        }

        func flushText() {
            defer { text.removeAll(keepingCapacity: true) }
            guard limit == nil, !text.isEmpty else { return }
            let decoded = decodeEntities(String(decoding: text, as: UTF8.self)).replacingOccurrences(of: "\0", with: "\u{FFFD}")
            if !decoded.isEmpty { _ = append(HTMLNode(name: "#text", text: decoded)) }
        }

        func startsWith(_ pattern: String, at position: Int) -> Bool {
            let p = Array(pattern.utf8)
            guard position + p.count <= count else { return false }
            for k in 0..<p.count where bytes[position + k] != p[k] { return false }
            return true
        }

        func indexOf(_ pattern: String, from position: Int, caseInsensitive: Bool = false) -> Int? {
            let p = Array((caseInsensitive ? pattern.lowercased() : pattern).utf8)
            guard !p.isEmpty else { return nil }
            var k = position
            while k + p.count <= count {
                var match = true
                for j in 0..<p.count {
                    var c = bytes[k + j]
                    if caseInsensitive, c >= 65, c <= 90 { c += 32 }
                    if c != p[j] { match = false; break }
                }
                if match { return k }
                k += 1
            }
            return nil
        }

        func isNameByte(_ c: UInt8) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45 || c == 58
        }

        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }

        func readName(_ position: inout Int) -> String {
            let start = position
            while position < count, isNameByte(bytes[position]) { position += 1 }
            return String(decoding: bytes[start..<position], as: UTF8.self).lowercased()
        }

        func skipSpace(_ position: inout Int) {
            while position < count, isSpace(bytes[position]) { position += 1 }
        }

        while index < count, limit == nil {
            guard bytes[index] == 60 else {   // not '<'
                text.append(bytes[index])
                index += 1
                continue
            }
            if startsWith("<!--", at: index) {
                flushText()
                index = (indexOf("-->", from: index + 4) ?? count - 3) + 3   // an unterminated comment runs to the end
                continue
            }
            if index + 1 < count, bytes[index + 1] == 33 || bytes[index + 1] == 63 {   // "<!" or "<?"
                flushText()
                index = (indexOf(">", from: index + 2) ?? count - 1) + 1
                continue
            }
            if index + 1 < count, bytes[index + 1] == 47 {   // "</"
                flushText()
                var position = index + 2
                let name = readName(&position)
                index = (indexOf(">", from: position) ?? count - 1) + 1
                if let open = stack.lastIndex(where: { $0.name == name }), open > 0 {
                    stack.removeSubrange(open...)
                }
                continue
            }
            guard index + 1 < count, (bytes[index + 1] >= 97 && bytes[index + 1] <= 122) || (bytes[index + 1] >= 65 && bytes[index + 1] <= 90) else {
                text.append(60)   // a '<' that does not start a tag is text
                index += 1
                continue
            }
            flushText()
            var position = index + 1
            let name = readName(&position)
            var attributes: [String: String] = [:]
            var selfClosing = false
            var attributeCount = 0
            while position < count {
                skipSpace(&position)
                guard position < count else { break }
                if bytes[position] == 62 { position += 1; break }                                  // ">"
                if bytes[position] == 47, position + 1 < count, bytes[position + 1] == 62 {          // "/>"
                    selfClosing = true
                    position += 2
                    break
                }
                if bytes[position] == 47 { position += 1; continue }
                let before = position
                let attributeName = readAttributeName(bytes, &position)
                skipSpace(&position)
                var value = ""
                if position < count, bytes[position] == 61 {                                       // "="
                    position += 1
                    skipSpace(&position)
                    if position < count, bytes[position] == 34 || bytes[position] == 39 {
                        let quote = bytes[position]
                        position += 1
                        let start = position
                        while position < count, bytes[position] != quote { position += 1 }
                        value = String(decoding: bytes[start..<position], as: UTF8.self)
                        if position < count { position += 1 }                                     // an unclosed quote runs to the end
                    } else {
                        let start = position
                        while position < count, !(isSpace(bytes[position]) || bytes[position] == 62) { position += 1 }
                        value = String(decoding: bytes[start..<position], as: UTF8.self)
                    }
                }
                if position == before { position += 1 }   // always make progress
                attributeCount += 1
                if attributeCount > maxAttributes {
                    limit = "an element has more than \(maxAttributes) attributes"
                    break
                }
                if value.utf8.count > maxAttributeBytes {
                    limit = "an attribute is longer than \(maxAttributeBytes) bytes"
                    break
                }
                if !attributeName.isEmpty, attributes[attributeName] == nil {
                    attributes[attributeName] = decodeEntities(value).replacingOccurrences(of: "\0", with: "\u{FFFD}")
                }
            }
            index = position
            guard limit == nil else { break }
            let node = HTMLNode(name: name, attributes: attributes)
            guard append(node) else { break }
            if rawTextElements.contains(name) {
                index = indexOf("</\(name)", from: index, caseInsensitive: true) ?? count
                if index < count { index = (indexOf(">", from: index) ?? count - 1) + 1 }
                continue
            }
            if !selfClosing, !voidElements.contains(name) {
                guard stack.count < maxDepth else {
                    limit = "the page is nested deeper than \(maxDepth) levels"
                    break
                }
                stack.append(node)
            }
        }
        flushText()
        return HTMLDocument(root: root, limit: limit)
    }

    static func readAttributeName(_ bytes: [UInt8], _ position: inout Int) -> String {
        let start = position
        while position < bytes.count {
            let c = bytes[position]
            if c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 61 || c == 62 || c == 47 { break }
            position += 1
        }
        return String(decoding: bytes[start..<position], as: UTF8.self).lowercased()
    }

    /// The common named entities and numeric references. Anything else is left as written. A reference that is not a
    /// valid scalar, such as a surrogate or a number too large to hold, is left as written too.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " ", "&copy;": "©", "&reg;": "®"]
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            guard let semi = tail.firstIndex(of: ";"), tail.distance(from: tail.startIndex, to: semi) <= 10 else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
                continue
            }
            let entity = String(tail[...semi])
            if let plain = named[entity] {
                out += plain
            } else if entity.hasPrefix("&#x") || entity.hasPrefix("&#X"), let code = UInt32(entity.dropFirst(3).dropLast(), radix: 16), let scalar = Unicode.Scalar(code) {
                out.append(Character(scalar))
            } else if entity.hasPrefix("&#"), let code = UInt32(entity.dropFirst(2).dropLast()), let scalar = Unicode.Scalar(code) {
                out.append(Character(scalar))
            } else {
                out += entity
            }
            rest = tail[tail.index(after: semi)...]
        }
        out += rest
        return out
    }
}
