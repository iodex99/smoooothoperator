/// State of a completed run in the offline-first upload queue.
///
/// A finished run must never be lost to connectivity (spec §60): it persists
/// locally in `.pending` and only leaves the queue after the server has
/// acknowledged both the telemetry blob and the run row.
public enum UploadState: String, Codable, Sendable, CaseIterable {
    case pending
    case uploading
    case uploaded
    case failed

    /// Legal state-machine transitions. Anything else is a programmer error
    /// and is rejected by the queue.
    public var allowedTransitions: Set<UploadState> {
        switch self {
        case .pending: [.uploading]
        case .uploading: [.uploaded, .failed]
        case .failed: [.uploading]  // retry
        case .uploaded: []          // terminal
        }
    }

    public func canTransition(to next: UploadState) -> Bool {
        allowedTransitions.contains(next)
    }
}
