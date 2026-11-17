import Foundation
import Testing
@testable import BSSSavedHTML

/// The scanner notes what a saved page shows without building a tree, skips what never shows (scripts, styles, inlined
/// data), and reads anything, valid or not, without crashing.
@Suite struct HTMLScannerTests {
    static let singleFilePage = """
    <!--
     Page saved with SingleFile
     url: https://forum.example/threads/door-seal.4512/?a=1&amp;b=2
     saved date: Wed Nov 11 2026 10:00:00 GMT+0000
    -->
    <html><head>
    <title>Door seal &amp; hinge</title>
    <meta name="generator" content="Example Boards 2.3">
    <meta property="og:url" content="https://forum.example/og">
    <link rel="canonical" href="https://forum.example/threads/door-seal.4512/">
    <link rel="alternate" type="application/rss+xml" title="Latest" href="/forums/-/index.rss">
    <link rel="alternate" type="application/atom+xml" href="/feed.atom">
    <style>.post { color: red } Hidden style text</style>
    <script>var hidden = "script text";</script>
    </head><body>
    <div class="post message" id="post-1"><p>First&nbsp;post</p><img src="data:image/png;base64,AAAA" alt="x"></div>
    <div class="post" id="post-2" style="display:none">Second <a href="/members/jane.7/">Jane</a></div>
    <form action="/search"></form>
    </body></html>
    """

    @Test func readsTheSingleFileHeader() {
        let facts = HTMLScanner.scan(Self.singleFilePage)
        #expect(facts.savedWithSingleFile)
        #expect(facts.savedURL == "https://forum.example/threads/door-seal.4512/?a=1&b=2")
        #expect(facts.savedDate?.hasPrefix("Wed Nov 11 2026") == true)
        #expect(facts.pageURL == facts.savedURL)
    }

    @Test func readsTitleGeneratorAndCanonical() {
        let facts = HTMLScanner.scan(Self.singleFilePage)
        #expect(facts.title == "Door seal & hinge")
        #expect(facts.generators == ["Example Boards 2.3"])
        #expect(facts.canonicalURL == "https://forum.example/threads/door-seal.4512/")
        #expect(facts.metas.contains("generator=Example Boards 2.3"))
    }

    @Test func withoutSingleFileThePageURLIsTheCanonical() {
        let facts = HTMLScanner.scan(#"<meta property="og:url" content="https://site.example/a"><p>x</p>"#)
        #expect(!facts.savedWithSingleFile)
        #expect(facts.pageURL == "https://site.example/a")
    }

    @Test func countsTagsClassesAndIDs() {
        let facts = HTMLScanner.scan(Self.singleFilePage)
        #expect(facts.tags["div"] == 2)
        #expect(facts.classes["post"] == 2)
        #expect(facts.classes["message"] == 1)
        #expect(facts.ids == ["post-1", "post-2"])
        #expect(!facts.attributes.contains { $0.hasPrefix("style=") || $0.hasPrefix("class=") || $0.hasPrefix("id=") })
    }

    @Test func findsFeedsAndLinksButNotDataAddresses() {
        let facts = HTMLScanner.scan(Self.singleFilePage)
        #expect(facts.feeds == [FeedLink(kind: "rss", url: "/forums/-/index.rss", title: "Latest"),
                                FeedLink(kind: "atom", url: "/feed.atom")])
        #expect(facts.links.contains("/members/jane.7/"))
        #expect(facts.links.contains("/search"))
        #expect(!facts.links.contains { $0.hasPrefix("data:") })
    }

    @Test func textSkipsScriptsAndStylesAndFoldsSpace() {
        let facts = HTMLScanner.scan(Self.singleFilePage)
        #expect(facts.text.contains("First post"))
        #expect(facts.text.contains("Second Jane"))
        #expect(!facts.text.contains("hidden"))
        #expect(!facts.text.contains("Hidden style"))
        #expect(!facts.text.contains("  "))
    }

    @Test func aHugeInlinedAttributeIsCutNotCopied() {
        let blob = String(repeating: "A", count: 5_000_000)
        let facts = HTMLScanner.scan("<img src=\"data:image/png;base64,\(blob)\"><a href=\"/\(blob)\">x</a><p>after</p>")
        #expect(facts.text.contains("after"))
        #expect(facts.links.allSatisfy { $0.count <= HTMLScanner.linkLimit })
        #expect(facts.byteCount > 10_000_000)
    }

    @Test func textStopsAtTheLimit() {
        let facts = HTMLScanner.scan(String(repeating: "word ", count: HTMLScanner.textLimit))
        #expect(facts.text.utf8.count <= HTMLScanner.textLimit)
    }

    @Test func readsAFileOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "scanner-\(UUID().uuidString).html")
        try Data(Self.singleFilePage.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try HTMLScanner.scan(fileAt: url).title == "Door seal & hinge")
    }

    @Test func threeThousandSeededCasesNeverCrashTheScanner() {
        var rng = HTMLTreeTests.SplitMix(state: 20_261_113)
        for caseNumber in 0..<3_000 {
            var bytes: [UInt8] = []
            if caseNumber % 5 == 0 {
                bytes = (0..<Int.random(in: 0...600, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            } else {
                for _ in 0..<Int.random(in: 1...300, using: &rng) {
                    bytes += Array(HTMLTreeTests.tokens.randomElement(using: &rng)!.utf8)
                }
            }
            let facts = HTMLScanner.scan(Data(bytes))
            #expect(facts.byteCount == bytes.count, "case \(caseNumber)")
        }
    }
}
