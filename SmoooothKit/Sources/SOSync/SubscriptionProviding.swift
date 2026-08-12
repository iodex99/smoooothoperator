/// Entitlement seam (spec §§8, 73): every Pro gate in the product keys off
/// this protocol. The iOS layer implements it with StoreKit 2 + the
/// server-verified subscriptions table; tests and previews use the fake.
/// The server independently re-checks entitlement on Pro-gated operations —
/// client state is for UX, never for authorization.
public protocol SubscriptionProviding: Sendable {
    /// Whether the user currently has an active Pro entitlement.
    func hasPro() async -> Bool
}

/// Deterministic fake for tests, previews, and development.
public struct FixedSubscriptionProvider: SubscriptionProviding {
    public let pro: Bool

    public init(pro: Bool) {
        self.pro = pro
    }

    public func hasPro() async -> Bool { pro }
}

/// What the free tier includes (spec §§8, 74): the free experience must be
/// genuinely valuable — gating rules live here, not scattered in views.
public enum ProGate: String, Codable, Sendable, CaseIterable {
    case unlimitedChallenges
    case customCourseCreation
    case advancedAnalytics
    case unlimitedGhostRacing
    case advancedFriendChallenges

    /// Free users get today's challenge, leaderboards, one ghost slot,
    /// friends, and joining shared courses — competing stays free.
    public static func requiresPro(_ gate: ProGate) -> Bool { true }
}
