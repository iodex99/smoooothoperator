import Foundation
import Testing
import SOCore
@testable import SOTelemetry

@Suite("DrivingEventDetector")
struct DrivingEventDetectorTests {
    let base = 1_754_982_000.0
    let detector = DrivingEventDetector()

    // MARK: - Helpers

    /// 50 Hz vehicle-frame samples over `duration` seconds with raised-cosine
    /// pulses (amplitude peaks at the pulse center) on chosen channels.
    private func makeSamples(
        duration: Double,
        longitudinalPulses: [(start: Double, length: Double, amplitude: Double)] = [],
        lateralPulses: [(start: Double, length: Double, amplitude: Double)] = []
    ) -> [VehicleFrameSample] {
        let hz = 50.0
        return (0...Int(duration * hz)).map { index in
            let t = Double(index) / hz
            func pulseValue(_ pulses: [(start: Double, length: Double, amplitude: Double)]) -> Double {
                pulses.reduce(0) { sum, pulse in
                    guard t >= pulse.start, t <= pulse.start + pulse.length else { return sum }
                    let phase = (t - pulse.start) / pulse.length
                    return sum + pulse.amplitude * 0.5 * (1 - cos(2 * .pi * phase))
                }
            }
            return VehicleFrameSample(
                timestamp: base + t,
                longitudinal: pulseValue(longitudinalPulses),
                lateral: pulseValue(lateralPulses),
                vertical: 0,
                yawRate: 0
            )
        }
    }

    /// Constant-speed trajectory covering `duration` seconds at 1 Hz.
    private func makeTrajectory(duration: Double, speedMps: Double) -> ProcessedTrajectory {
        let origin = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
        let points = (0...Int(duration)).map { second in
            TrajectoryPoint(
                timestamp: base + Double(second),
                coordinate: origin.destination(bearingDegrees: 0, distanceMeters: speedMps * Double(second)),
                speedMps: speedMps,
                headingDegrees: 0,
                distanceAlongPathMeters: speedMps * Double(second),
                horizontalAccuracy: 5
            )
        }
        return ProcessedTrajectory(points: points, gaps: [], rejectedSampleCount: 0)
    }

    // MARK: - The speed-contextual heart of spec §37

    @Test("a 0.4g brake at 30 m/s is HARD braking")
    func hardBrakingAtSpeed() {
        let samples = makeSamples(
            duration: 20,
            longitudinalPulses: [(start: 9, length: 2, amplitude: -0.4)]
        )
        let events = detector.detect(samples: samples, trajectory: makeTrajectory(duration: 20, speedMps: 30))
        #expect(events.map(\.kind) == [.hardBraking])
        #expect(abs((events.first?.speedAtPeakMps ?? 0) - 30) < 0.001)
    }

    @Test("the SAME 0.4g brake at 4 m/s is ordinary braking — thresholds adapt to speed")
    func ordinaryBrakingAtLowSpeed() {
        let samples = makeSamples(
            duration: 20,
            longitudinalPulses: [(start: 9, length: 2, amplitude: -0.4)]
        )
        let events = detector.detect(samples: samples, trajectory: makeTrajectory(duration: 20, speedMps: 4))
        #expect(events.map(\.kind) == [.braking])
    }

    // MARK: - Detection basics

    @Test("gentle 0.2g inputs produce no events at all")
    func gentleDriving() {
        let samples = makeSamples(
            duration: 20,
            longitudinalPulses: [(start: 3, length: 2, amplitude: 0.2), (start: 9, length: 2, amplitude: -0.2)],
            lateralPulses: [(start: 14, length: 2, amplitude: 0.2)]
        )
        let events = detector.detect(samples: samples, trajectory: makeTrajectory(duration: 20, speedMps: 15))
        #expect(events.isEmpty)
    }

    @Test("a throttle pulse is an acceleration event (no hard variant exists)")
    func accelerationEvent() {
        let samples = makeSamples(
            duration: 20,
            longitudinalPulses: [(start: 9, length: 2, amplitude: 0.5)]
        )
        let events = detector.detect(samples: samples, trajectory: makeTrajectory(duration: 20, speedMps: 10))
        #expect(events.map(\.kind) == [.acceleration])
    }

    @Test("a strong lateral pulse is hard cornering; a moderate one is cornering")
    func corneringClassification() {
        let strong = makeSamples(duration: 20, lateralPulses: [(start: 9, length: 2, amplitude: -0.6)])
        let strongEvents = detector.detect(samples: strong, trajectory: makeTrajectory(duration: 20, speedMps: 20))
        #expect(strongEvents.map(\.kind) == [.hardCornering])

        let moderate = makeSamples(duration: 20, lateralPulses: [(start: 9, length: 2, amplitude: 0.36)])
        let moderateEvents = detector.detect(samples: moderate, trajectory: makeTrajectory(duration: 20, speedMps: 20))
        #expect(moderateEvents.map(\.kind) == [.cornering])
    }

    // MARK: - Noise rejection

    @Test("a single-sample 1g spike is absorbed by smoothing — no event")
    func spikeRejection() {
        var samples = makeSamples(duration: 20)
        samples[500].longitudinal = -1.0  // one sample at t=10s
        let events = detector.detect(samples: samples, trajectory: makeTrajectory(duration: 20, speedMps: 15))
        #expect(events.isEmpty)
    }

    @Test("a 0.1s burst above threshold fails the minimum duration gate")
    func shortBurstRejection() {
        let samples = makeSamples(
            duration: 20,
            longitudinalPulses: [(start: 10, length: 0.1, amplitude: -1.5)]
        )
        let events = detector.detect(samples: samples, trajectory: makeTrajectory(duration: 20, speedMps: 15))
        #expect(events.isEmpty)
    }

    // MARK: - Merging & overlap

    @Test("same-kind events inside the merge gap collapse into one; outside it they stay separate")
    func mergeAdjacent() {
        let samples = makeSamples(
            duration: 20,
            longitudinalPulses: [
                (start: 8, length: 1.0, amplitude: -0.4),
                (start: 9.3, length: 1.0, amplitude: -0.4),
            ]
        )
        let trajectory = makeTrajectory(duration: 20, speedMps: 4)

        // Hysteresis leaves ~0.7s between these two events: below a 1.0s
        // merge gap they collapse…
        var mergingConfig = EventDetectionConfig.default
        mergingConfig.mergeGapSeconds = 1.0
        let merged = DrivingEventDetector(config: mergingConfig).detect(samples: samples, trajectory: trajectory)
        #expect(merged.map(\.kind) == [.braking])
        #expect((merged.first?.duration ?? 0) > 1.5)

        // …with the default 0.5s gap they stay two distinct events.
        let separate = detector.detect(samples: samples, trajectory: trajectory)
        #expect(separate.map(\.kind) == [.braking, .braking])
    }

    @Test("braking while cornering reports BOTH events, overlapping")
    func simultaneousChannels() {
        let samples = makeSamples(
            duration: 20,
            longitudinalPulses: [(start: 9, length: 2, amplitude: -0.4)],
            lateralPulses: [(start: 9.5, length: 2, amplitude: 0.4)]
        )
        let events = detector.detect(samples: samples, trajectory: makeTrajectory(duration: 20, speedMps: 8))
        let kinds = Set(events.map(\.kind))
        #expect(kinds.contains(.braking) || kinds.contains(.hardBraking))
        #expect(kinds.contains(.cornering) || kinds.contains(.hardCornering))
        // The two channel events genuinely overlap in time.
        if let braking = events.first(where: { $0.kind == .braking || $0.kind == .hardBraking }),
           let cornering = events.first(where: { $0.kind == .cornering || $0.kind == .hardCornering }) {
            #expect(braking.startTime < cornering.endTime && cornering.startTime < braking.endTime)
        }
    }

    // MARK: - Degenerate inputs

    @Test("empty and single-sample inputs return no events")
    func degenerateInputs() {
        #expect(detector.detect(samples: [], trajectory: nil).isEmpty)
        let single = [VehicleFrameSample(timestamp: base, longitudinal: -2, lateral: 0, vertical: 0, yawRate: 0)]
        #expect(detector.detect(samples: single, trajectory: nil).isEmpty)
    }

    @Test("nil trajectory still detects events, with unknown speed")
    func nilTrajectory() {
        let samples = makeSamples(
            duration: 20,
            longitudinalPulses: [(start: 9, length: 2, amplitude: -0.6)]
        )
        let events = detector.detect(samples: samples, trajectory: nil)
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.speedAtPeakMps == nil })
    }

    // MARK: - Properties

    @Test("random pulse trains: events are well-formed and channel-disjoint",
          arguments: 1...20)
    func propertyWellFormed(seed: Int) {
        var rng = SeededRandomNumberGenerator(seed: UInt64(seed))
        let duration = 60.0
        var longitudinalPulses: [(start: Double, length: Double, amplitude: Double)] = []
        var lateralPulses: [(start: Double, length: Double, amplitude: Double)] = []
        for _ in 0..<8 {
            let start = Double.random(in: 0...(duration - 3), using: &rng)
            let length = Double.random(in: 0.2...2.5, using: &rng)
            let amplitude = Double.random(in: -0.7...0.7, using: &rng)
            if Bool.random(using: &rng) {
                longitudinalPulses.append((start, length, amplitude))
            } else {
                lateralPulses.append((start, length, amplitude))
            }
        }
        let samples = makeSamples(
            duration: duration,
            longitudinalPulses: longitudinalPulses,
            lateralPulses: lateralPulses
        )
        let speed = Double.random(in: 2...35, using: &rng)
        let events = detector.detect(samples: samples, trajectory: makeTrajectory(duration: duration, speedMps: speed))

        let maxInput = samples.map { max(abs($0.longitudinal), abs($0.lateral)) }.max() ?? 0
        for event in events {
            #expect(event.endTime > event.startTime)
            #expect(event.duration >= detector.config.minEventDurationSeconds)
            #expect(event.startTime >= base && event.endTime <= base + duration + 0.001)
            #expect(event.peakMagnitudeG > 0 && event.peakMagnitudeG <= maxInput + 0.001)
        }
        // Same-channel events never overlap.
        let longitudinalFamily: Set<DrivingEventKind> = [.acceleration, .braking, .hardBraking]
        for family in [longitudinalFamily, [.cornering, .hardCornering]] {
            let channelEvents = events.filter { family.contains($0.kind) }.sorted { $0.startTime < $1.startTime }
            for (a, b) in zip(channelEvents, channelEvents.dropFirst()) {
                #expect(a.endTime <= b.startTime + 0.001)
            }
        }
    }
}
