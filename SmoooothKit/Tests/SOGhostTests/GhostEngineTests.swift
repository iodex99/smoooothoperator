import Foundation
import Testing
import SOCore
import SOCourse
import SOTelemetry
@testable import SOGhost

@Suite("GhostEngine")
struct GhostEngineTests {
    let origin = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
    let base = 1_754_982_000.0

    /// Straight 2 km course, gates at 0 / 1000 / 2000.
    private var course: (polyline: [GeoCoordinate], checkpoints: [Checkpoint]) {
        let polyline = stride(from: 0.0, through: 2000, by: 100).map {
            origin.destination(bearingDegrees: 0, distanceMeters: $0)
        }
        let gates = [0.0, 1000, 2000].enumerated().map { sequence, meters in
            Checkpoint(sequence: sequence,
                       center: origin.destination(bearingDegrees: 0, distanceMeters: meters),
                       radiusMeters: 30)
        }
        return (polyline, gates)
    }

    /// Constant-speed drive with `stagingSeconds` parked before moving.
    private func makeTrajectory(speedMps: Double, stagingSeconds: Double = 5) -> ProcessedTrajectory {
        var points: [TrajectoryPoint] = []
        for second in 0..<Int(stagingSeconds) {
            points.append(TrajectoryPoint(
                timestamp: base + Double(second), coordinate: origin, speedMps: 0,
                headingDegrees: nil, distanceAlongPathMeters: 0, horizontalAccuracy: 5
            ))
        }
        let steps = Int(2000 / speedMps)
        for step in 0...steps {
            let meters = min(2000, Double(step) * speedMps)
            points.append(TrajectoryPoint(
                timestamp: base + stagingSeconds + Double(step),
                coordinate: origin.destination(bearingDegrees: 0, distanceMeters: meters),
                speedMps: speedMps,
                headingDegrees: 0,
                distanceAlongPathMeters: meters,
                horizontalAccuracy: 5
            ))
        }
        return ProcessedTrajectory(points: points, gaps: [], rejectedSampleCount: 0)
    }

    private func makeGhost(speedMps: Double, stagingSeconds: Double = 5) throws -> GhostTrajectory {
        let (polyline, checkpoints) = course
        return try GhostEngine.generate(
            trajectory: makeTrajectory(speedMps: speedMps, stagingSeconds: stagingSeconds),
            polyline: polyline,
            checkpoints: checkpoints
        )
    }

    @Test("a ghost spans start line to finish, monotone in both axes")
    func ghostShape() throws {
        let ghost = try makeGhost(speedMps: 20)
        // The ends are the progress the car ACTUALLY had, not pinned 0 and 1.
        // The clock starts once it has moved `startMovingMeters` past the
        // gate, so the first point sits slightly along the course; a run ends
        // on ENTERING the finish gate circle, so the last sits slightly short
        // of it. Pinning both ends was a real defect: it stretched the ghost's
        // first and last segments across ground the driver never covers, and
        // showed a driver racing their own run as ~1.8 s away from themselves
        // at each end.
        #expect(ghost.points.first?.elapsedSeconds == 0)
        let firstProgress = ghost.points.first?.progress ?? -1
        #expect(firstProgress >= 0 && firstProgress < 0.05, "start \(firstProgress)")
        #expect(abs((ghost.points.last?.progress ?? 0) - 1) < 0.05)
        #expect(zip(ghost.points, ghost.points.dropFirst()).allSatisfy {
            $0.progress < $1.progress && $0.elapsedSeconds <= $1.elapsedSeconds
        })
        // 2000 m at 20 m/s ≈ 100 s — staging time never counts.
        #expect(abs(ghost.totalSeconds - 100) < 3)
    }

    @Test("staging time before the start line never affects the ghost clock")
    func stagingExcluded() throws {
        let quick = try makeGhost(speedMps: 20, stagingSeconds: 2)
        let slow = try makeGhost(speedMps: 20, stagingSeconds: 60)
        #expect(abs(quick.totalSeconds - slow.totalSeconds) < 1.5)
    }

    @Test("ghosts are compact regardless of sampling rate")
    func compactness() throws {
        let ghost = try makeGhost(speedMps: 10)  // 200 s of driving
        #expect(ghost.points.count <= Int(1 / GhostConfig.default.progressResolution) + 2)
    }

    @Test("racing your own ghost shows zero gap everywhere (identity property)")
    func selfGapIsZero() throws {
        let ghost = try makeGhost(speedMps: 20)
        for point in ghost.points {
            let gap = GhostEngine.gapSeconds(
                elapsedSeconds: point.elapsedSeconds,
                progress: point.progress,
                against: ghost
            )
            #expect(abs(gap) < 0.001)
        }
    }

    @Test("a faster driver shows ahead (negative gap) against a slower ghost")
    func fasterIsAhead() throws {
        let slowGhost = try makeGhost(speedMps: 15)
        let fastGhost = try makeGhost(speedMps: 20)
        // At half distance, the fast run's elapsed vs the slow ghost:
        let gap = GhostEngine.gapSeconds(
            elapsedSeconds: fastGhost.elapsedSeconds(atProgress: 0.5),
            progress: 0.5,
            against: slowGhost
        )
        #expect(gap < -10)  // 1000 m: 50 s vs ~66.7 s → about −16 s

        let reverseGap = GhostEngine.gapSeconds(
            elapsedSeconds: slowGhost.elapsedSeconds(atProgress: 0.5),
            progress: 0.5,
            against: fastGhost
        )
        #expect(reverseGap > 10)
    }

    @Test("interpolation between stored points is linear and clamped")
    func interpolation() throws {
        let ghost = GhostTrajectory(
            points: [
                GhostPoint(progress: 0, elapsedSeconds: 0),
                GhostPoint(progress: 0.5, elapsedSeconds: 60),
                GhostPoint(progress: 1, elapsedSeconds: 100),
            ],
            totalSeconds: 100
        )
        #expect(ghost.elapsedSeconds(atProgress: 0.25) == 30)
        #expect(ghost.elapsedSeconds(atProgress: 0.75) == 80)
        #expect(ghost.elapsedSeconds(atProgress: -0.5) == 0)
        #expect(ghost.elapsedSeconds(atProgress: 1.5) == 100)
    }

    @Test("unfinished runs cannot become ghosts")
    func unfinishedRejected() {
        let (polyline, checkpoints) = course
        // Stop at 900 m — the mid gate is never reached.
        let short = ProcessedTrajectory(
            points: (0...45).map { step in
                TrajectoryPoint(
                    timestamp: base + Double(step),
                    coordinate: origin.destination(bearingDegrees: 0, distanceMeters: Double(step) * 20),
                    speedMps: 20, headingDegrees: 0,
                    distanceAlongPathMeters: Double(step) * 20, horizontalAccuracy: 5
                )
            },
            gaps: [], rejectedSampleCount: 0
        )
        #expect(throws: GhostGenerationError.runDidNotFinish) {
            _ = try GhostEngine.generate(trajectory: short, polyline: polyline, checkpoints: checkpoints)
        }
    }

    @Test("ghost payloads stay privacy-safe: progress + time only, no coordinates")
    func privacyShape() throws {
        let ghost = try makeGhost(speedMps: 20)
        let data = try JSONEncoder().encode(ghost)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("latitude"))
        #expect(!json.contains("longitude"))
        #expect(!json.contains("coordinate"))
    }
}
