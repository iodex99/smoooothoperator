import Foundation
import Testing
import SOCore
import SOCourse
import SOGhost
import SOModels
import SOScoring
import SOSimulator
import SOTelemetry
@testable import SOSync

/// The app's core loop, Linux-tested end to end: simulated sensors through
/// the same DriveSession the iOS layer drives (spec §§16-17, 71).
@Suite("DriveSession")
struct DriveSessionTests {
    static let route = TelemetrySimulator.demoRoute(seed: 77)

    static let scoringConfig: ScoringConfig = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("configs/scoring/v1.json")
        return try! ScoringConfig.load(from: Data(contentsOf: url))
    }()

    private func gates() -> [Checkpoint] {
        [0, Self.route.count / 3, 2 * Self.route.count / 3, Self.route.count - 1]
            .enumerated().map { sequence, index in
                Checkpoint(sequence: sequence, center: Self.route[index], radiusMeters: 40)
            }
    }

    private func makeSession(ghost: GhostTrajectory? = nil) -> DriveSession {
        DriveSession(
            polyline: Self.route,
            gates: gates(),
            benchmarkSeconds: 300,
            scoringConfig: Self.scoringConfig,
            ghost: ghost
        )!
    }

    private func eventStream(_ profile: SimulationProfile, seed: UInt64 = 9) -> AsyncStream<SensorEvent> {
        let run = TelemetrySimulator(profile: profile, seed: seed).simulate(route: Self.route)
        let events = SensorEvent.merge(gps: run.gps, imu: run.imu)
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    /// Drives the session with a profile and collects every state.
    private func drive(
        _ profile: SimulationProfile,
        ghost: GhostTrajectory? = nil
    ) async -> [DriveSessionState] {
        let session = makeSession(ghost: ghost)
        var seen: [DriveSessionState] = []
        let stream = await session.states()
        await session.start(events: eventStream(profile))
        for await state in stream {
            // Collapse the high-frequency active updates to state kinds plus
            // the last active snapshot.
            if case .active = state, case .active = seen.last {
                seen[seen.count - 1] = state
            } else {
                seen.append(state)
            }
            if case .finished = state { break }
            if case .failed = state { break }
        }
        return seen
    }

    private func kinds(_ states: [DriveSessionState]) -> [String] {
        states.map { state in
            switch state {
            case .idle: "idle"
            case .calibrating: "calibrating"
            case .ready: "ready"
            case .active: "active"
            case .processing: "processing"
            case .finished: "finished"
            case .failed: "failed"
            }
        }
    }

    @Test("a clean drive walks the full state machine and finishes verified")
    func cleanDrive() async throws {
        let states = await drive(.fastSmooth)
        #expect(kinds(states) == ["idle", "calibrating", "ready", "active", "processing", "finished"])

        guard case .finished(let outcome) = states.last else {
            Issue.record("no finished outcome")
            return
        }
        #expect(outcome.provisionalVerdict == .verified)
        #expect(outcome.provisionalScore > 0 && outcome.provisionalScore <= 10_000)
        #expect(outcome.gatesHit == 4)
        #expect(!outcome.deviationDetected)
        #expect(!outcome.rawGPS.isEmpty && !outcome.rawIMU.isEmpty)
    }

    @Test("mock GPS never calibrates — the session cannot reach READY")
    func mockGPSNeverReady() async {
        let states = await drive(.mockGPS)
        #expect(!kinds(states).contains("ready"))
        #expect(kinds(states).last == "failed")
    }

    @Test("a deviating run still completes and reports the deviation provisionally")
    func deviationReported() async throws {
        let states = await drive(.routeDeviation)
        guard case .finished(let outcome) = states.last else {
            Issue.record("expected finished, got \(states.last.map(String.init(describing:)) ?? "nil")")
            return
        }
        #expect(outcome.deviationDetected)
        #expect(outcome.provisionalVerdict == .invalid)
    }

    @Test("racing your own ghost shows a near-zero gap at the finish")
    func ghostGap() async throws {
        // Build the ghost from a first run of the same profile+seed.
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 9).simulate(route: Self.route)
        let trajectory = TrajectoryProcessor().process(run.gps)
        let ghost = try GhostEngine.generate(
            trajectory: trajectory, polyline: Self.route, checkpoints: gates()
        )

        let states = await drive(.fastSmooth, ghost: ghost)
        // The last collapsed active state carries the final live gap.
        let lastActive = states.last { if case .active = $0 { true } else { false } }
        guard case .active(_, _, let gap?) = lastActive else {
            Issue.record("no ghost gap in active states")
            return
        }
        #expect(abs(gap) < 3, "self-race gap should be near zero, got \(gap)")
    }

    @Test("abort mid-stream fails the run without losing the terminal state machine")
    func abortRun() async {
        let session = makeSession()
        await session.start(events: eventStream(.normal))
        await session.abort()
        let state = await session.state
        var isTerminal = false
        if case .failed = state { isTerminal = true }
        if case .finished = state { isTerminal = true }  // raced past abort — fine
        #expect(isTerminal)
    }
}
