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
    /// How far the car must move past the start gate before the clock
    /// starts, in metres.
    ///
    /// This used to be a speed threshold, and the ghost clock used the same
    /// threshold against a *smoothed* speed while this one used the device's
    /// reported speed. Filtered derivatives lag, so the two clocks started
    /// at different instants and a driver racing their own best run was
    /// shown ~2.6 s ahead of themselves. Both sides now call
    /// `GhostEngine.startTime` with this distance.
    public var startMovingMeters: Double

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
        startMovingMeters: Double,
        maxWaitingSeconds: Double = 600,
        maxRunSeconds: Double = 7_200,
        maxIMUSamples: Int = 500_000,
        maxGPSSamples: Int = 100_000
    ) {
        self.gpsFreshSeconds = gpsFreshSeconds
        self.startMovingMeters = startMovingMeters
        self.maxWaitingSeconds = maxWaitingSeconds
        self.maxRunSeconds = maxRunSeconds
        self.maxIMUSamples = maxIMUSamples
        self.maxGPSSamples = maxGPSSamples
    }

    public static let `default` = DriveSessionConfig(
        gpsFreshSeconds: 3,
        startMovingMeters: 5
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

    /// The memberwise initialiser, spelled out. Declaring the one below
    /// suppresses the synthesised version, and fixtures need to build an
    /// outcome from specific numbers rather than a real evaluation.
    public init(
        provisionalScore: Int,
        provisionalVerdict: RunVerificationStatus,
        breakdown: ScoreBreakdown,
        confidenceScore: Int,
        durationSeconds: Double,
        distanceMeters: Double,
        gatesHit: Int,
        deviationDetected: Bool,
        integrityFlags: [String] = [],
        rawGPS: [GPSSample],
        rawIMU: [IMUSample]
    ) {
        self.provisionalScore = provisionalScore
        self.provisionalVerdict = provisionalVerdict
        self.breakdown = breakdown
        self.confidenceScore = confidenceScore
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.gatesHit = gatesHit
        self.deviationDetected = deviationDetected
        self.integrityFlags = integrityFlags
        self.rawGPS = rawGPS
        self.rawIMU = rawIMU
    }

    /// Builds the outcome from a pipeline result.
    ///
    /// Public and shared on purpose. A finished live drive and a drive
    /// recovered from a crash journal produce the same thing, and the App
    /// layer needs to build one too. When that mapping was copied by hand
    /// in a second place, the two drifted immediately — and a field added
    /// here would have gone silently missing from recovered runs.
    public init(evaluation: PipelineOutcome, rawGPS: [GPSSample], rawIMU: [IMUSample]) {
        self.provisionalScore = evaluation.score.finalScore
        self.provisionalVerdict = evaluation.integrity.verdict
        self.breakdown = evaluation.score.breakdown
        self.confidenceScore = evaluation.confidence.score
        self.durationSeconds = evaluation.trajectory.duration
        self.distanceMeters = evaluation.trajectory.totalDistanceMeters
        self.gatesHit = evaluation.gatesHit
        self.deviationDetected = evaluation.deviationDetected
        self.integrityFlags = Set(evaluation.integrity.findings.map(\.flag.rawValue)).sorted()
        self.rawGPS = rawGPS
        self.rawIMU = rawIMU
    }
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
    /// Where the car was when it crossed the start gate. The clock starts
    /// once it is `startMovingMeters` from here — see DriveSessionConfig.
    private var gateCrossingCoordinate: GeoCoordinate?
    private var consumeTask: Task<Void, Never>?
    /// Writes the drive to disk as it happens, so a mid-run crash does not
    /// destroy it. Optional: a session with no recorder still works, which
    /// is what every existing test relies on.
    private var recorder: InFlightRecorder?
    /// Samples waiting to be journalled.
    ///
    /// The first version spawned `Task { await recorder.record(…) }` per
    /// sample. Actor calls made from independent Tasks have NO ordering
    /// guarantee, so at 50 Hz that was thousands of concurrent tasks racing
    /// to append — a recovered file could hold samples in the wrong order,
    /// which is worse than no file at all. The session is already an actor,
    /// so buffering here is serialised for free.
    private var journalGPS: [GPSSample] = []
    private var journalIMU: [IMUSample] = []
    private var journalTask: Task<Void, Never>?

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
    public func abort() async {
        consumeTask?.cancel()
        // An aborted run is not recoverable — leaving the journal behind
        // would offer it back on next launch as a drive worth keeping.
        journalGPS.removeAll()
        journalIMU.removeAll()
        journalTask?.cancel()
        if let recorder { await recorder.discard() }
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
            journalIMU.append(sample)
        case .gps(let sample):
            estimator.ingest(gps: sample)
            rawGPS.append(sample)
            journalGPS.append(sample)
            flushJournalIfNeeded()
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

    /// Hands whatever has accumulated to the recorder, in order, as one
    /// batch. Chained off the previous write so two flushes can never
    /// interleave.
    private func flushJournalIfNeeded(force: Bool = false) {
        guard let recorder else { return }
        guard force || journalGPS.count + journalIMU.count >= 50 else { return }
        let gps = journalGPS, imu = journalIMU
        journalGPS.removeAll(keepingCapacity: true)
        journalIMU.removeAll(keepingCapacity: true)
        guard !gps.isEmpty || !imu.isEmpty else { return }
        let previous = journalTask
        journalTask = Task {
            await previous?.value
            await recorder.record(gps: gps, imu: imu)
        }
    }

    /// Waits for every queued write to land. Used before the journal is
    /// handed over or thrown away, so nothing is still in flight.
    private func drainJournal() async {
        flushJournalIfNeeded(force: true)
        await journalTask?.value
    }

    /// Ends the session and releases the buffers. Nothing is recoverable
    /// from a session that hit a limit, and holding tens of megabytes after
    /// giving up is the bug this exists to prevent.
    private func stop(reason: String) {
        consumeTask?.cancel()
        rawGPS.removeAll(keepingCapacity: false)
        rawIMU.removeAll(keepingCapacity: false)
        journalGPS.removeAll()
        journalIMU.removeAll()
        journalTask?.cancel()
        if let recorder {
            Task { await recorder.discard() }
        }
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
            // Exactly the rule ghost generation uses: the clock starts on the
            // FIRST fix that is `startMovingMeters` from where the car
            // crossed the start gate. Samples arrive in order, so the first
            // one to satisfy it is this one — which makes this transition
            // identical to `GhostEngine.startTime` rather than merely similar.
            guard let hit = tracker.checkpointHits.first(where: { $0.sequence == 0 })
            else { break }
            // The origin is the fix AT the gate crossing — looked up in the
            // raw buffer, not "wherever we happened to be when READY
            // arrived". The car can cross the gate while the orientation
            // estimator is still converging, in which case READY comes late
            // and using the current fix put the origin 13.5 m down the road.
            if gateCrossingCoordinate == nil {
                gateCrossingCoordinate = rawGPS
                    .first(where: { $0.timestamp >= hit.timestamp })?.coordinate
            }
            if let origin = gateCrossingCoordinate,
               origin.distance(to: sample.coordinate) >= config.startMovingMeters {
                // The anchor is the FIRST fix that cleared the threshold,
                // found across the whole buffer — not this one. READY can
                // arrive several fixes late (the orientation estimator has
                // to converge first), and taking the current fix started the
                // clock ~0.9 s after the ghost's did. Same function, same
                // inputs, same answer as ghost generation.
                startTime = GhostEngine.startTime(
                    samples: rawGPS.map { ($0.timestamp, $0.coordinate) },
                    gateHitTimestamp: hit.timestamp,
                    movedMeters: config.startMovingMeters
                )
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
        // NOT recorder.finish() — the run is not safe yet. It is safe once
        // the app has put it in the upload queue, and only the app knows
        // when that happened. Flushing what is buffered is right; deleting
        // the file here would reopen the crash window this exists to close.
        Task { await self.drainJournal() }
        transition(to: .finished(DriveRunOutcome(
            evaluation: outcome, rawGPS: rawGPS, rawIMU: rawIMU
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
