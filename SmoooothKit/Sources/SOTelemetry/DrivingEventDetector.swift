import SOCore

/// Kinds of notable driving events detected from vehicle-frame telemetry
/// (spec §37). Raw values are persisted in fixtures and server-side — never
/// change them.
public enum DrivingEventKind: String, Codable, Sendable, CaseIterable {
    case acceleration
    case braking
    case hardBraking
    case cornering
    case hardCornering
}

/// One detected driving event: a contiguous window where a smoothed
/// vehicle-frame signal stayed above its (speed-contextual) threshold.
public struct DrivingEvent: Codable, Sendable, Equatable {
    public var kind: DrivingEventKind
    /// Seconds since Unix epoch.
    public var startTime: Double
    public var endTime: Double
    /// Absolute value of the peak *smoothed* signal during the event, in g.
    public var peakMagnitudeG: Double
    /// Interpolated ground speed at the peak; nil when no trajectory was given.
    public var speedAtPeakMps: Double?

    public init(
        kind: DrivingEventKind,
        startTime: Double,
        endTime: Double,
        peakMagnitudeG: Double,
        speedAtPeakMps: Double?
    ) {
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.peakMagnitudeG = peakMagnitudeG
        self.speedAtPeakMps = speedAtPeakMps
    }

    public var duration: Double { endTime - startTime }
}

/// Thresholds and smoothing for `DrivingEventDetector`. Every threshold is a
/// `PiecewiseLinearCurve` mapping speed (m/s) → threshold (g), because hard
/// braking at 60 mph is not hard braking at 10 mph (spec §37). Nothing is
/// hard-coded in the detection logic.
public struct EventDetectionConfig: Codable, Sendable, Equatable {
    /// Positive longitudinal (throttle) event threshold.
    public var accelerationThreshold: PiecewiseLinearCurve
    /// Negative longitudinal (brake) event threshold.
    public var brakingThreshold: PiecewiseLinearCurve
    /// Peak level at which a braking event is classified hard. Decreases
    /// with speed: the faster you go, the stricter the smoothness bar.
    public var hardBrakingThreshold: PiecewiseLinearCurve
    /// |lateral| (cornering) event threshold.
    public var corneringThreshold: PiecewiseLinearCurve
    /// Peak level at which a cornering event is classified hard.
    public var hardCorneringThreshold: PiecewiseLinearCurve
    /// Width of the centered moving-average window, seconds.
    public var smoothingWindowSeconds: Double
    /// Events shorter than this are discarded as noise, seconds.
    public var minEventDurationSeconds: Double
    /// An open event closes when the signal drops below
    /// `hysteresisRatio × threshold` (prevents flutter at the boundary).
    public var hysteresisRatio: Double
    /// Same-kind events separated by less than this merge into one, seconds.
    public var mergeGapSeconds: Double

    public init(
        accelerationThreshold: PiecewiseLinearCurve,
        brakingThreshold: PiecewiseLinearCurve,
        hardBrakingThreshold: PiecewiseLinearCurve,
        corneringThreshold: PiecewiseLinearCurve,
        hardCorneringThreshold: PiecewiseLinearCurve,
        smoothingWindowSeconds: Double,
        minEventDurationSeconds: Double,
        hysteresisRatio: Double,
        mergeGapSeconds: Double
    ) {
        self.accelerationThreshold = accelerationThreshold
        self.brakingThreshold = brakingThreshold
        self.hardBrakingThreshold = hardBrakingThreshold
        self.corneringThreshold = corneringThreshold
        self.hardCorneringThreshold = hardCorneringThreshold
        self.smoothingWindowSeconds = smoothingWindowSeconds
        self.minEventDurationSeconds = minEventDurationSeconds
        self.hysteresisRatio = hysteresisRatio
        self.mergeGapSeconds = mergeGapSeconds
    }

    /// Spec §37 initial thresholds. Hard thresholds tighten as speed grows —
    /// aggressive inputs are penalized more where their consequences are
    /// larger. Breakpoint literals are strictly increasing in x, so the
    /// force-unwraps cannot fail.
    public static let `default` = EventDetectionConfig(
        accelerationThreshold: PiecewiseLinearCurve(breakpoints: [
            .init(x: 0, y: 0.30), .init(x: 30, y: 0.25),
        ])!,
        brakingThreshold: PiecewiseLinearCurve(breakpoints: [
            .init(x: 0, y: 0.25),
        ])!,
        hardBrakingThreshold: PiecewiseLinearCurve(breakpoints: [
            .init(x: 3, y: 0.45), .init(x: 15, y: 0.35), .init(x: 30, y: 0.30),
        ])!,
        corneringThreshold: PiecewiseLinearCurve(breakpoints: [
            .init(x: 0, y: 0.30),
        ])!,
        hardCorneringThreshold: PiecewiseLinearCurve(breakpoints: [
            .init(x: 3, y: 0.50), .init(x: 15, y: 0.42), .init(x: 30, y: 0.38),
        ])!,
        smoothingWindowSeconds: 0.5,
        minEventDurationSeconds: 0.3,
        hysteresisRatio: 0.8,
        mergeGapSeconds: 0.5
    )
}

/// Detects acceleration, braking and cornering events from vehicle-frame
/// samples, with thresholds that adapt to ground speed (spec §37).
///
/// The detector smooths each channel with a centered time-window moving
/// average (single-sample spikes are physics-free noise), then segments each
/// channel with hysteresis, classifies hard variants by the peak against the
/// hard curve at the speed of the peak, drops sub-duration blips, and merges
/// same-kind neighbors. Events from *different* channels may overlap —
/// braking while cornering is real and matters to scoring.
public struct DrivingEventDetector: Sendable {
    public let config: EventDetectionConfig

    public init(config: EventDetectionConfig = .default) {
        self.config = config
    }

    /// Detects events. `samples` must be in timestamp order. When
    /// `trajectory` is nil, speed is unknown and every threshold curve is
    /// evaluated at 0 (its clamped low end).
    public func detect(
        samples: [VehicleFrameSample],
        trajectory: ProcessedTrajectory?
    ) -> [DrivingEvent] {
        guard samples.count > 1 else { return [] }

        let times = samples.map(\.timestamp)
        let longitudinal = smooth(values: samples.map(\.longitudinal), times: times)
        let lateral = smooth(values: samples.map(\.lateral), times: times)
        let speeds = SpeedInterpolator(trajectory: trajectory)

        var events: [DrivingEvent] = []
        // Throttle: positive longitudinal only.
        events += segment(
            signal: longitudinal.map { max(0, $0) }, times: times, speeds: speeds,
            openCurve: config.accelerationThreshold, hardCurve: nil,
            normalKind: .acceleration, hardKind: nil
        )
        // Brake: negative longitudinal, folded to magnitude.
        events += segment(
            signal: longitudinal.map { max(0, -$0) }, times: times, speeds: speeds,
            openCurve: config.brakingThreshold, hardCurve: config.hardBrakingThreshold,
            normalKind: .braking, hardKind: .hardBraking
        )
        // Cornering: |lateral|, either direction.
        events += segment(
            signal: lateral.map { abs($0) }, times: times, speeds: speeds,
            openCurve: config.corneringThreshold, hardCurve: config.hardCorneringThreshold,
            normalKind: .cornering, hardKind: .hardCornering
        )

        return merge(events).sorted { ($0.startTime, $0.kind.rawValue) < ($1.startTime, $1.kind.rawValue) }
    }

    // MARK: - Pipeline stages

    /// Centered moving average over a time window (not a sample count), so
    /// irregular sample spacing cannot bias the smoothing.
    private func smooth(values: [Double], times: [Double]) -> [Double] {
        let halfWindow = config.smoothingWindowSeconds / 2
        guard halfWindow > 0 else { return values }

        var smoothed = [Double]()
        smoothed.reserveCapacity(values.count)
        var lower = 0
        var upper = 0
        var windowSum = 0.0

        for index in values.indices {
            let center = times[index]
            while upper < values.count && times[upper] <= center + halfWindow {
                windowSum += values[upper]
                upper += 1
            }
            while lower < upper && times[lower] < center - halfWindow {
                windowSum -= values[lower]
                lower += 1
            }
            smoothed.append(windowSum / Double(upper - lower))
        }
        return smoothed
    }

    /// Hysteresis segmentation of one non-negative signal.
    private func segment(
        signal: [Double],
        times: [Double],
        speeds: SpeedInterpolator,
        openCurve: PiecewiseLinearCurve,
        hardCurve: PiecewiseLinearCurve?,
        normalKind: DrivingEventKind,
        hardKind: DrivingEventKind?
    ) -> [DrivingEvent] {
        struct OpenEvent {
            var startTime: Double
            var peak: Double
            var peakSpeed: Double?
        }

        var events: [DrivingEvent] = []
        var open: OpenEvent?

        func close(_ event: OpenEvent, at endTime: Double) {
            guard endTime - event.startTime >= config.minEventDurationSeconds else { return }
            var kind = normalKind
            if let hardCurve, let hardKind,
               event.peak >= hardCurve.value(at: event.peakSpeed ?? 0) {
                kind = hardKind
            }
            events.append(DrivingEvent(
                kind: kind,
                startTime: event.startTime,
                endTime: endTime,
                peakMagnitudeG: event.peak,
                speedAtPeakMps: event.peakSpeed
            ))
        }

        for index in signal.indices {
            let time = times[index]
            let speed = speeds.speed(at: time)
            let threshold = openCurve.value(at: speed ?? 0)
            let value = signal[index]

            if var current = open {
                if value >= config.hysteresisRatio * threshold {
                    if value > current.peak {
                        current.peak = value
                        current.peakSpeed = speed
                    }
                    open = current
                } else {
                    close(current, at: time)
                    open = nil
                }
            } else if value >= threshold {
                open = OpenEvent(startTime: time, peak: value, peakSpeed: speed)
            }
        }
        if let current = open, let last = times.last {
            close(current, at: last)
        }
        return events
    }

    /// Merges same-kind events separated by less than `mergeGapSeconds`,
    /// keeping the strongest peak.
    private func merge(_ events: [DrivingEvent]) -> [DrivingEvent] {
        var merged: [DrivingEvent] = []
        for event in events.sorted(by: { $0.startTime < $1.startTime }) {
            if let lastIndex = merged.indices.last,
               merged[lastIndex].kind == event.kind,
               event.startTime - merged[lastIndex].endTime < config.mergeGapSeconds {
                merged[lastIndex].endTime = max(merged[lastIndex].endTime, event.endTime)
                if event.peakMagnitudeG > merged[lastIndex].peakMagnitudeG {
                    merged[lastIndex].peakMagnitudeG = event.peakMagnitudeG
                    merged[lastIndex].speedAtPeakMps = event.speedAtPeakMps
                }
            } else {
                merged.append(event)
            }
        }
        return merged
    }
}

/// Linear speed interpolation over trajectory points; O(1) amortized for
/// monotone queries via a moving cursor semantic (kept simple: binary search).
private struct SpeedInterpolator {
    private let points: [TrajectoryPoint]

    init(trajectory: ProcessedTrajectory?) {
        self.points = trajectory?.points ?? []
    }

    func speed(at time: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if time <= first.timestamp { return first.speedMps }
        if time >= last.timestamp { return last.speedMps }

        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].timestamp <= time { low = mid } else { high = mid }
        }
        let a = points[low]
        let b = points[high]
        let span = b.timestamp - a.timestamp
        guard span > 0 else { return a.speedMps }
        let t = (time - a.timestamp) / span
        return a.speedMps + t * (b.speedMps - a.speedMps)
    }
}
