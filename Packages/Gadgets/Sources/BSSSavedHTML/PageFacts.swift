import Foundation

/// What `HTMLScanner` notes about a saved page, read once.
/// Scripts and styles are skipped, never run, so a page saved with or without scripts reads the same.
public struct PageFacts: Sendable {
    /// From the comment SingleFile writes at the top of every page it saves.
    public var savedURL: String?
    public var savedDate: String?
    public var savedWithSingleFile = false
    /// `<link rel="canonical">` or `og:url`, used when the page has no SingleFile comment.
    public var canonicalURL: String?
    public var title = ""
    public var byteCount = 0

    /// Element name to how many times it appears, lowercased.
    public var tags: [String: Int] = [:]
    /// Class name to how many elements carry it. Case kept: class names are case sensitive.
    public var classes: [String: Int] = [:]
    public var ids: [String] = []
    /// Every attribute as `name=value`, value cut to 200 characters. Not `class`, `id` or `style`.
    public var attributes: [String] = []
    /// `name=content` for every meta element, using name, property or http-equiv.
    public var metas: [String] = []
    public var generators: [String] = []
    /// href, src and action values, without data: addresses.
    public var links: [String] = []
    public var feeds: [FeedLink] = []
    public var comments: [String] = []
    /// Visible text with runs of white space folded, cut to `textLimit` characters.
    public var text = ""

    public init() {}

    /// The address the page came from, as best known.
    public var pageURL: String? { savedURL ?? canonicalURL }
}

/// A feed the page names with `<link rel="alternate">`. `kind` is `rss` or `atom`.
public struct FeedLink: Codable, Sendable, Hashable {
    public var kind: String
    public var url: String
    public var title: String?

    public init(kind: String, url: String, title: String? = nil) {
        self.kind = kind
        self.url = url
        self.title = title
    }
}
