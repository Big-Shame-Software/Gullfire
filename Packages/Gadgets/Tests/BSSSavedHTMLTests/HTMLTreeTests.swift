import Foundation
import Testing
@testable import BSSSavedHTML

/// The tree builder must read malformed markup without crashing, keep the text it can see, and stop at its caps with
/// a reason rather than recursing or allocating without limit.
@Suite struct HTMLTreeTests {
    /// A seeded generator, so that the fuzz cases are the same on every run.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func depth(_ node: HTMLNode) -> Int {
        1 + (node.children.map { depth($0) }.max() ?? 0)
    }

    static func count(_ node: HTMLNode) -> Int {
        1 + node.children.reduce(0) { $0 + count($1) }
    }

    // MARK: malformed markup

    @Test func unclosedAndMisnestedTagsKeepTheirText() {
        let doc = HTMLTree.parse("<b>one <i>two</b> three</i> four<p>five<p>six")
        #expect(doc.limit == nil)
        let text = doc.root.textContent
        for word in ["one", "two", "three", "four", "five", "six"] {
            #expect(text.contains(word), "\(word) was lost: \(text)")
        }
    }

    @Test func aStrayLessThanIsText() {
        let doc = HTMLTree.parse("a < b <3 c <")
        #expect(doc.limit == nil)
        #expect(doc.root.textContent == "a < b <3 c <")
    }

    @Test func anUnterminatedCommentRunsToTheEndAndIsNotText() {
        let doc = HTMLTree.parse("kept <!-- never closed, and this is inside it")
        #expect(doc.limit == nil)
        #expect(doc.root.textContent == "kept")
    }

    @Test func anUnterminatedAttributeRunsToTheEnd() {
        let doc = HTMLTree.parse("<a href=\"never closed")
        #expect(doc.limit == nil)
        #expect(doc.root.elements { $0.name == "a" }.first?.attributes["href"] == "never closed")
    }

    @Test func invalidEntitiesAreLeftAsWritten() {
        let doc = HTMLTree.parse("&#xZZ; &#99999999999999999999; &unknown; &#xD800; &;")
        #expect(doc.limit == nil)
        let text = doc.root.textContent
        #expect(text.contains("&unknown;"))
        #expect(text.contains("&#xZZ;"))
        #expect(text.contains("&;"))
    }

    @Test func nulBytesBecomeReplacementCharacters() {
        let doc = HTMLTree.parse("a\u{0}b<p title=\"x\u{0}y\">c</p>&#0;")
        #expect(doc.limit == nil)
        let text = doc.root.textContent
        #expect(text.contains("a\u{FFFD}b"))
        #expect(!text.contains("\u{0}"))
        #expect(doc.root.elements { $0.name == "p" }.first?.attributes["title"] == "x\u{FFFD}y")
    }

    // MARK: caps

    @Test func nestingPastTheDepthCapStopsWithAReason() {
        let doc = HTMLTree.parse(String(repeating: "<div>", count: HTMLTree.maxDepth + 10))
        #expect(doc.limit?.contains("nested") == true, "\(doc.limit ?? "no limit")")
    }

    @Test func nestingWithinTheCapIsRead() {
        let doc = HTMLTree.parse(String(repeating: "<div>", count: 300) + "deep" + String(repeating: "</div>", count: 300))
        #expect(doc.limit == nil)
        #expect(doc.root.textContent == "deep")
    }

    @Test func tooManyNodesStopWithAReason() {
        let doc = HTMLTree.parse(String(repeating: "<i></i>", count: HTMLTree.maxNodes + 1))
        #expect(doc.limit?.contains("nodes") == true, "\(doc.limit ?? "no limit")")
    }

    @Test func tooManyAttributesStopWithAReason() {
        let attributes = (0...HTMLTree.maxAttributes).map { "a\($0)=1" }.joined(separator: " ")
        let doc = HTMLTree.parse("<p \(attributes)>x</p>")
        #expect(doc.limit?.contains("attributes") == true)
    }

    @Test func aHugeAttributeStopsWithAReason() {
        let doc = HTMLTree.parse("<a title=\"" + String(repeating: "x", count: HTMLTree.maxAttributeBytes + 1) + "\">y</a>")
        #expect(doc.limit?.contains("longer") == true)
    }

    // MARK: fuzz

    static let tokens = ["<", ">", "</", "<!--", "-->", "<!", "<?", "&", "&#x", "&#", ";", "=", "\"", "'", "/", "div", "b", "i", "p",
                         "article", " ", "\n", "\u{0}", "cooked", "post_1", "class=", "id=", "<script>", "</script>", "<style>",
                         "é", "&amp;", "<article id=\"post_1\" class=\"topic-post\">", "</article>", "<title>", "</title>",
                         "<time datetime=\"2024\">", "<link rel=\"canonical\" href=\"https://c.example/t/x/1\">", "<br>", "</b>"]

    @Test func threeThousandSeededCasesNeverCrashTheTree() {
        var rng = SplitMix(state: 20_261_113)
        for caseNumber in 0..<3_000 {
            var html = ""
            if caseNumber % 5 == 0 {
                // Raw bytes, some of them not UTF-8.
                let bytes = (0..<Int.random(in: 0...600, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
                html = String(decoding: bytes, as: UTF8.self)
            } else {
                for _ in 0..<Int.random(in: 1...300, using: &rng) {
                    html += Self.tokens.randomElement(using: &rng)!
                }
            }
            let document = HTMLTree.parse(html)
            if document.limit == nil {
                #expect(Self.depth(document.root) <= HTMLTree.maxDepth + 2, "case \(caseNumber) is deeper than the cap")
                #expect(Self.count(document.root) <= HTMLTree.maxNodes + 1, "case \(caseNumber) has more nodes than the cap")
                _ = document.root.textContent
                _ = document.root.elements { $0.hasClass("cooked") }
            }
        }
    }
}
