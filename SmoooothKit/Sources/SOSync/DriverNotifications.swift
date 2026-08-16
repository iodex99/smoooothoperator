import Foundation

/// Notifications, and the rules about when NOT to send one.
///
/// This is a driving app. The single most important thing here is not what
/// gets sent — it is that nothing arrives while somebody is driving. A banner
/// on a hairpin is not a notification, it is a hazard, and no engagement
/// metric is worth it.
///
/// Everything in this file is platform-independent and Linux-tested. The iOS
/// layer supplies a `NotificationScheduling` that talks to
/// UNUserNotificationCenter; the decision about whether to schedule at all is
/// made here, where it can be proven.
///
/// REMOTE PUSH IS NOT HERE, and cannot be yet: APNs needs an Apple Developer
/// account for its signing key and the `aps-environment` entitlement, and
/// there is no account. The seam is shaped so the transport can be swapped
/// without the policy moving — the same way `SubscriptionProviding` is shaped.

// ── what the product may say ─────────────────────────────────────────────

public enum DriverNotification: Sendable, Equatable, Hashable {
    /// The server finished scoring a run. The one notification a driver is
    /// actually waiting for: scoring is asynchronous, so without this they
    /// have to keep opening the app to find out.
    case runScored(courseName: String, score: Int)

    /// Drives recorded on this phone that have not reached the server. The
    /// app knows this without being told by anyone.
    case runsWaitingToUpload(count: Int)

    /// Today's challenge has been chosen and is drivable.
    case todaysChallengeReady(courseName: String)

    /// Somebody took a record. The competitive hook — and the one most
    /// easily overdone, which is why the policy below rate-limits it.
    case recordBeaten(courseName: String, byUsername: String)

    /// Stable identity. Scheduling the same identity twice REPLACES rather
    /// than stacks, so a driver with nine unsent runs gets one notification
    /// that says nine, not nine notifications.
    public var identifier: String {
        switch self {
        case .runScored(let course, _):        return "run-scored:\(course)"
        case .runsWaitingToUpload:             return "runs-waiting"
        case .todaysChallengeReady:            return "todays-challenge"
        case .recordBeaten(let course, _):     return "record-beaten:\(course)"
        }
    }

    public var title: String {
        switch self {
        case .runScored:            return "Your run is scored"
        case .runsWaitingToUpload:  return "Runs still on this phone"
        case .todaysChallengeReady: return "Today's Challenge is ready"
        case .recordBeaten:         return "Your record went"
        }
    }

    /// Written to be readable on a lock screen at a glance, and to be honest:
    /// no false urgency, no invented achievement.
    public var body: String {
        switch self {
        case .runScored(let course, let score):
            return "\(score) on \(course)."
        case .runsWaitingToUpload(let count):
            return count == 1
                ? "One drive hasn't uploaded yet. Open the app on Wi-Fi and it goes."
                : "\(count) drives haven't uploaded yet. Open the app on Wi-Fi and they go."
        case .todaysChallengeReady(let course):
            return "\(course) is today's course."
        case .recordBeaten(let course, let username):
            return "\(username) beat your time on \(course)."
        }
    }

    /// Whether this one is worth interrupting somebody for at all. A record
    /// being beaten can wait for the app to be opened; a run finishing
    /// scoring is the thing they are waiting on.
    public var isTimeSensitive: Bool {
        switch self {
        case .runScored:            return true
        case .runsWaitingToUpload:  return false
        case .todaysChallengeReady: return false
        case .recordBeaten:         return false
        }
    }
}

// ── the transport, so the policy can be tested without one ───────────────

public protocol NotificationScheduling: Sendable {
    /// Whether the driver has allowed notifications at all.
    func isAuthorized() async -> Bool
    /// Ask, once. Returns what the driver chose.
    func requestAuthorization() async -> Bool
    /// Deliver, replacing any pending notification with the same identifier.
    func schedule(_ notification: DriverNotification, after seconds: Double) async
    /// Withdraw one that is no longer true — an upload that has since
    /// succeeded must not still be nagging about itself.
    func cancel(identifier: String) async
}

/// Deterministic fake for tests, previews and development.
public actor RecordingNotificationScheduler: NotificationScheduling {
    public private(set) var scheduled: [(notification: DriverNotification, delay: Double)] = []
    public private(set) var cancelled: [String] = []
    public private(set) var authorizationRequests = 0
    private var authorized: Bool

    public init(authorized: Bool = true) {
        self.authorized = authorized
    }

    public func isAuthorized() async -> Bool { authorized }

    public func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return authorized
    }

    public func schedule(_ notification: DriverNotification, after seconds: Double) async {
        // Mirrors the real behaviour: same identifier replaces.
        scheduled.removeAll { $0.notification.identifier == notification.identifier }
        scheduled.append((notification, seconds))
    }

    public func cancel(identifier: String) async {
        cancelled.append(identifier)
        scheduled.removeAll { $0.notification.identifier == identifier }
    }

    public func setAuthorized(_ value: Bool) { authorized = value }
}

// ── when NOT to send ─────────────────────────────────────────────────────

public struct NotificationPolicy: Sendable, Equatable {
    /// Local hour (0-23) after which nothing is sent until `quietEndHour`.
    public var quietStartHour: Int
    public var quietEndHour: Int
    /// Hard ceiling per local day, across all kinds.
    public var maxPerDay: Int
    /// Minimum spacing, so two things happening at once do not arrive as two
    /// buzzes a second apart.
    public var minimumGapSeconds: Double

    public init(
        quietStartHour: Int = 21,
        quietEndHour: Int = 8,
        maxPerDay: Int = 3,
        minimumGapSeconds: Double = 1800
    ) {
        self.quietStartHour = quietStartHour
        self.quietEndHour = quietEndHour
        self.maxPerDay = maxPerDay
        self.minimumGapSeconds = minimumGapSeconds
    }

    public static let `default` = NotificationPolicy()
}

public enum NotificationSuppression: Sendable, Equatable {
    /// A drive is in progress. Non-negotiable and checked first.
    case driving
    case notAuthorized
    case quietHours
    case dailyLimitReached
    case tooSoonAfterLast
}

public enum NotificationDecision: Sendable, Equatable {
    case send
    case suppress(NotificationSuppression)

    public var isSend: Bool { self == .send }
}

/// The state a decision is made against. Passed in rather than read from
/// globals so every rule below is reproducible in a test.
public struct NotificationContext: Sendable {
    public var isDriving: Bool
    public var isAuthorized: Bool
    /// Local hour 0-23 where the driver is, not UTC — a quiet-hours rule in
    /// the wrong timezone is worse than no rule.
    public var localHour: Int
    public var sentToday: Int
    public var secondsSinceLastSent: Double?

    public init(
        isDriving: Bool,
        isAuthorized: Bool,
        localHour: Int,
        sentToday: Int,
        secondsSinceLastSent: Double?
    ) {
        self.isDriving = isDriving
        self.isAuthorized = isAuthorized
        self.localHour = localHour
        self.sentToday = sentToday
        self.secondsSinceLastSent = secondsSinceLastSent
    }
}

public enum NotificationGatekeeper {
    /// Order matters and is deliberate: safety first, permission second,
    /// then courtesy. A time-sensitive notification may cross quiet hours
    /// and the spacing rule — a finished score at 22:00 is what the driver
    /// is waiting for — but NOTHING crosses `driving`, and nothing crosses
    /// the daily ceiling.
    public static func decide(
        _ notification: DriverNotification,
        policy: NotificationPolicy = .default,
        context: NotificationContext
    ) -> NotificationDecision {
        // 1. Never while moving. This app exists because of what happens on
        //    a road at speed; a banner is a hazard, not a feature.
        if context.isDriving { return .suppress(.driving) }

        if !context.isAuthorized { return .suppress(.notAuthorized) }

        // 2. A hard ceiling that even urgency does not lift, because "this
        //    one is important" is how every app ends up sending nine.
        if context.sentToday >= policy.maxPerDay { return .suppress(.dailyLimitReached) }

        if !notification.isTimeSensitive {
            if isQuiet(hour: context.localHour, policy: policy) {
                return .suppress(.quietHours)
            }
            if let since = context.secondsSinceLastSent, since < policy.minimumGapSeconds {
                return .suppress(.tooSoonAfterLast)
            }
        }

        return .send
    }

    /// Handles a window that wraps midnight (21:00 → 08:00), which the
    /// obvious `start < hour && hour < end` gets wrong for every evening.
    public static func isQuiet(hour: Int, policy: NotificationPolicy) -> Bool {
        if policy.quietStartHour == policy.quietEndHour { return false }
        if policy.quietStartHour < policy.quietEndHour {
            return hour >= policy.quietStartHour && hour < policy.quietEndHour
        }
        return hour >= policy.quietStartHour || hour < policy.quietEndHour
    }
}
