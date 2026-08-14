import Foundation
import SOCore
import SOCourse
import SOGhost
import SOIntegrity
import SOModels
import SOScoring
import SOTelemetry

/// Session tuning knobs (spec §§16-17, 71).
public struct DriveSessionConfig: Sendable, Equatable {
    /// GPS fixes must be at least this fresh for READY, seconds.
    public var gpsFreshSeconds: Double
    /// Speed that turns READY into ACTIVE once the start gate is hit, m/s.
    public var startMovingSpeedMps: Double

    /// How long the session may sit waiting to start before it gives up.
    ///
    /// Without this the app is a memory leak with a countdown: parked on the
    /// ready screen it buffers IMU at 50 Hz — roughly 150 MB an hour — until
    /// iOS jetsams it. A driver who opens the app and then takes a phone
    /// call hits exactly that.
    public var maxWaitingSeconds: Double

    /// Hard ceiling on one run's duration. A run left running because the
    /// driver never reached the finish gate must end by itself.
    public var maxRunSeconds: Double

    /// Absolute ceiling on buffered samples, as a last line of defence for
    /// a sensor stream that misreports its own timestamps. Sized from the
    /// duration ceilings with generous headroom, not from a guess at memory.
    public var maxIMUSamples: Int
    public var maxGPSSamples: Int

    public init(
        gpsFreshSeconds: Double,
        startMovingSpeedMps: Double,
        maxWaitingSeconds: Double = 600,
        maxRunSeconds: Double = 7_200,
        maxIMUSamples: Int = 500_000,
        maxGPSSamples: Int = 100_000
    ) {
        self.gpsFreshSeconds = gpsFreshSeconds
        self.startMovingSpeedMps = startMovingSpeedMps
        self.maxWaitingSeconds = maxWaitingSeconds
        self.maxRunSeconds = maxRunSeconds
        self.maxIMUSamples = maxIMUSamples
        self.maxGPSSamples = maxGPSSamples
    }

    public static let `default` = DriveSessionConfig(
        gpsFreshSeconds: 3,
        startMovingSpeedMps: 1.5
    )
}

/// App-state machine of one challenge attempt (spec §71):
/// idle → calibrating → ready → active → processing → finished/failed.
public enum DriveSessionState: Sendable, Equatable {
    case idle
    case calibrating
    case ready
    /// Live status while driving — the ONLY data the driving screen shows
    /// (spec §17: minimal display, no dashboards).
    case active(progressFraction: Double, elapsedSeconds: Double, ghostGapSeconds: Double?)
    case processing
    case finished(DriveRunOutcome)
    case failed(reason: String)
}

/// The provisional client-side result plus everything the upload needs.
/// The server recomputes all of it authoritatively (spec §46).
public struct DriveRunOutcome: Codable, Sendable, Equatable {
    public var provisionalScore: Int
    public var provisionalVerdict: RunVerificationStatus
    public var breakdown: ScoreBreakdown
    public var confidenceScore: Int
    public var durationSeconds: Double
    public var distanceMeters: Double
    public var gatesHit: Int
    public var deviationDetected: Bool
    /// Why the verdict is what it is, as stable flag strings. The UI needs
    /// this to tell a driver something they can act on ("roll up slowly")
    /// rather than a bare "not ranked".
    public var integrityFlags: [String] = []
    /// Raw samples for the telemetry upload — never mutated by processing.
    public var rawGPS: [GPSSample]
    public var rawIMU: [IMUSample]
}

/// Orchestrates one drive: consumes the unified sensor stream, calibrates
/// orientation, gates course progress live, and runs the evaluation
/// pipeline at the finish. Pure Kit logic — the iOS layer only feeds the
/// stream and renders states (ADR-0001).
public actor DriveSession {
    private let polyline: [GeoCoordinate]
    private let gates: [Checkpoint]
    private let benchmarkSeconds: Double
    private let scoringConfig: ScoringConfig
    private let ghost: GhostTrajectory?
    private let config: DriveSessionConfig

    private var estimator = VehicleOrientationEstimator()
    private var tracker: CourseProgressTracker
    private var rawGPS: [GPSSample] = []
    private var rawIMU: [IMUSample] = []
    private var startTime: Double?
    private var firstEventTime: Double?
    private var consumeTask: Task<Void, Never>?
    /// Writes the drive to disk as it happens, so a mid-run crash does not
    /// destroy it. Optional: a session with no recorder still works, which
    /// is what every existing test relies on.
    private var recorder: InFlightRecorder?

    private var stateValue: DriveSessionState = .idle
    private var continuations: [UUID: AsyncStream<DriveSessionState>.Continuation] = [:]

    public init?(
        polyline: [GeoCoordinate],
        gates: [Checkpoint],
        benchmarkSeconds: Double,
        scoringConfig: ScoringConfig,
        ghost: GhostTrajectory? = nil,
        config: DriveSessionConfig = .default
    ) {
        guard let tracker = CourseProgressTracker(polyline: polyline, checkpoints: gates) else {
            return nil
        }
        self.polyline = polyline
        self.gates = gates
        self.benchmarkSeconds = benchmarkSeconds
        self.scoringConfig = scoringConfig
        self.ghost = ghost
        self.config = config
        self.tracker = tracker
    }

    public var state: DriveSessionState { stateValue }

    /// How many raw samples the session is currently holding. Exists so a
    /// test can prove the buffers are actually released when a ceiling is
    /// hit — the leak this guards against is invisible from the state alone.
    public var bufferedSampleCount: Int { rawGPS.count + rawIMU.count }

    /// Attach a crash-safe recorder. Separate from `init` so the recorder
    /// can be created asynchronously and so a failure to open the file never
    /// prevents a drive — a run recorded only in memory is far better than
    /// no run at all.
    public func attach(recorder: InFlightRecorder) {
        self.recorder = recorder
    }

    /// Every state change, including the current state immediately.
    public func states() -> AsyncStream<DriveSessionState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(stateValue)
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func transition(to newState: DriveSessionState) {
        stateValue = newState
        for continuation in continuations.values {
            continuation.yield(newState)
        }
    }

    /// Starts consuming the sensor stream. Call once.
    public func start(events: AsyncStream<SensorEvent>) {
        guard case .idle = stateValue else { return }
        transition(to: .calibrating)
        consumeTask = Task {
            for await event in events {
                if Task.isCancelled { return }
                await self.handle(event)
                if await self.isTerminal { break }
            }
            await self.streamEnded()
        }
    }

    /// Abandons the run (user stop, phone call bailout, …).
    public func abort() {
        consumeTask?.cancel()
        if !isTerminal {
            transition(to: .failed(reason: "aborted"))
        }
    }

    private var isTerminal: Bool {
        switch stateValue {
        case .finished, .failed: true
        default: false
        }
    }

    // MARK: - Event handling

    private func handle(_ event: SensorEvent) async {
        if enforceLimits(at: event.timestamp) { return }
        switch event {
        case .imu(let sample):
            estimator.ingest(imu: sample)
            rawIMU.append(sample)
            if let recorder { Task { await recorder.record(imu: sample) } }
        case .gps(let sample):
            estimator.ingest(gps: sample)
            rawGPS.append(sample)
            if let recorder { Task { await recorder.record(gps: sample) } }
            handleFix(sample)
        }
    }

    /// Ends the session rather than growing without bound. Returns true when
    /// the session has stopped and the event should be dropped.
    ///
    /// Three separate ceilings because they fail differently: waiting too
    /// long is a driver who wandered off, running too long is a run that
    /// never reached its finish gate, and the sample caps catch a stream
    /// whose timestamps lie about how much time has passed.
    private func enforceLimits(at timestamp: Double) -> Bool {
        if firstEventTime == nil { firstEventTime = timestamp }

        switch stateValue {
        case .calibrating, .ready:
            if let first = firstEventTime, timestamp - first > config.maxWaitingSeconds {
                stop(reason: "no run started — the session timed out waiting")
                return true
            }
        case .active:
            if let start = startTime, timestamp - start > config.maxRunSeconds {
                stop(reason: "run exceeded the maximum length")
                return true
            }
        default:
            break
        }

        if rawIMU.count >= config.maxIMUSamples || rawGPS.count >= config.maxGPSSamples {
            stop(reason: "sensor buffer limit reached")
            return true
        }
        return false
    }

    /// Ends the session and releases the buffers. Nothing is recoverable
    /// from a session that hit a limit, and holding tens of megabytes after
    /// giving up is the bug this exists to prevent.
    private func stop(reason: String) {
        consumeTask?.cancel()
        rawGPS.removeAll(keepingCapacity: false)
        rawIMU.removeAll(keepingCapacity: false)
        if let recorder { Task { await recorder.discard() } }
        transition(to: .failed(reason: reason))
    }

    private func handleFix(_ sample: GPSSample) {
        // Live tracking uses the fix directly; the full batch pipeline
        // re-derives everything from raw samples at the finish.
        tracker.ingest(TrajectoryPoint(
            timestamp: sample.timestamp,
            coordinate: sample.coordinate,
            speedMps: max(0, sample.speed ?? 0),
            headingDegrees: sample.course,
            distanceAlongPathMeters: 0,
            horizontalAccuracy: sample.horizontalAccuracy
        ))

        switch stateValue {
        case .calibrating:
            if estimator.estimate != nil {
                transition(to: .ready)
            }
        case .ready:
            if tracker.checkpointHits.contains(where: { $0.sequence == 0 }),
               (sample.speed ?? 0) > config.startMovingSpeedMps {
                startTime = sample.timestamp
                transition(to: activeState(at: sample.timestamp))
            }
        case .active:
            if tracker.hasFinished {
                transition(to: .processing)
                finishRun()
            } else {
                transition(to: activeState(at: sample.timestamp))
            }
        default:
            break
        }
    }

    private func activeState(at timestamp: Double) -> DriveSessionState {
        let elapsed = timestamp - (startTime ?? timestamp)
        let progress = tracker.progressFraction
        let gap = ghost.map {
            GhostEngine.gapSeconds(elapsedSeconds: elapsed, progress: progress, against: $0)
        }
        return .active(
            progressFraction: progress,
            elapsedSeconds: elapsed,
            ghostGapSeconds: gap
        )
    }

    private func finishRun() {
        guard let outcome = RunEvaluationPipeline.evaluate(
            gps: rawGPS,
            imu: rawIMU,
            route: polyline,
            gates: gates,
            benchmarkSeconds: benchmarkSeconds,
            scoringConfig: scoringConfig
        ) else {
            transition(to: .failed(reason: "processing failed"))
            return
        }
        if let recorder { Task { await recorder.finish() } }
        transition(to: .finished(DriveRunOutcome(
            provisionalScore: outcome.score.finalScore,
            provisionalVerdict: outcome.integrity.verdict,
            breakdown: outcome.score.breakdown,
            confidenceScore: outcome.confidence.score,
            durationSeconds: outcome.trajectory.duration,
            distanceMeters: outcome.trajectory.totalDistanceMeters,
            gatesHit: outcome.gatesHit,
            deviationDetected: outcome.deviationDetected,
            integrityFlags: Set(outcome.integrity.findings.map(\.flag.rawValue)).sorted(),
            rawGPS: rawGPS,
            rawIMU: rawIMU
        )))
    }

    private func streamEnded() {
        guard !isTerminal else { return }
        switch stateValue {
        case .idle, .calibrating, .ready:
            transition(to: .failed(reason: "sensor stream ended before the run started"))
        case .active:
            transition(to: .failed(reason: "sensor stream ended mid-run"))
        case .processing:
            break  // finishRun already transitioning
        case .finished, .failed:
            break
        }
    }
}
