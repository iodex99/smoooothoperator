import Foundation

/// The free tier's one real limit (spec §§8, 74).
///
/// Everything that makes the app worth using stays free — today's challenge,
/// leaderboards, friends, verification, ghosts of your own runs. What Pro
/// buys is *volume*: free drivers get a few scored runs a day, which is more
/// than a commuting driver needs and less than a leaderboard grinder wants.
///
/// This lives in the Kit so the rule is one testable fact rather than an
/// `if` scattered through views, and so the server can enforce the identical
/// rule later without a second definition.
public enum DailyRunAllowance {
    public static let freeRunsPerDay = 3

    public static func allows(runsToday: Int, isPro: Bool) -> Bool {
        isPro || runsToday < freeRunsPerDay
    }

    /// Runs left today; nil means unlimited (Pro).
    public static func remaining(runsToday: Int, isPro: Bool) -> Int? {
        isPro ? nil : max(0, freeRunsPerDay - runsToday)
    }
}
