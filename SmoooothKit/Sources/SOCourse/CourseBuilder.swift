import Foundation
import SOCore

/// Turns a drive into a publishable course.
///
/// **You make a course by driving it.** That is the only creation route, and
/// it is a deliberate constraint rather than a shortcut: it means nobody can
/// publish a road they have never been down, the geometry is real rather
/// than sketched on a map, and a course that is unsafe or impossible to
/// drive cannot be created by someone who has not tried.
///
/// The output is a *proposal*. The server re-validates every rule with the
/// same shared validator before anything enters the catalog — clients are
/// read-only on `courses`, so this can never be the thing that decides.
public enum CourseBuilder {
    public struct Proposal: Sendable, Equatable {
        public var polyline: [GeoCoordinate]
        public var checkpoints: [Checkpoint]
        public var distanceMeters: Double
        public var turnCount: Int
        /// Seconds the creator actually took. The server derives its own
        /// reference benchmark from geometry; this is only shown back to the
        /// creator so they can sanity-check what they recorded.
        public var recordedSeconds: Double
    }

    public struct Config: Sendable, Equatable {
        /// Simplification tolerance. Small enough to keep the shape of a
        /// corner, large enough that a 20-minute drive is not 12,000 points.
        public var simplifyToleranceMeters: Double
        /// The validator rejects a polyline with any gap over 500 m, so long
        /// straights are re-split below that.
        public var maxSegmentMeters: Double
        /// Five gates at 0/25/50/75/100%, matching the curated catalog.
        public var gateCount: Int
        public var gateRadiusMeters: Double
        /// A heading change beyond this counts as a turn.
        public var turnThresholdDegrees: Double

        public init(
            simplifyToleranceMeters: Double = 8,
            maxSegmentMeters: Double = 400,
            gateCount: Int = 5,
            gateRadiusMeters: Double = 45,
            turnThresholdDegrees: Double = 25
        ) {
            self.simplifyToleranceMeters = simplifyToleranceMeters
            self.maxSegmentMeters = maxSegmentMeters
            self.gateCount = gateCount
            self.gateRadiusMeters = gateRadiusMeters
            self.turnThresholdDegrees = turnThresholdDegrees
        }

        public static let `default` = Config()
    }

    /// Builds a proposal from a recorded drive, or nil when there is not
    /// enough of a drive to make a course from. Validation failures are the
    /// validator's business — this only refuses input it cannot shape at all.
    public static func build(
        from points: [GeoCoordinate],
        recordedSeconds: Double = 0,
        config: Config = .default
    ) -> Proposal? {
        let clean = points.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && abs($0.latitude) <= 90 && abs($0.longitude) <= 180
        }
        guard clean.count >= 2 else { return nil }

        // Drop repeats: a car parked at the line for a minute contributes a
        // hundred identical fixes and no shape.
        var deduped: [GeoCoordinate] = [clean[0]]
        for point in clean.dropFirst() where point.distance(to: deduped[deduped.count - 1]) > 1 {
            deduped.append(point)
        }
        guard deduped.count >= 2 else { return nil }

        let simplified = resample(
            simplify(deduped, tolerance: config.simplifyToleranceMeters),
            maxSegmentMeters: config.maxSegmentMeters
        )
        guard simplified.count >= 2 else { return nil }

        let cumulative = cumulativeDistances(simplified)
        let total = cumulative.last ?? 0
        guard total > 0 else { return nil }

        return Proposal(
            polyline: simplified,
            checkpoints: gates(along: simplified, cumulative: cumulative, config: config),
            distanceMeters: total,
            turnCount: turnCount(simplified, thresholdDegrees: config.turnThresholdDegrees),
            recordedSeconds: recordedSeconds
        )
    }

    // MARK: - Geometry

    /// Ramer–Douglas–Peucker. Keeps the corners, drops the straights.
    static func simplify(_ points: [GeoCoordinate], tolerance: Double) -> [GeoCoordinate] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        // Iterative rather than recursive: a 20-minute drive at 10 Hz is
        // 12,000 points, and recursion on that risks the stack.
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first
            var maxDistance = 0.0
            for index in (first + 1)..<last {
                let distance = perpendicularDistance(
                    points[index], from: points[first], to: points[last]
                )
                if distance > maxDistance {
                    maxDistance = distance
                    farthest = index
                }
            }
            if maxDistance > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    /// Distance from `point` to the segment a→b, in metres. Local flat-earth
    /// projection: over a segment of a road the error is far below the
    /// tolerance this feeds.
    static func perpendicularDistance(
        _ point: GeoCoordinate,
        from a: GeoCoordinate,
        to b: GeoCoordinate
    ) -> Double {
        let cosLat = cos(a.latitude * .pi / 180)
        let metresPerDegree = 111_320.0
        let ax = 0.0, ay = 0.0
        let bx = (b.longitude - a.longitude) * cosLat * metresPerDegree
        let by = (b.latitude - a.latitude) * metresPerDegree
        let px = (point.longitude - a.longitude) * cosLat * metresPerDegree
        let py = (point.latitude - a.latitude) * metresPerDegree

        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (px * px + py * py).squareRoot() }
        var t = (px * dx + py * dy) / lengthSquared
        t = min(max(t, 0), 1)
        let cx = t * dx, cy = t * dy
        return ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
    }

    /// Splits any segment longer than the limit. Simplification can leave a
    /// single 3 km straight, which the validator rejects as excessive point
    /// spacing — correctly, since a two-point straight cannot be matched
    /// against.
    static func resample(_ points: [GeoCoordinate], maxSegmentMeters: Double) -> [GeoCoordinate] {
        guard points.count >= 2, maxSegmentMeters > 0 else { return points }
        var out: [GeoCoordinate] = [points[0]]
        for (a, b) in zip(points, points.dropFirst()) {
            let span = a.distance(to: b)
            if span > maxSegmentMeters {
                let steps = Int((span / maxSegmentMeters).rounded(.up))
                for step in 1..<steps {
                    let t = Double(step) / Double(steps)
                    out.append(GeoCoordinate(
                        latitude: a.latitude + (b.latitude - a.latitude) * t,
                        longitude: a.longitude + (b.longitude - a.longitude) * t
                    ))
                }
            }
            out.append(b)
        }
        return out
    }

    static func cumulativeDistances(_ points: [GeoCoordinate]) -> [Double] {
        var out: [Double] = [0]
        out.reserveCapacity(points.count)
        for (a, b) in zip(points, points.dropFirst()) {
            out.append(out[out.count - 1] + a.distance(to: b))
        }
        return out
    }

    /// Gates at even fractions of the route, snapped to real vertices so
    /// they sit exactly ON the line — the validator checks that, and a gate
    /// interpolated between vertices can miss by more than its tolerance.
    static func gates(
        along points: [GeoCoordinate],
        cumulative: [Double],
        config: Config
    ) -> [Checkpoint] {
        let total = cumulative.last ?? 0
        let count = max(2, config.gateCount)
        var used = Set<Int>()
        var out: [Checkpoint] = []
        for index in 0..<count {
            let target = total * Double(index) / Double(count - 1)
            var vertex = nearestVertex(to: target, in: cumulative)
            // Two gates on the same vertex would be zero apart; nudge to the
            // next unused one so the sequence stays strictly increasing.
            while used.contains(vertex) && vertex + 1 < points.count { vertex += 1 }
            used.insert(vertex)
            out.append(Checkpoint(
                sequence: index,
                center: points[vertex],
                radiusMeters: config.gateRadiusMeters
            ))
        }
        return out
    }

    static func nearestVertex(to distance: Double, in cumulative: [Double]) -> Int {
        var best = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (index, value) in cumulative.enumerated() {
            let delta = abs(value - distance)
            if delta < bestDelta {
                bestDelta = delta
                best = index
            }
        }
        return best
    }

    /// Counts direction changes. Used for the catalog's turn count, which
    /// also feeds the derived benchmark — a twistier road gets a slower
    /// reference pace.
    static func turnCount(_ points: [GeoCoordinate], thresholdDegrees: Double) -> Int {
        guard points.count >= 3 else { return 0 }
        var turns = 0
        var previous = points[0].bearing(to: points[1])
        for index in 1..<(points.count - 1) {
            let bearing = points[index].bearing(to: points[index + 1])
            var delta = abs(bearing - previous)
            if delta > 180 { delta = 360 - delta }
            if delta >= thresholdDegrees {
                turns += 1
                previous = bearing
            }
        }
        return turns
    }
}
