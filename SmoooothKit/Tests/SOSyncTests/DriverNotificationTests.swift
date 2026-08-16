import Foundation
import Testing
@testable import SOSync

/// The rules that decide whether a driver's phone buzzes. The one that
/// matters most is the one that says nothing at all.
@Suite("Notification policy")
struct DriverNotificationTests {
    private func context(
        driving: Bool = false,
        authorized: Bool = true,
        hour: Int = 14,
        sentToday: Int = 0,
        sinceLast: Double? = nil
    ) -> NotificationContext {
        NotificationContext(
            isDriving: driving,
            isAuthorized: authorized,
            localHour: hour,
            sentToday: sentToday,
            secondsSinceLastSent: sinceLast
        )
    }

    // ── the rule the product exists to respect ───────────────────────────

    @Test("nothing is ever sent while a drive is in progress")
    func nothingWhileDriving() {
        // Every kind, including the urgent one, including inside a perfectly
        // reasonable hour with no other reason to hold back.
        let all: [DriverNotification] = [
            .runScored(courseName: "Stelvio", score: 9100),
            .runsWaitingToUpload(count: 3),
            .todaysChallengeReady(courseName: "Hardknott"),
            .recordBeaten(courseName: "Bealach na Bà", byUsername: "ana"),
        ]
        for n in all {
            #expect(
                NotificationGatekeeper.decide(n, context: context(driving: true))
                    == .suppress(.driving),
                "\(n.identifier) must not interrupt someone at the wheel"
            )
        }
    }

    @Test("driving beats urgency, permission and everything else")
    func drivingIsCheckedFirst() {
        // Deliberately stacks every other reason to send: authorised, urgent,
        // midday, nothing sent yet. Only the wheel matters.
        let decision = NotificationGatekeeper.decide(
            .runScored(courseName: "Transfăgărășan", score: 9500),
            context: context(driving: true, authorized: true, hour: 12, sentToday: 0)
        )
        #expect(decision == .suppress(.driving))
    }

    // ── permission ───────────────────────────────────────────────────────

    @Test("nothing is sent without permission")
    func requiresAuthorization() {
        #expect(
            NotificationGatekeeper.decide(
                .runScored(courseName: "Gavia", score: 8000),
                context: context(authorized: false)
            ) == .suppress(.notAuthorized)
        )
    }

    // ── quiet hours, including the window that wraps midnight ────────────

    @Test("the quiet window wraps midnight correctly", arguments: [
        (22, true), (23, true), (0, true), (3, true), (7, true),
        (8, false), (12, false), (20, false), (21, true),
    ])
    func quietHoursWrap(hour: Int, expectedQuiet: Bool) {
        // 21:00 → 08:00. The naive `start < h && h < end` test gets every
        // evening hour wrong, which is why this is asserted hour by hour.
        #expect(
            NotificationGatekeeper.isQuiet(hour: hour, policy: .default) == expectedQuiet,
            "hour \(hour)"
        )
    }

    @Test("a routine notification waits for morning")
    func routineWaitsOutQuietHours() {
        #expect(
            NotificationGatekeeper.decide(
                .recordBeaten(courseName: "Cat and Fiddle", byUsername: "sam"),
                context: context(hour: 23)
            ) == .suppress(.quietHours)
        )
    }

    @Test("a finished score still arrives at 23:00 — it is what they are waiting for")
    func timeSensitiveCrossesQuietHours() {
        #expect(
            NotificationGatekeeper.decide(
                .runScored(courseName: "Applecross", score: 8800),
                context: context(hour: 23)
            ) == .send
        )
    }

    // ── ceilings ─────────────────────────────────────────────────────────

    @Test("the daily ceiling holds even for the urgent kind")
    func dailyCeilingIsAbsolute() {
        // "This one is important" is how every app ends up sending nine.
        #expect(
            NotificationGatekeeper.decide(
                .runScored(courseName: "Nürburgring", score: 9000),
                context: context(sentToday: 3)
            ) == .suppress(.dailyLimitReached)
        )
    }

    @Test("two routine things happening at once do not arrive as two buzzes")
    func spacingSuppressesRoutine() {
        #expect(
            NotificationGatekeeper.decide(
                .recordBeaten(courseName: "Evo Triangle", byUsername: "kit"),
                context: context(sinceLast: 60)
            ) == .suppress(.tooSoonAfterLast)
        )
    }

    @Test("but a score is not held back by spacing")
    func spacingDoesNotHoldBackScores() {
        #expect(
            NotificationGatekeeper.decide(
                .runScored(courseName: "Furka", score: 8600),
                context: context(sinceLast: 60)
            ) == .send
        )
    }

    // ── identity: replace, never stack ───────────────────────────────────

    @Test("nine unsent runs is one notification saying nine, not nine notifications")
    func upsertsRatherThanStacks() async {
        let scheduler = RecordingNotificationScheduler()
        await scheduler.schedule(.runsWaitingToUpload(count: 1), after: 0)
        await scheduler.schedule(.runsWaitingToUpload(count: 4), after: 0)
        await scheduler.schedule(.runsWaitingToUpload(count: 9), after: 0)

        let pending = await scheduler.scheduled
        #expect(pending.count == 1)
        #expect(pending.first?.notification == .runsWaitingToUpload(count: 9))
    }

    @Test("per-course notifications are separate, per-app ones are not")
    func identityIsScopedCorrectly() {
        // Two different courses being beaten are two different facts.
        #expect(
            DriverNotification.recordBeaten(courseName: "A", byUsername: "x").identifier
            != DriverNotification.recordBeaten(courseName: "B", byUsername: "x").identifier
        )
        // The same course beaten twice replaces itself.
        #expect(
            DriverNotification.recordBeaten(courseName: "A", byUsername: "x").identifier
            == DriverNotification.recordBeaten(courseName: "A", byUsername: "y").identifier
        )
        // "Runs waiting" is one fact about the phone, whatever the count.
        #expect(
            DriverNotification.runsWaitingToUpload(count: 1).identifier
            == DriverNotification.runsWaitingToUpload(count: 9).identifier
        )
    }

    @Test("a notification that stopped being true can be withdrawn")
    func cancellingRemovesPending() async {
        let scheduler = RecordingNotificationScheduler()
        await scheduler.schedule(.runsWaitingToUpload(count: 2), after: 0)
        await scheduler.cancel(identifier: DriverNotification.runsWaitingToUpload(count: 2).identifier)

        let pending = await scheduler.scheduled
        #expect(pending.isEmpty, "an upload that has since succeeded must stop nagging")
    }

    // ── the words on the lock screen ─────────────────────────────────────

    @Test("the copy says the true thing, singular and plural")
    func copyReadsCorrectly() {
        #expect(DriverNotification.runsWaitingToUpload(count: 1).body.hasPrefix("One drive"))
        #expect(DriverNotification.runsWaitingToUpload(count: 4).body.hasPrefix("4 drives"))
        #expect(
            DriverNotification.runScored(courseName: "Stelvio", score: 9100).body
                == "9100 on Stelvio."
        )
    }

    @Test("only the score is treated as time-sensitive")
    func onlyScoresAreUrgent() {
        #expect(DriverNotification.runScored(courseName: "x", score: 1).isTimeSensitive)
        #expect(!DriverNotification.runsWaitingToUpload(count: 1).isTimeSensitive)
        #expect(!DriverNotification.todaysChallengeReady(courseName: "x").isTimeSensitive)
        #expect(!DriverNotification.recordBeaten(courseName: "x", byUsername: "y").isTimeSensitive)
    }
}
