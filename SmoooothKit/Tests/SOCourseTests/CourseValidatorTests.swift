import Foundation
import Testing
import SOCore
@testable import SOCourse

@Suite("CourseValidator")
struct CourseValidatorTests {
    let origin = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
    let validator = CourseValidator()

    /// Straight course of `meters`, points every 100 m.
    private func polyline(meters: Double) -> [GeoCoordinate] {
        stride(from: 0.0, through: meters, by: 100).map {
            origin.destination(bearingDegrees: 0, distanceMeters: $0)
        }
    }

    private func checkpoint(_ sequence: Int, at meters: Double, radius: Double = 30) -> Checkpoint {
        Checkpoint(
            sequence: sequence,
            center: origin.destination(bearingDegrees: 0, distanceMeters: meters),
            radiusMeters: radius
        )
    }

    private var validCourse: ([GeoCoordinate], [Checkpoint]) {
        (polyline(meters: 3000), [
            checkpoint(0, at: 0),
            checkpoint(1, at: 1500),
            checkpoint(2, at: 3000),
        ])
    }

    @Test("a well-formed course validates clean")
    func validCoursePasses() {
        let (route, gates) = validCourse
        #expect(validator.validate(polyline: route, checkpoints: gates).isEmpty)
    }

    @Test("too-short and too-long courses are rejected (configurable limits)")
    func lengthLimits() {
        let short = validator.validate(
            polyline: polyline(meters: 500),
            checkpoints: [checkpoint(0, at: 0), checkpoint(1, at: 500)]
        )
        #expect(short.contains { if case .tooShort = $0 { true } else { false } })

        var strict = CourseValidationConfig.default
        strict.maxDistanceMeters = 2000
        let (route, gates) = validCourse
        let long = CourseValidator(config: strict).validate(polyline: route, checkpoints: gates)
        #expect(long.contains { if case .tooLong = $0 { true } else { false } })
    }

    @Test("coarse routes (big point spacing) are rejected — geometry can hide between points")
    func pointSpacing() {
        let coarse = [origin,
                      origin.destination(bearingDegrees: 0, distanceMeters: 900),
                      origin.destination(bearingDegrees: 0, distanceMeters: 1800)]
        let issues = validator.validate(
            polyline: coarse,
            checkpoints: [checkpoint(0, at: 0), checkpoint(1, at: 1800)]
        )
        #expect(issues.contains { if case .excessivePointSpacing = $0 { true } else { false } })
    }

    @Test("non-finite and out-of-range coordinates are rejected")
    func invalidCoordinates() {
        var route = polyline(meters: 2000)
        route[3] = GeoCoordinate(latitude: .nan, longitude: -118)
        let issues = validator.validate(polyline: route, checkpoints: [])
        #expect(issues.contains { if case .invalidCoordinate(index: 3) = $0 { true } else { false } })

        var outOfRange = polyline(meters: 2000)
        outOfRange[5] = GeoCoordinate(latitude: 91, longitude: 0)
        let rangeIssues = validator.validate(polyline: outOfRange, checkpoints: [])
        #expect(rangeIssues.contains { if case .invalidCoordinate(index: 5) = $0 { true } else { false } })
    }

    @Test("checkpoint problems: count, duplicates, contiguity, off-route, order, spacing")
    func checkpointIssues() {
        let route = polyline(meters: 3000)

        let single = validator.validate(polyline: route, checkpoints: [checkpoint(0, at: 0)])
        #expect(single.contains { if case .insufficientCheckpoints(count: 1) = $0 { true } else { false } })

        let duplicated = validator.validate(
            polyline: route,
            checkpoints: [checkpoint(0, at: 0), checkpoint(1, at: 1000), checkpoint(1, at: 2000)]
        )
        #expect(duplicated.contains { if case .duplicateCheckpointSequence(sequence: 1) = $0 { true } else { false } })

        let gapped = validator.validate(
            polyline: route,
            checkpoints: [checkpoint(0, at: 0), checkpoint(2, at: 3000)]
        )
        #expect(gapped.contains { $0 == .nonContiguousCheckpointSequence })

        let offRouteGate = Checkpoint(
            sequence: 1,
            center: origin.destination(bearingDegrees: 0, distanceMeters: 1500)
                .destination(bearingDegrees: 90, distanceMeters: 200),
            radiusMeters: 30
        )
        let offRoute = validator.validate(
            polyline: route,
            checkpoints: [checkpoint(0, at: 0), offRouteGate, checkpoint(2, at: 3000)]
        )
        #expect(offRoute.contains { if case .checkpointOffRoute(sequence: 1, _) = $0 { true } else { false } })

        let disordered = validator.validate(
            polyline: route,
            checkpoints: [checkpoint(0, at: 0), checkpoint(1, at: 2500), checkpoint(2, at: 1000), checkpoint(3, at: 3000)]
        )
        #expect(disordered.contains { if case .checkpointsOutOfOrder(sequence: 2) = $0 { true } else { false } })

        let crowded = validator.validate(
            polyline: route,
            checkpoints: [checkpoint(0, at: 0), checkpoint(1, at: 1000), checkpoint(2, at: 1050), checkpoint(3, at: 3000)]
        )
        #expect(crowded.contains { if case .checkpointsTooClose(sequence: 2, _) = $0 { true } else { false } })
    }

    @Test("start and finish gates must anchor the route ends")
    func startFinishAnchoring() {
        let route = polyline(meters: 3000)
        let issues = validator.validate(
            polyline: route,
            checkpoints: [checkpoint(0, at: 500), checkpoint(1, at: 1500), checkpoint(2, at: 2400)]
        )
        #expect(issues.contains { if case .startNotAtRouteStart = $0 { true } else { false } })
        #expect(issues.contains { if case .finishNotAtRouteEnd = $0 { true } else { false } })
    }

    @Test("all issues are reported in one pass, not just the first")
    func aggregateReporting() {
        let issues = validator.validate(
            polyline: polyline(meters: 500),
            checkpoints: [checkpoint(0, at: 500)]
        )
        #expect(issues.count >= 2)  // tooShort + insufficientCheckpoints + anchoring
    }
}
