import Testing
@testable import SOSync

/// The free tier must be genuinely usable and the paid tier must genuinely
/// differ — otherwise the subscription sells nothing (audit 2026-08-13).
@Suite("Daily run allowance")
struct DailyRunAllowanceTests {
    @Test("a free driver gets a real number of runs before hitting the wall")
    func freeTierIsUsable() {
        #expect(DailyRunAllowance.allows(runsToday: 0, isPro: false))
        #expect(DailyRunAllowance.allows(runsToday: 2, isPro: false))
        #expect(!DailyRunAllowance.allows(runsToday: 3, isPro: false))
    }

    @Test("Pro is unlimited — the thing the subscription actually buys")
    func proIsUnlimited() {
        #expect(DailyRunAllowance.allows(runsToday: 99, isPro: true))
        #expect(DailyRunAllowance.remaining(runsToday: 99, isPro: true) == nil)
    }

    @Test("remaining never goes negative")
    func remainingIsClamped() {
        #expect(DailyRunAllowance.remaining(runsToday: 0, isPro: false) == 3)
        #expect(DailyRunAllowance.remaining(runsToday: 10, isPro: false) == 0)
    }
}
