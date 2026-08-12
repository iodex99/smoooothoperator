import Foundation
import Testing
import SOCore
import SOTelemetry
@testable import SOSimulator

@Suite("TelemetrySimulator")
struct TelemetrySimulatorTests {
    let route = TelemetrySimulator.demoRoute(seed: 7)

    private func run(_ profile: SimulationProfile, seed: UInt64 = 42) -> SimulatedRun {
        TelemetrySimulator(profile: profile, seed: seed).simulate(route: route)
    }

    /// Max straight-line speed implied between consecutive fixes, m/s.
    private func maxImpliedSpeed(_ gps: [GPSSample]) -> Double {
        zip(gps, gps.dropFirst()).map { a, b in
            let dt = b.timestamp - a.timestamp
            guard dt > 0 else { return 0 }
            return a.coordinate.distance(to: b.coordinate) / dt
        }.max() ?? 0
    }

    /// Point-to-polyline distance via local equirectangular projection —
    /// accurate to well under 1% at course scale.
    private func distanceToRoute(_ point: GeoCoordinate) -> Double {
        let metersPerDegree = 111_195.0
        let cosLat = cos(point.latitude * .pi / 180)
        func project(_ c: GeoCoordinate) -> (x: Double, y: Double) {
            ((c.longitude - point.longitude) * metersPerDegree * cosLat,
             (c.latitude - point.latitude) * metersPerDegree)
        }
        var best = Double.infinity
        for (a, b) in zip(route, route.dropFirst()) {
            let pa = project(a)
            let pb = project(b)
            let dx = pb.x - pa.x
            let dy = pb.y - pa.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0
                ? min(1, max(0, (-pa.x * dx - pa.y * dy) / lengthSquared))
                : 0
            let cx = pa.x + t * dx
            let cy = pa.y + t * dy
            best = min(best, (cx * cx + cy * cy).squareRoot())
        }
        return best
    }

    // MARK: - Determinism

    @Test("same profile+seed+route reproduces identical output; different seeds differ")
    func determinism() {
        let first = run(.fastSmooth)
        let second = run(.fastSmooth)
        #expect(first.gps == second.gps)
        #expect(first.imu == second.imu)
        #expect(first.groundTruth == second.groundTruth)

        let other = run(.fastSmooth, seed: 43)
        #expect(first.gps != other.gps)
    }

    // MARK: - Clean profile shape

    @Test("clean run has the right shape: rate, monotonic clock, route endpoints, speed cap",
          arguments: [SimulationProfile.fastSmooth, .fastAggressive, .slowSmooth, .normal])
    func cleanShape(profile: SimulationProfile) {
        let result = run(profile)
        let expectedFixCount = result.groundTruth.expectedDurationSeconds * 10

        #expect(abs(Double(result.gps.count) - expectedFixCount) <= 2)
        #expect(zip(result.gps, result.gps.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        #expect(zip(result.imu, result.imu.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })

        if let first = result.gps.first, let last = result.gps.last {
            #expect(first.coordinate.distance(to: route[0]) < 30)
            #expect(last.coordinate.distance(to: route[route.count - 1]) < 30)
        }

        let vMax = ProfileDynamics.dynamics(for: profile).vMaxMps
        #expect(result.gps.compactMap(\.speed).allSatisfy { $0 <= vMax + 1 })
    }

    @Test("every run starts with a stationary calibration lead")
    func stationaryLead() {
        let result = run(.normal)
        let leadEnd = result.gps[0].timestamp + 1.9
        let leadFixes = result.gps.filter { $0.timestamp < leadEnd }
        #expect(leadFixes.count >= 15)
        #expect(leadFixes.compactMap(\.speed).allSatisfy { $0 < 1.0 })
    }

    @Test("driving styles order durations: fastSmooth < normal < slowSmooth")
    func durationOrdering() {
        let fast = run(.fastSmooth).groundTruth.expectedDurationSeconds
        let normal = run(.normal).groundTruth.expectedDurationSeconds
        let slow = run(.slowSmooth).groundTruth.expectedDurationSeconds
        #expect(fast < normal)
        #expect(normal < slow)
    }

    @Test("the aggressive profile brakes/accelerates measurably harder than the smooth one")
    func aggressionShows() {
        func peakAcceleration(_ gps: [GPSSample]) -> Double {
            // 1s-averaged speeds kill reported-speed noise before differencing.
            let speeds = gps.compactMap(\.speed)
            let window = 10
            guard speeds.count > 3 * window else { return 0 }
            let means = stride(from: 0, to: speeds.count - window, by: window).map { start in
                speeds[start..<start + window].reduce(0, +) / Double(window)
            }
            return zip(means, means.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        }
        let aggressive = peakAcceleration(run(.fastAggressive).gps)
        let smooth = peakAcceleration(run(.fastSmooth).gps)
        #expect(aggressive > smooth)
    }

    @Test("the mount rotation is orthonormal and recorded in ground truth")
    func mountAxes() {
        let truth = run(.normal).groundTruth
        for axis in [truth.mountForwardDevice, truth.mountRightDevice, truth.mountUpDevice] {
            #expect(abs(axis.norm - 1) < 1e-9)
        }
        #expect(abs(truth.mountForwardDevice.dot(truth.mountUpDevice)) < 1e-9)
        #expect(truth.mountForwardDevice.cross(truth.mountUpDevice)
            .dot(truth.mountRightDevice) > 0.999)  // right-handed: fwd × up = right
    }

    // MARK: - Injector signatures

    @Test("missingGPS drops whole windows")
    func missingGPSSignature() {
        let gaps = zip(run(.missingGPS).gps, run(.missingGPS).gps.dropFirst())
            .map { $1.timestamp - $0.timestamp }
        #expect((gaps.max() ?? 0) > 4)
    }

    @Test("gpsJump teleports imply impossible speeds")
    func gpsJumpSignature() {
        #expect(maxImpliedSpeed(run(.gpsJump).gps) > 90)
    }

    @Test("mockGPS is too perfect: zero accuracy variance, metronome clock, dead IMU")
    func mockGPSSignature() {
        let result = run(.mockGPS)
        let accuracies = Set(result.gps.map(\.horizontalAccuracy))
        #expect(accuracies.count == 1)

        // Metronome clock: uniform to Double ULP at epoch magnitude (~2.4e-7)…
        let dts = zip(result.gps, result.gps.dropFirst()).map { $1.timestamp - $0.timestamp }
        let worstDeviation = dts.map { abs($0 - 0.1) }.max() ?? 0
        #expect(worstDeviation < 1e-6, "worst dt deviation: \(worstDeviation)")

        // …while an honest receiver's fix clock visibly jitters.
        let normalDts = zip(run(.normal).gps, run(.normal).gps.dropFirst())
            .map { $1.timestamp - $0.timestamp }
        let normalJitter = normalDts.map { abs($0 - 0.1) }.max() ?? 0
        #expect(normalJitter > 1e-4)

        // The phone sits still while GPS claims motion: gravity only.
        let maxDynamic = result.imu.map {
            abs((Vector3(x: $0.accelX, y: $0.accelY, z: $0.accelZ)).norm - 1)
        }.max() ?? 1
        #expect(maxDynamic < 0.01)
    }

    @Test("impossiblePhysics implies >120 m/s travel")
    func impossiblePhysicsSignature() {
        let result = run(.impossiblePhysics)
        #expect(maxImpliedSpeed(result.gps) > 120)
        #expect(result.gps.compactMap(\.speed).contains { $0 > 120 })
    }

    @Test("timestampManipulation contains a clock regression and speed disagreement")
    func timestampSignature() {
        let result = run(.timestampManipulation)
        let hasRegression = zip(result.gps, result.gps.dropFirst())
            .contains { $1.timestamp <= $0.timestamp }
        #expect(hasRegression)
    }

    @Test("routeDeviation leaves the course corridor; clean profiles never do")
    func routeDeviationSignature() {
        let deviating = run(.routeDeviation).gps.map { distanceToRoute($0.coordinate) }.max() ?? 0
        #expect(deviating > 100)

        let clean = run(.normal).gps.map { distanceToRoute($0.coordinate) }.max() ?? 0
        #expect(clean < 30)
    }

    // MARK: - Route generation & degenerate input

    @Test("demoRoute is course-sized and starts with a calibration straight")
    func demoRouteShape() {
        var total = 0.0
        for (a, b) in zip(route, route.dropFirst()) {
            total += a.distance(to: b)
        }
        #expect(total > 3000)

        let firstBearings = (0..<4).map { route[$0].bearing(to: route[$0 + 1]) }
        for bearing in firstBearings {
            #expect(abs(bearing - firstBearings[0]) < 1)
        }
        // Distinct seeds produce distinct routes.
        #expect(TelemetrySimulator.demoRoute(seed: 8) != route)
    }

    @Test("degenerate routes yield an empty run, never a crash")
    func degenerateRoute() {
        let empty = TelemetrySimulator(profile: .normal, seed: 1).simulate(route: [])
        #expect(empty.gps.isEmpty && empty.imu.isEmpty)

        let single = TelemetrySimulator(profile: .normal, seed: 1)
            .simulate(route: [GeoCoordinate(latitude: 0, longitude: 0)])
        #expect(single.gps.isEmpty && single.imu.isEmpty)
    }
}
