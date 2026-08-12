import Foundation
import SOCore

/// A fix matched against the course line.
public struct CourseMatch: Sendable, Equatable {
    /// Distance along the course of the closest on-course point, meters.
    public var distanceAlongCourseMeters: Double
    /// Unsigned distance from the fix to the course line, meters.
    public var lateralOffsetMeters: Double
    /// Index of the polyline segment the match landed on.
    public var segmentIndex: Int

    public init(distanceAlongCourseMeters: Double, lateralOffsetMeters: Double, segmentIndex: Int) {
        self.distanceAlongCourseMeters = distanceAlongCourseMeters
        self.lateralOffsetMeters = lateralOffsetMeters
        self.segmentIndex = segmentIndex
    }
}

/// Geometric matcher against a course polyline (map matching v1, ADR scope:
/// no road-network provider needed — the course IS the reference geometry).
///
/// Positions are projected onto polyline segments in a local equirectangular
/// frame (error ≪ GPS noise at course scale). `nearestMatch` scans the whole
/// course; `match(_:near:...)` restricts the scan to a distance window around
/// a cursor so self-crossing or out-and-back courses can't snap progress to
/// the wrong pass.
public struct CourseMatcher: Sendable {
    private struct Segment: Sendable {
        var startX: Double
        var startY: Double
        var deltaX: Double
        var deltaY: Double
        var lengthSquared: Double
        /// Course distance at the segment start, meters.
        var startDistance: Double
        var length: Double
    }

    private let segments: [Segment]
    private let originLatitude: Double
    private let originLongitude: Double
    private let cosLatitude: Double
    public let totalDistanceMeters: Double

    private static let metersPerDegree = 111_195.0

    /// Fails on degenerate polylines (<2 points or zero length).
    public init?(polyline: [GeoCoordinate]) {
        guard polyline.count >= 2, let origin = polyline.first else { return nil }
        originLatitude = origin.latitude
        originLongitude = origin.longitude
        cosLatitude = cos(origin.latitude * .pi / 180)

        func project(_ coordinate: GeoCoordinate) -> (x: Double, y: Double) {
            ((coordinate.longitude - origin.longitude) * Self.metersPerDegree * cos(origin.latitude * .pi / 180),
             (coordinate.latitude - origin.latitude) * Self.metersPerDegree)
        }

        var built: [Segment] = []
        var cumulative = 0.0
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            let pa = project(a)
            let pb = project(b)
            let dx = pb.x - pa.x
            let dy = pb.y - pa.y
            let lengthSquared = dx * dx + dy * dy
            let length = lengthSquared.squareRoot()
            guard length > 0 else { continue }  // skip duplicate points
            built.append(Segment(
                startX: pa.x, startY: pa.y,
                deltaX: dx, deltaY: dy,
                lengthSquared: lengthSquared,
                startDistance: cumulative,
                length: length
            ))
            cumulative += length
        }
        guard cumulative > 0 else { return nil }
        segments = built
        totalDistanceMeters = cumulative
    }

    /// Closest match across the entire course.
    public func nearestMatch(to coordinate: GeoCoordinate) -> CourseMatch {
        match(coordinate, segmentRange: segments.indices)
    }

    /// Closest match within a course-distance window around `cursorMeters` —
    /// the live-tracking form that keeps self-crossing courses honest.
    public func match(
        _ coordinate: GeoCoordinate,
        near cursorMeters: Double,
        backtrackMeters: Double = 100,
        lookaheadMeters: Double = 400
    ) -> CourseMatch {
        let lower = cursorMeters - backtrackMeters
        let upper = cursorMeters + lookaheadMeters
        var first = segments.count - 1
        var last = 0
        for (index, segment) in segments.enumerated() {
            let segmentEnd = segment.startDistance + segment.length
            if segmentEnd >= lower && segment.startDistance <= upper {
                first = min(first, index)
                last = max(last, index)
            }
        }
        guard first <= last else { return nearestMatch(to: coordinate) }
        return match(coordinate, segmentRange: first...last)
    }

    private func match<Range: Sequence>(
        _ coordinate: GeoCoordinate,
        segmentRange: Range
    ) -> CourseMatch where Range.Element == Int {
        let x = (coordinate.longitude - originLongitude) * Self.metersPerDegree * cosLatitude
        let y = (coordinate.latitude - originLatitude) * Self.metersPerDegree

        var best = CourseMatch(
            distanceAlongCourseMeters: 0,
            lateralOffsetMeters: .infinity,
            segmentIndex: 0
        )
        for index in segmentRange {
            let segment = segments[index]
            let relX = x - segment.startX
            let relY = y - segment.startY
            let t = min(1, max(0, (relX * segment.deltaX + relY * segment.deltaY) / segment.lengthSquared))
            let closestX = segment.startX + t * segment.deltaX
            let closestY = segment.startY + t * segment.deltaY
            let offsetX = x - closestX
            let offsetY = y - closestY
            let offset = (offsetX * offsetX + offsetY * offsetY).squareRoot()
            if offset < best.lateralOffsetMeters {
                best = CourseMatch(
                    distanceAlongCourseMeters: segment.startDistance + t * segment.length,
                    lateralOffsetMeters: offset,
                    segmentIndex: index
                )
            }
        }
        return best
    }
}
