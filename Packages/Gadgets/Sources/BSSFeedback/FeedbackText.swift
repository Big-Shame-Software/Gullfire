import Foundation
import BSSRedact

/// Text from a problem report or an idea, cleaned before it's written.
/// Home folders become `~`, and web addresses go through `BSSRedact`, which removes credentials.
/// The text is data. Nothing in it is ever treated as an instruction.
public enum FeedbackText {
    public static func scrub(_ text: String) -> String {
        redactLinks(text).replacingOccurrences(of: #"/Users/[^/\s"'<>]+"#, with: "~", options: .regularExpression)
    }

    static func redactLinks(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += Redact.url(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
