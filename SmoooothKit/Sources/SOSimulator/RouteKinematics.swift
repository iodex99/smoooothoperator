import Foundation
import SOCore

/// A route polyline prepared for kinematic queries: cumulative distances,
/// per-segment headings, and per-vertex signed curvature.
/// Curvature sign convention: positive = heading increasing = RIGHT turn.
struct RoutePath: Sendable {
    struct Vertex: Sendable {
        var coordinate: GeoCoordinate
        /// Path distance from the route start, meters.
        var distance: Double
        /// Heading of the segment LEAVING this vertex (last vertex: of the
        /// segment arriving), degrees from north.
        var heading: Double
        /// Signed curvature at this vertex, 1/m (+ = right turn).
        var curvature: Double
    }

    let vertices: [Vertex]
    let totalDistance: Double

    /// Fails on degenerate input (fewer than 2 distinct points).
    init?(route: [GeoCoordinate]) {
        guard route.count >= 2 else { return nil }

        var cumulative = 0.0
        var headings: [Double] = []
        var distances: [Double] = [0]
        for (a, b) in zip(route, route.dropFirst()) {
            headings.append(a.bearing(to: b))
            cumulative += a.distance(to: b)
            distances.append(cumulative)
        }
        guard cumulative > 0 else { return nil }

        var vertices: [Vertex] = []
        for index in route.indices {
            // Heading leaving this vertex; the final vertex keeps the
            // arriving segment's heading.
            let heading = index < headings.count ? headings[index] : headings[headings.count - 1]

            // Curvature from the heading change across this vertex, spread
            // over the mean of the adjacent segment lengths.
            var curvature = 0.0
            if index > 0 && index < headings.count {
                let turn = Self.signedAngleDelta(from: headings[index - 1], to: headings[index])
                let before = distances[index] - distances[index - 1]
                let after = distances[index + 1] - distances[index]
                let span = (before + after) / 2
                if span > 0 {
                    curvature = (turn * .pi / 180) / span
                }
            }
            vertices.append(Vertex(
                coordinate: route[index],
                distance: distances[index],
                heading: heading,
                curvature: curvature
            ))
        }

        self.vertices = vertices
        self.totalDistance = cumulative
    }

    /// Shortest signed angle from `a` to `b`, degrees in (-180, 180].
    static func signedAngleDelta(from a: Double, to b: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }

    /// Index of the segment containing path distance `s` (binary search).
    private func segmentIndex(at s: Double) -> Int {
        var low = 0
        var high = vertices.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if vertices[mid].distance <= s { low = mid } else { high = mid }
        }
        return low
    }

    func coordinate(at s: Double) -> GeoCoordinate {
        let clamped = min(max(s, 0), totalDistance)
        let index = segmentIndex(at: clamped)
        let vertex = vertices[index]
        return vertex.coordinate.destination(
            bearingDegrees: vertex.heading,
            distanceMeters: clamped - vertex.distance
        )
    }

    func heading(at s: Double) -> Double {
        vertices[segmentIndex(at: min(max(s, 0), totalDistance))].heading
    }

    /// Curvature linearly interpolated between vertices.
    func curvature(at s: Double) -> Double {
        let clamped = min(max(s, 0), totalDistance)
        let index = segmentIndex(at: clamped)
        let a = vertices[index]
        let b = vertices[min(index + 1, vertices.count - 1)]
        let span = b.distance - a.distance
        guard span > 0 else { return a.curvature }
        let t = (clamped - a.distance) / span
        return a.curvature + t * (b.curvature - a.curvature)
    }
}

/// One instant of kinematic ground truth along the route.
struct GroundTruthState: Sendable {
    /// Seconds since the run start (movement begins after the stationary lead).
    var time: Double
    /// Path distance, meters.
    var distance: Double
    /// Speed, m/s.
    var speed: Double
    /// Longitudinal acceleration, m/s².
    var acceleration: Double
    /// Heading, degrees from north.
    var heading: Double
    /// Signed curvature at this point, 1/m (+ = right turn).
    var curvature: Double
}

/// Integrates profile dynamics along a route into ground-truth states.
struct GroundTruthIntegrator: Sendable {
    let path: RoutePath
    let dynamics: ProfileDynamics

    /// Corner-speed plan: per-vertex speed ceiling from lateral budget, with
    /// a backward pass so braking anticipates corners within the brake limit.
    private func speedPlan() -> [Double] {
        var plan = path.vertices.map { vertex in
            let curvature = abs(vertex.curvature)
            guard curvature > 1e-6 else { return dynamics.vMaxMps }
            return min(dynamics.vMaxMps, (dynamics.maxLateralMps2 / curvature).squareRoot())
        }
        // Roll through the finish at low speed rather than stopping on it.
        plan[plan.count - 1] = min(plan[plan.count - 1], 2.0)

        for index in stride(from: plan.count - 2, through: 0, by: -1) {
            let ds = path.vertices[index + 1].distance - path.vertices[index].distance
            let reachable = (plan[index + 1] * plan[index + 1] + 2 * dynamics.maxBrakeMps2 * ds).squareRoot()
            plan[index] = min(plan[index], reachable)
        }
        return plan
    }

    private func targetSpeed(at s: Double, plan: [Double]) -> Double {
        let clamped = min(max(s, 0), path.totalDistance)
        var low = 0
        var high = path.vertices.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if path.vertices[mid].distance <= clamped { low = mid } else { high = mid }
        }
        let a = path.vertices[low]
        let b = path.vertices[min(low + 1, path.vertices.count - 1)]
        let span = b.distance - a.distance
        guard span > 0 else { return plan[low] }
        let t = (clamped - a.distance) / span
        return plan[low] + t * (plan[min(low + 1, plan.count - 1)] - plan[low])
    }

    /// Integrates from rest at the route start until the finish line (or a
    /// hard 1-hour cap), at `hz` steps per second. `time` starts at 0.
    func integrate(hz: Double, oscillationPhaseSeconds: Double = 2.0) -> [GroundTruthState] {
        let dt = 1 / hz
        let plan = speedPlan()
        let followTau = 0.6  // seconds to close the speed error at the limit

        var states: [GroundTruthState] = []
        var s = 0.0
        var v = 0.0
        var a = 0.0
        var t = 0.0

        while s < path.totalDistance - 0.5 && t < 3600 {
            let target = targetSpeed(at: s, plan: plan)
            let error = target - v
            var desired = error / followTau
            if dynamics.oscillationMps2 > 0 && v > 1 {
                desired += dynamics.oscillationMps2 * sin(2 * .pi * t / oscillationPhaseSeconds)
            }
            // Jerk-aware anticipation: never carry more acceleration toward
            // the target speed than the jerk limit can unwind in time —
            // otherwise smooth (low-jerk) profiles overshoot their own plan.
            let approachBound = (2 * dynamics.jerkLimitMps3 * max(error, 0)).squareRoot()
            let brakeApproachBound = -(2 * dynamics.jerkLimitMps3 * max(-error, 0)).squareRoot()
            desired = min(max(desired, brakeApproachBound), approachBound)
            desired = min(max(desired, -dynamics.maxBrakeMps2), dynamics.maxAccelMps2)

            // Jerk limit: commanded acceleration slews toward the desired value.
            let maxDelta = dynamics.jerkLimitMps3 * dt
            a += min(max(desired - a, -maxDelta), maxDelta)

            v = max(0, v + a * dt)
            s = min(path.totalDistance, s + v * dt)
            t += dt

            states.append(GroundTruthState(
                time: t,
                distance: s,
                speed: v,
                acceleration: a,
                heading: path.heading(at: s),
                curvature: path.curvature(at: s)
            ))
        }
        return states
    }
}
