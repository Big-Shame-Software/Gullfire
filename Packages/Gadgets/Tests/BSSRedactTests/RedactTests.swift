import Testing
import Foundation
@testable import BSSRedact

/// The redaction policy: credential names are redacted, names that only contain a credential-like string are not,
/// `code` only in an OAuth query, and hex runs only in a credential context.
@Suite struct RedactionRulesTests {
    static let commit = "0123456789abcdef0123456789abcdef01234567"

    @Test(arguments: ["passkey", "pass", "user_pass", "token", "auth", "authkey", "sid", "xf_sid", "PHPSESSID",
                      "session", "secret", "sig", "uid", "userid", "rsskey", "email", "login", "api_key", "apikey",
                      "key", "hash", "user.key", "authorization_code", "authorization-code",
                      "verification_code", "verification-code"])
    func credentialNamesAreRedacted(name: String) {
        #expect(Redact.url("https://tracker.example/rss.php?\(name)=abc123&ddl=1") == "https://tracker.example/rss.php?\(name)=REDACTED&ddl=1")
    }

    @Test(arguments: ["keyword", "hashtag", "monkey", "code", "sesc", "sigma", "oauth", "passage", "author", "sidebar", "topic", "page", "q"])
    func harmlessNamesAreKept(name: String) {
        let url = "/search/?\(name)=door+seal"
        #expect(Redact.url(url) == url)
    }

    @Test func plainSearchLinkIsUntouched() {
        let url = "/search.php?keyword=door+seal&code=7&sort=new"
        #expect(Redact.url(url) == url)
    }

    @Test func hashParameterIsRedactedInASearchLink() {
        #expect(Redact.url("/search.php?keyword=door&hash=abc") == "/search.php?keyword=door&hash=REDACTED")
    }

    @Test func codeIsRedactedInAnOAuthQuery() {
        let url = "/oauth/callback?client_id=abc&redirect_uri=https%3A%2F%2Fx.example%2Fcb&state=s1&code=SECRETCODE"
        #expect(Redact.url(url) == "/oauth/callback?client_id=abc&redirect_uri=https%3A%2F%2Fx.example%2Fcb&state=s1&code=REDACTED")
    }

    @Test func codeIsRedactedWhenAnyOAuthNameIsPresent() {
        #expect(Redact.url("/cb?state=s1&code=SECRETCODE") == "/cb?state=s1&code=REDACTED")
        #expect(Redact.url("/cb?code=SECRETCODE&redirect_uri=x") == "/cb?code=REDACTED&redirect_uri=x")
    }

    @Test func bareCodeIsKept() {
        let url = "/callback?code=abc123"
        #expect(Redact.url(url) == url)
    }

    @Test func oauthContextDoesNotSpreadToOtherAddresses() {
        let text = "/login?state=1 and then /b?code=7"
        #expect(Redact.url(text) == text)
    }

    @Test func nonHexTokenInFragmentIsRedacted() {
        #expect(Redact.url("https://site.example/cb#access_token=eyJhbGciOiJIUzI1NiJ9.payload.sig")
                == "https://site.example/cb#access_token=REDACTED")
    }

    @Test func codeIsRedactedInAFragmentOAuthContext() {
        #expect(Redact.url("https://site.example/cb#state=abc&code=XYZ") == "https://site.example/cb#state=abc&code=REDACTED")
    }

    @Test func plainAnchorIsUnchanged() {
        let url = "https://site.example/thread#post-42"
        #expect(Redact.url(url) == url)
    }

    @Test func credentialInFragmentAfterQueryIsRedacted() {
        #expect(Redact.url("https://site.example/x?a=1#sid=abc") == "https://site.example/x?a=1#sid=REDACTED")
    }

    @Test func oauthContextDoesNotCrossFromQueryToFragment() {
        #expect(Redact.url("https://site.example/x?state=1#code=XYZ") == "https://site.example/x?state=1#code=XYZ")
    }

    @Test func hexTokenInFragmentIsRedacted() {
        #expect(Redact.url("https://site.example/cb#token=\(Self.commit)40") == "https://site.example/cb#token=REDACTED")
        #expect(Redact.url("https://site.example/cb#/dl/\(Self.commit)") == "https://site.example/cb#/dl/REDACTED")
    }

    @Test func vbulletinSessionInSIsRedactedAndAShortSearchTermIsKept() {
        #expect(Redact.url("/forumdisplay.php?s=\(Self.commit.prefix(32))&f=12") == "/forumdisplay.php?s=REDACTED&f=12")
        #expect(Redact.url("/search.php?s=door&f=12") == "/search.php?s=door&f=12")
    }

    @Test func hexInsideAFeedNameIsRedactedWhateverTheParameter() {
        let hex = String(Self.commit.prefix(32))
        #expect(Redact.url("/feeds.php?feed=torrents_notify_\(hex)&user=1234") == "/feeds.php?feed=torrents_notify_REDACTED&user=REDACTED")
        #expect(Redact.url("/x?ref=\(Self.commit)") == "/x?ref=REDACTED")
    }

    @Test func memberNumbersInUserParametersAreRedacted() {
        #expect(Redact.url("/feeds.php?user=150") == "/feeds.php?user=REDACTED")
        #expect(Redact.url("/profile?user_name=jane") == "/profile?user_name=REDACTED")
    }

    @Test func commitHashesInPathsSurviveButNotInQueryValues() {
        let path = "https://github.example/org/repo/commit/\(Self.commit)"
        #expect(Redact.url(path) == path)
    }

    @Test func commitHashesInLinksSurvive() {
        let link = "https://github.example/org/repo/commit/\(Self.commit)"
        #expect(Redact.url(link) == link)
        let post = "/threads/door-seal.4512/post-\(Self.commit)"
        #expect(Redact.url(post) == post)
    }

    @Test(arguments: ["/token/", "/rss/", "/feed/", "/download.php/", "/dl/", "/passkey/", "/userid="])
    func hexAfterCredentialContextIsRedacted(context: String) {
        #expect(Redact.url("\(context)\(Self.commit)/file") == "\(context)REDACTED/file")
    }

    @Test func hexAfterCredentialWordWithSeparatorIsRedacted() {
        #expect(Redact.url("/auth_\(Self.commit)") == "/auth_REDACTED")
        #expect(Redact.url("/sid:\(Self.commit)") == "/sid:REDACTED")
    }

    @Test func shortHexIsNeverRedactedByItself() {
        let url = "/token/abc123"
        #expect(Redact.url(url) == url)
    }

    @Test func isCredentialNameMatchesWholeWords() {
        #expect(Redact.isCredentialName("user-pass"))
        #expect(Redact.isCredentialName("user.key"))
        #expect(!Redact.isCredentialName("keyword"))
        #expect(!Redact.isCredentialName("hashtag"))
        #expect(!Redact.isCredentialName("monkey"))
        #expect(!Redact.isCredentialName("sigma"))
    }
}
