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
    ///
    /// Every case of `ProGate` is, by construction, a thing behind the
    /// paywall; the free features above are simply not gates. This returned
    /// a bare `true` while nothing called it, which reads as a stub and is
    /// a trap: whoever wired it up would get the right answer for the wrong
    /// reason and never notice if a free feature were added to the enum.
    ///
    /// `@unknown`-style exhaustiveness is the point — adding a case forces
    /// a decision here rather than defaulting it to paid.
    public static func requiresPro(_ gate: ProGate) -> Bool {
        switch gate {
        case .unlimitedChallenges,
             .customCourseCreation,
             .advancedAnalytics,
             .unlimitedGhostRacing,
             .advancedFriendChallenges:
            true
        }
    }
}
