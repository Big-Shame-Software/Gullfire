import Foundation

/// Removes credentials from web addresses before they are shown, logged or handed to anyone (an LLM included):
/// private sites put passkeys, session tokens and member numbers in feed and download links.
/// `Redact.url` works on a single address or on text with addresses in it; what it removes becomes `REDACTED`.
public enum Redact {
    /// A query, matrix or fragment parameter: its separator, its name, its value. A fragment (`#…`) is read like a query.
    static let parameter = try! NSRegularExpression(pattern: "([?&;#])([^=&;#?]*)=[^&;#]*")

    /// Name fragments that mark a credential wherever they appear: `passkey`, `PHPSESSID`, `rsskey`.
    static let credentialFragments = ["passkey", "password", "passwd", "token", "secret", "session", "sessid", "authkey",
                                      "rsskey", "apikey", "api_key", "api-key", "userid", "user_id", "email",
                                      "authorization_code", "authorization-code", "verification_code", "verification-code"]
    /// Words that mark a credential only as a whole token of the name: `pass`, `user_pass`, `user.key`, `sid`, `sig`,
    /// but not `keyword`, `hashtag`, `monkey`, `sesc`. `code` is not here: it is redacted only in an OAuth query (see `oauthContextNames`).
    /// `user` is here too: a member's number in a feed or profile link identifies a person.
    static let credentialWords: Set<String> = ["pass", "auth", "sid", "sig", "uid", "login", "key", "hash", "user"]
    /// A query that carries any of these names is an OAuth or sign-in redirect, and its `code` is a credential.
    static let oauthContextNames: Set<String> = ["state", "client_id", "redirect_uri"]

    /// A credential word or known credential path, then a separator, then a run of 24 or more hex digits:
    /// `token/0123…`, `download.php/0123…`, `uid=0123…`. A bare hex run, such as a commit hash in a link, is not matched.
    static let credentialHex = try! NSRegularExpression(
        pattern: "(?<![a-z0-9])((?:passkey|password|token|secret|session|sessid|authkey|rsskey|apikey|api[_-]?key|userid|user_id|pass|auth|sid|sig|uid|rss|feeds?|dl|download(?:\\.[a-z]{2,4})?)[=/_:.\\-]+)[0-9a-f]{24,}",
        options: [.caseInsensitive])

    public static func url(_ s: String) -> String {
        var out = redactParameters(s)
        out = replace(credentialHex, in: out, with: "$1REDACTED")
        return out
    }

    /// Whether a parameter name is a credential: it contains a credential fragment, or one of its words is a credential word.
    public static func isCredentialName(_ name: String) -> Bool {
        let n = name.lowercased()
        if credentialFragments.contains(where: { n.contains($0) }) { return true }
        let words = n.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." }).map(String.init)
        return words.contains(where: credentialWords.contains)
    }

    /// A query string (from `?`) or a fragment (from `#`), each ending at whitespace, a quote, an angle bracket,
    /// or the next `?` or `#`, so that each is checked on its own.
    static let query = try! NSRegularExpression(pattern: "[?#][^\\s\"'<>?#]*")

    static func redactParameters(_ s: String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for q in query.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: q.range.location - last))
            out += redactQuery(ns.substring(with: q.range))
            last = q.range.location + q.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// One query or fragment segment. Parameters are checked one at a time, except `code`, which is a credential only when the
    /// same query is an OAuth redirect (it also carries `state`, `client_id` or `redirect_uri`).
    static func redactQuery(_ q: String) -> String {
        let ns = q as NSString
        let matches = parameter.matches(in: q, range: NSRange(location: 0, length: ns.length))
        let names = matches.map { ns.substring(with: $0.range(at: 2)) }
        let oauth = names.contains { oauthContextNames.contains($0.lowercased()) }
        var out = ""
        var last = 0
        for (m, name) in zip(matches, names) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if isCredentialName(name) || (oauth && name.lowercased() == "code") {
                out += ns.substring(with: m.range(at: 1)) + name + "=REDACTED"
            } else {
                // Any other parameter keeps its name and value, except a run of 24 or more hex digits in the value: session ids
                // (vBulletin's `s=`) and keys carried inside a feed name are removed whatever the parameter is called.
                let whole = ns.substring(with: m.range)
                if let eq = whole.firstIndex(of: "=") {
                    out += String(whole[...eq]) + replace(valueHex, in: String(whole[whole.index(after: eq)...]), with: "REDACTED")
                } else {
                    out += whole
                }
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// 24 or more hex digits standing alone in a value, or set off by punctuation such as `_` or `-`.
    static let valueHex = try! NSRegularExpression(pattern: "(?<![0-9a-zA-Z])[0-9a-fA-F]{24,}(?![0-9a-zA-Z])")

    static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

