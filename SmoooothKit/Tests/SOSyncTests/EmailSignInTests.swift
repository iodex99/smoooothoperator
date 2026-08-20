import Testing
@testable import SOSync

/// Email sign-in is the third door into the app, added 2026-08-20 because
/// Apple and Google exclude anyone holding neither account.
@Suite("Email sign-in")
struct EmailSignInTests {

    @Test("an ordinary address normalises to itself")
    func ordinaryAddress() {
        #expect(EmailSignIn.normalize("driver@example.com") == "driver@example.com")
    }

    /// The bug this prevents: sending the code to "Me@Example.com" and
    /// verifying against "me@example.com" is two different accounts to the
    /// API, and it surfaces as an invalid code rather than a mismatch.
    @Test("case and surrounding whitespace are removed, so send and verify agree")
    func normalisationIsStable() {
        let typed = "  Driver@Example.COM \n"
        #expect(EmailSignIn.normalize(typed) == "driver@example.com")
        // Idempotent: normalising an already-normal address changes nothing.
        let once = EmailSignIn.normalize(typed)!
        #expect(EmailSignIn.normalize(once) == once)
    }

    @Test("the typos people actually make are refused before an email is spent")
    func rejectsRealTypos() {
        #expect(EmailSignIn.normalize("me@gmail") == nil)        // no TLD
        #expect(EmailSignIn.normalize("me@@gmail.com") == nil)   // two @
        #expect(EmailSignIn.normalize("me gmail.com") == nil)    // space, no @
        #expect(EmailSignIn.normalize("@gmail.com") == nil)      // no local part
        #expect(EmailSignIn.normalize("me@.com") == nil)         // leading dot
        #expect(EmailSignIn.normalize("me@gmail..com") == nil)   // double dot
        #expect(EmailSignIn.normalize("me@gmail.com.") == nil)   // trailing dot
        #expect(EmailSignIn.normalize("") == nil)
        #expect(EmailSignIn.normalize("   ") == nil)
    }

    /// Being too clever here costs real users. Plus-addressing and long TLDs
    /// are ordinary, and a regex that rejects them is a support ticket.
    @Test("unusual but legitimate addresses are accepted")
    func acceptsLegitimateOddities() {
        #expect(EmailSignIn.normalize("driver+malibu@example.com") != nil)
        #expect(EmailSignIn.normalize("a.b.c@sub.domain.co.uk") != nil)
        #expect(EmailSignIn.normalize("me@example.technology") != nil)
        #expect(EmailSignIn.normalize("x1@e.io") != nil)
    }

    @Test("a pasted code keeps its digits and drops the decoration")
    func codeNormalisation() {
        #expect(EmailSignIn.normalizeCode("481027") == "481027")
        #expect(EmailSignIn.normalizeCode("481 027") == "481027")
        #expect(EmailSignIn.normalizeCode("481-027") == "481027")
        #expect(EmailSignIn.normalizeCode(" 481027 ") == "481027")
    }

    @Test("a code is complete only at exactly six digits")
    func codeCompleteness() {
        #expect(!EmailSignIn.isCompleteCode("48102"))
        #expect(EmailSignIn.isCompleteCode("481027"))
        #expect(!EmailSignIn.isCompleteCode("4810277"))
        #expect(!EmailSignIn.isCompleteCode("abcdef"))
    }

    /// Supabase rate-limits sends per address. Three impatient taps burn the
    /// quota and lock the driver out of their own account, so the cooldown
    /// is a correctness rule, not a nicety.
    @Test("resend is locked until the cooldown elapses")
    func resendCooldown() {
        #expect(!EmailSignIn.resendAvailable(secondsSinceSend: 0))
        #expect(!EmailSignIn.resendAvailable(secondsSinceSend: 44))
        #expect(EmailSignIn.resendAvailable(secondsSinceSend: 45))
        #expect(EmailSignIn.resendAvailable(secondsSinceSend: 600))
    }

    @Test("the countdown reaches zero and stays there")
    func countdownIsClamped() {
        #expect(EmailSignIn.resendCountdown(secondsSinceSend: 0) == 45)
        #expect(EmailSignIn.resendCountdown(secondsSinceSend: 44) == 1)
        #expect(EmailSignIn.resendCountdown(secondsSinceSend: 45) == 0)
        #expect(EmailSignIn.resendCountdown(secondsSinceSend: 999) == 0)
    }
}
