import Foundation
import Testing
@testable import SOSync

/// The entitlement declared `applinks:` from the first iOS commit and
/// nothing ever read the incoming URL, so a shared challenge opened the app
/// on Home and dropped the code. An invite that does nothing is worse than
/// no invite, because the sender believes it worked.
@Suite("Links into the app")
struct DeepLinkTests {
    static func link(_ string: String) -> DeepLink? {
        URL(string: string).flatMap { DeepLink(url: $0) }
    }

    @Test("a shared challenge link carries its code")
    func challengeLink() {
        #expect(Self.link("https://smoooothoperator.com/challenge/ABC123") == .challenge(code: "ABC123"))
    }

    @Test("the custom scheme works too — it is the fallback that matters most")
    func customScheme() {
        // Universal links stop working whenever the association file has not
        // propagated, which is precisely when a launch is happening.
        #expect(Self.link("smooothoperator://challenge/ABC123") == .challenge(code: "ABC123"))
        #expect(Self.link("smooothoperator://c/ABC123") == .challenge(code: "ABC123"))
    }

    @Test("codes are case-insensitive, because nobody types them exactly")
    func caseInsensitive() {
        #expect(Self.link("https://smoooothoperator.com/challenge/abc123") == .challenge(code: "ABC123"))
        #expect(Self.link("https://smoooothoperator.com/CHALLENGE/AbC123") == .challenge(code: "ABC123"))
    }

    @Test("a trailing slash is not a different link")
    func trailingSlash() {
        #expect(Self.link("https://smoooothoperator.com/challenge/ABC123/") == .challenge(code: "ABC123"))
    }

    @Test("a code in the query string is still a code")
    func queryForm() {
        #expect(Self.link("https://smoooothoperator.com/challenge?code=ABC123") == .challenge(code: "ABC123"))
    }

    @Test("a course link carries a real id, and only a real id")
    func courseLink() {
        let id = "3F2A1B9C-4D5E-4F60-8A1B-2C3D4E5F6071"
        #expect(Self.link("https://smoooothoperator.com/course/\(id)") == .course(id: id))
        // Anything that is not a UUID in that position is someone probing,
        // and the app must not forward it to the server.
        #expect(Self.link("https://smoooothoperator.com/course/../../admin") == nil)
        #expect(Self.link("https://smoooothoperator.com/course/1") == nil)
    }

    @Test("nonsense is refused rather than guessed at")
    func hostileInput() {
        let refusals = [
            "https://smoooothoperator.com/",
            "https://smoooothoperator.com/challenge",
            "https://smoooothoperator.com/challenge/",
            "https://smoooothoperator.com/challenge/AB",            // too short
            "https://smoooothoperator.com/challenge/ABCDEFGHIJKLMN", // too long
            "https://smoooothoperator.com/challenge/ABC-123",        // punctuation
            "https://smoooothoperator.com/challenge/<script>",
            "https://smoooothoperator.com/settings/reset",
            "https://evil.example.com/challenge/ABC123/../../x",
        ]
        for string in refusals {
            #expect(Self.link(string) == nil, "accepted \(string)")
        }
    }

    @Test("a code is never silently truncated into a valid one")
    func noTruncation() {
        // Accepting a prefix would send a driver to a completely different
        // challenge than the one they were sent.
        #expect(Self.link("https://smoooothoperator.com/challenge/ABC123XYZTOOLONG") == nil)
    }
}
