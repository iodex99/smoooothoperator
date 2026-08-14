import Foundation

/// What a link into the app means.
///
/// The entitlement has declared `applinks:` since the first iOS commit and
/// nothing ever read the incoming URL, so every shared challenge opened the
/// app on Home and silently dropped the code — the invite worked exactly as
/// well as no invite at all.
///
/// Parsing lives in the Kit, not the app, for the usual reason: it is the
/// part with edge cases (case, trailing slashes, query codes, the custom
/// scheme, hostile input) and the Kit is the part that gets tested on Linux.
public enum DeepLink: Equatable, Sendable {
    /// A shared challenge invite. The code is normalised to uppercase.
    case challenge(code: String)
    /// A direct link to a course.
    case course(id: String)

    /// Codes are short, unambiguous and case-insensitive. Anything else is
    /// not a code, and guessing would send a driver to a stranger's run.
    public static let codePattern = "^[A-Z0-9]{4,12}$"

    /// Hosts a web link may claim to come from.
    ///
    /// iOS only fires a universal link for the associated domain, so this is
    /// belt-and-braces there — but the CUSTOM scheme has no such protection,
    /// and neither does anything else that hands this parser a URL. A link
    /// from a host we do not own is not our link.
    public static let allowedHosts: Set<String> = [
        "smoooothoperator.com",
        "www.smoooothoperator.com",
    ]

    public init?(url: URL, allowedHosts: Set<String> = DeepLink.allowedHosts) {
        if url.scheme?.hasPrefix("http") == true {
            guard let host = url.host?.lowercased(), allowedHosts.contains(host) else {
                return nil
            }
        }

        // Accept both the universal link and the custom scheme, because the
        // custom scheme is the fallback when the association file has not
        // propagated yet — and that fallback is exactly when links matter.
        let parts = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        // smoooothoperator.com/challenge/ABC123
        // smooothoperator://challenge/ABC123  (host carries the first segment)
        var segments = parts
        if url.scheme?.hasPrefix("http") == false, let host = url.host, !host.isEmpty {
            segments.insert(host, at: 0)
        }

        guard let kind = segments.first?.lowercased() else { return nil }
        let value = segments.count > 1
            ? segments[1]
            : URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value

        switch kind {
        case "challenge", "c":
            guard let code = Self.normalisedCode(value) else { return nil }
            self = .challenge(code: code)
        case "course":
            guard let id = value, Self.isPlausibleId(id) else { return nil }
            self = .course(id: id)
        default:
            return nil
        }
    }

    static func normalisedCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.range(of: codePattern, options: .regularExpression) != nil else {
            return nil
        }
        return code
    }

    /// A course id is a UUID. Anything else in that position is someone
    /// probing, and the app should not forward it to the server.
    static func isPlausibleId(_ raw: String) -> Bool {
        UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }
}
