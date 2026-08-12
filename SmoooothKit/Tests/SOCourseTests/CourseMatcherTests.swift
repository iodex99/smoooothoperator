import Foundation
import Testing
import SOCore
@testable import SOCourse

@Suite("CourseMatcher")
struct CourseMatcherTests {
    let origin = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)

    /// Straight 1 km course heading north.
    private var straightCourse: CourseMatcher {
        let polyline = stride(from: 0.0, through: 1000, by: 100).map {
            origin.destination(bearingDegrees: 0, distanceMeters: $0)
        }
        return CourseMatcher(polyline: polyline)!
    }

    @Test("projects onto the middle of a straight course with correct lateral offset")
    func straightProjection() {
        let probe = origin
            .destination(bearingDegrees: 0, distanceMeters: 500)
            .destination(bearingDegrees: 90, distanceMeters: 10)
        let match = straightCourse.nearestMatch(to: probe)
        #expect(abs(match.distanceAlongCourseMeters - 500) < 1)
        #expect(abs(match.lateralOffsetMeters - 10) < 0.5)
    }

    @Test("clamps beyond the finish and before the start")
    func clamping() {
        let past = origin.destination(bearingDegrees: 0, distanceMeters: 1100)
        let pastMatch = straightCourse.nearestMatch(to: past)
        #expect(abs(pastMatch.distanceAlongCourseMeters - 1000) < 1)
        #expect(abs(pastMatch.lateralOffsetMeters - 100) < 1)

        let before = origin.destination(bearingDegrees: 180, distanceMeters: 50)
        let beforeMatch = straightCourse.nearestMatch(to: before)
        #expect(beforeMatch.distanceAlongCourseMeters < 1)
        #expect(abs(beforeMatch.lateralOffsetMeters - 50) < 1)
    }

    @Test("total distance matches the polyline length")
    func totalDistance() {
        #expect(abs(straightCourse.totalDistanceMeters - 1000) < 1)
    }

    @Test("windowed matching resolves out-and-back ambiguity by cursor")
    func selfCrossingCursor() {
        // North 1 km, jog east 50 m, back south 1 km: two parallel passes.
        var polyline = stride(from: 0.0, through: 1000, by: 100).map {
            origin.destination(bearingDegrees: 0, distanceMeters: $0)
        }
        let turnPoint = polyline[polyline.count - 1].destination(bearingDegrees: 90, distanceMeters: 50)
        polyline.append(turnPoint)
        polyline += stride(from: 100.0, through: 1000, by: 100).map {
            turnPoint.destination(bearingDegrees: 180, distanceMeters: $0)
        }
        let matcher = CourseMatcher(polyline: polyline)!

        // A probe halfway up, 25 m east: equidistant from both passes.
        let probe = origin
            .destination(bearingDegrees: 0, distanceMeters: 500)
            .destination(bearingDegrees: 90, distanceMeters: 25)

        let outbound = matcher.match(probe, near: 400, backtrackMeters: 100, lookaheadMeters: 400)
        #expect(abs(outbound.distanceAlongCourseMeters - 500) < 5)

        let inbound = matcher.match(probe, near: 1500, backtrackMeters: 100, lookaheadMeters: 400)
        #expect(inbound.distanceAlongCourseMeters > 1200)
    }

    @Test("degenerate polylines fail initialization")
    func degenerate() {
        #expect(CourseMatcher(polyline: []) == nil)
        #expect(CourseMatcher(polyline: [origin]) == nil)
        #expect(CourseMatcher(polyline: [origin, origin]) == nil)  // zero length
    }

    @Test("duplicate intermediate points are tolerated")
    func duplicatePoints() {
        let mid = origin.destination(bearingDegrees: 0, distanceMeters: 500)
        let end = origin.destination(bearingDegrees: 0, distanceMeters: 1000)
        let matcher = CourseMatcher(polyline: [origin, mid, mid, end])
        #expect(matcher != nil)
        #expect(abs((matcher?.totalDistanceMeters ?? 0) - 1000) < 1)
    }
}
