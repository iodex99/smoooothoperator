import Testing
@testable import SOGhost

/// The ghost's POSITION over time — what puts a rival's pin on the drive map
/// next to your own, instead of only a gap in seconds.
@Suite("Ghost position")
struct GhostPositionTests {
    /// A ghost that covers the course at a steady pace in 100 seconds.
    private let steady = GhostTrajectory(
        points: (0...10).map {
            GhostPoint(progress: Double($0) / 10, elapsedSeconds: Double($0) * 10)
        },
        totalSeconds: 100
    )

    @Test("position interpolates between stored points")
    func interpolates() {
        #expect(steady.progress(atElapsed: 50) == 0.5)
        #expect(abs(steady.progress(atElapsed: 25) - 0.25) < 1e-9)
    }

    @Test("before the start the ghost waits at the line")
    func clampsAtStart() {
        #expect(steady.progress(atElapsed: -10) == 0)
        #expect(steady.progress(atElapsed: 0) == 0)
    }

    @Test("after finishing the ghost stays at the finish, never past it")
    func clampsAtFinish() {
        #expect(steady.progress(atElapsed: 100) == 1)
        #expect(steady.progress(atElapsed: 10_000) == 1)
    }

    @Test("position and elapsed are inverses of each other")
    func roundTrip() {
        for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
            let elapsed = steady.elapsedSeconds(atProgress: fraction)
            #expect(abs(steady.progress(atElapsed: elapsed) - fraction) < 1e-9)
        }
    }

    @Test("an empty ghost reports the start rather than crashing")
    func emptyGhostIsSafe() {
        let empty = GhostTrajectory(points: [], totalSeconds: 0)
        #expect(empty.progress(atElapsed: 42) == 0)
    }

    @Test("a stalled ghost (no time passing) doesn't divide by zero")
    func stalledSegment() {
        let stalled = GhostTrajectory(
            points: [
                GhostPoint(progress: 0, elapsedSeconds: 0),
                GhostPoint(progress: 0.5, elapsedSeconds: 10),
                GhostPoint(progress: 0.9, elapsedSeconds: 10),
                GhostPoint(progress: 1, elapsedSeconds: 20),
            ],
            totalSeconds: 20
        )
        let at10 = stalled.progress(atElapsed: 10)
        #expect(at10.isFinite)
        #expect(at10 >= 0.5 && at10 <= 0.9)
    }
}
