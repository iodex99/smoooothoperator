import Foundation

/// Email one-time-code sign-in: the rules, separated from the screen.
///
/// Apple and Google cover most people and exclude a real slice — anyone
/// without either account, and anyone who simply will not hand a social
/// login to a driving app. This is the third door, and it deliberately does
/// NOT involve a password: we hold no credentials, there is no reset flow to
/// get wrong, and a breach of this database exposes no reusable secret.
///
/// The logic lives in the Kit because the iOS layer cannot be tested from
/// Linux, and every rule here is exactly the kind that rots silently in a
/// view: an email that normalises one way at send and another at verify
/// gives you `otp_expired` on a code that was perfectly valid.
public enum EmailSignIn {

    // ── Address ───────────────────────────────────────────────────────────

    /// Normalises an address for submission, or nil if it cannot be one.
    ///
    /// SENDING AND VERIFYING MUST NORMALISE IDENTICALLY. Supabase matches
    /// the code against the address it was issued to; " Me@Example.com "
    /// at send and "me@example.com" at verify are two different accounts as
    /// far as the API is concerned, and the failure surfaces as an expired
    /// or invalid code rather than as a mismatch.
    ///
    /// Lowercasing the whole address is technically wrong — the local part
    /// is case-sensitive per RFC 5321 — and is what every mail provider
    /// people actually use does anyway. Consistency beats pedantry here:
    /// the alternative is a user who signs up as `Sam@` and can never sign
    /// in as `sam@`.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                         .lowercased()
        return isPlausible(trimmed) ? trimmed : nil
    }

    /// Deliberately permissive. This check exists to catch a typo before we
    /// spend an email on it, not to adjudicate RFC 5322 — a regex that tries
    /// to is famously wrong at the edges, and the authoritative test is
    /// whether the code arrives.
    public static func isPlausible(_ address: String) -> Bool {
        guard address.count >= 6, address.count <= 254 else { return false }
        guard !address.contains(" ") else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }          // exactly one @
        let (local, domain) = (parts[0], parts[1])
        guard !local.isEmpty, local.count <= 64 else { return false }
        guard domain.count >= 4, domain.contains(".") else { return false }
        guard !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        guard !domain.contains("..") else { return false }
        // A bare TLD is a typo ("me@gmail" — the one people actually make).
        guard let tld = domain.split(separator: ".").last, tld.count >= 2 else {
            return false
        }
        return true
    }

    // ── Code ──────────────────────────────────────────────────────────────

    public static let codeLength = 6

    /// Strips the formatting people paste in — spaces and dashes from a mail
    /// client that helpfully broke the number up — and keeps the digits.
    public static func normalizeCode(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    public static func isCompleteCode(_ raw: String) -> Bool {
        normalizeCode(raw).count == codeLength
    }

    // ── Resend ────────────────────────────────────────────────────────────

    /// Seconds before "resend" is offered again.
    ///
    /// Not politeness: Supabase rate-limits OTP sends per address, and a
    /// driver who taps resend three times in five seconds burns the quota
    /// and is then locked out of their own account for an hour. The button
    /// is disabled for longer than the mail usually takes.
    public static let resendCooldownSeconds = 45

    public static func resendAvailable(secondsSinceSend: Int) -> Bool {
        secondsSinceSend >= resendCooldownSeconds
    }

    public static func resendCountdown(secondsSinceSend: Int) -> Int {
        max(0, resendCooldownSeconds - secondsSinceSend)
    }
}
