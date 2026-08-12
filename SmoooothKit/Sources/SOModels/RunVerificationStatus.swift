/// Verification outcome of a run after integrity + confidence evaluation.
///
/// Only `.verified` runs enter competitive leaderboards. `.questionable`
/// runs are kept (the user sees their result) but rank nowhere — the tier
/// exists so uncertain data never accuses anyone of cheating.
/// Raw values are persisted in the database and in golden fixtures — never change them.
public enum RunVerificationStatus: String, Codable, Sendable, CaseIterable {
    case verified
    case questionable
    case invalid
}
