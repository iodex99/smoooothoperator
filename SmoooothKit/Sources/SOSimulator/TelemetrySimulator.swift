import Foundation
import SOCore
import SOTelemetry

/// What the simulator knows to be true about the run it generated — the
/// reference against which pipeline output is asserted in tests and golden
/// fixtures.
public struct SimulationGroundTruth: Codable, Sendable, Equatable {
    public var profile: SimulationProfile
    public var seed: UInt64
    /// Polyline length of the route, meters.
    public var routeDistanceMeters: Double
    /// Stationary lead + movement time, seconds.
    public var expectedDurationSeconds: Double
    /// Vehicle axes expressed in the device frame used to rotate the IMU.
    public var mountForwardDevice: Vector3
    public var mountRightDevice: Vector3
    public var mountUpDevice: Vector3
}

/// One simulated run: raw sensor streams shaped exactly like the platform
/// adapters produce, plus ground truth.
public struct SimulatedRun: Sendable {
    public var gps: [GPSSample]
    public var imu: [IMUSample]
    public var groundTruth: SimulationGroundTruth
}

/// Development-only synthetic telemetry source (spec §58).
///
/// Produces GPS+IMU streams indistinguishable in *shape* from the real
/// platform adapters, so they exercise the exact production pipeline:
/// clean driving-style profiles differ in kinematic limits and jerk;
/// degraded-signal and cheat profiles drive like `.normal` and corrupt the
/// emission layer. Fully deterministic per (profile, seed, route, config).
public struct TelemetrySimulator: Sendable {
    public let profile: SimulationProfile
    public let seed: UInt64
    public let config: SimulationConfig

    public init(profile: SimulationProfile, seed: UInt64, config: SimulationConfig = .default) {
        self.profile = profile
        self.seed = seed
        self.config = config
    }

    // MARK: - Route generation

    /// A deterministic ~4 km winding demo route. Starts with ≥400 m of
    /// straight so orientation calibration always has its window.
    public static func demoRoute(seed: UInt64) -> [GeoCoordinate] {
        var rng = SeededRandomNumberGenerator(seed: seed)
        var route = [GeoCoordinate(latitude: 34.0259, longitude: -118.7798)]
        var heading = 40.0

        for _ in 0..<4 {  // 400 m calibration straight
            route.append(route[route.count - 1].destination(bearingDegrees: heading, distanceMeters: 100))
        }
        for segment in 0..<18 {
            let turn = segment % 4 == 3
                ? Double.random(in: -5...5, using: &rng)          // breather straight
                : Double.random(in: -38...38, using: &rng)         // real corner
            heading += turn
            let length = Double.random(in: 120...350, using: &rng)
            route.append(route[route.count - 1].destination(bearingDegrees: heading, distanceMeters: length))
        }
        return route
    }

    // MARK: - Simulation

    public func simulate(route: [GeoCoordinate]) -> SimulatedRun {
        // Independent deterministic streams so adding noise draws in one
        // place never shifts another stream's sequence.
        var mountRng = GaussianRandom(seed: seed &* 0x9E37_79B9 &+ 1)
        var noise = GaussianRandom(seed: seed &* 0x9E37_79B9 &+ 2)
        var injector = GaussianRandom(seed: seed &* 0x9E37_79B9 &+ 3)

        let mount = Self.randomMount(using: &mountRng)

        guard let path = RoutePath(route: route) else {
            return SimulatedRun(gps: [], imu: [], groundTruth: SimulationGroundTruth(
                profile: profile, seed: seed, routeDistanceMeters: 0,
                expectedDurationSeconds: 0,
                mountForwardDevice: mount.forward,
                mountRightDevice: mount.right,
                mountUpDevice: mount.up
            ))
        }

        let dynamics = ProfileDynamics.dynamics(for: profile)
        let movement = GroundTruthIntegrator(path: path, dynamics: dynamics).integrate(hz: config.imuHz)

        // Stationary lead-in states (calibration window, spec §16).
        let dt = 1 / config.imuHz
        let leadCount = Int(config.stationaryLeadSeconds * config.imuHz)
        let initialHeading = path.heading(at: 0)
        var states: [GroundTruthState] = (0..<leadCount).map { index in
            GroundTruthState(time: Double(index + 1) * dt - config.stationaryLeadSeconds,
                             distance: 0, speed: 0, acceleration: 0,
                             heading: initialHeading, curvature: 0)
        }
        states += movement

        let mock = profile == .mockGPS
        let imuScale = profile == .sensorDisagreement ? 2.5 : 1.0
        let gpsStride = max(1, Int((config.imuHz / config.gpsHz).rounded()))

        var gps: [GPSSample] = []
        var imu: [IMUSample] = []
        var fixFractions: [Double] = []   // path progress per emitted fix (injector input)
        var fixHeadings: [Double] = []

        for (index, state) in states.enumerated() {
            let timestamp = config.startTimestamp + config.stationaryLeadSeconds + state.time

            // IMU — vehicle frame dynamics, then rotated into the mount.
            let longitudinal = mock ? 0 : (state.acceleration / 9.81 + noise.next(sigma: config.imuAccelNoiseG)) * imuScale
            let lateral = mock ? 0 : (state.speed * state.speed * state.curvature / 9.81 + noise.next(sigma: config.imuAccelNoiseG)) * imuScale
            let vertical = mock ? 0 : noise.next(sigma: config.imuAccelNoiseG) * imuScale
            let yawRate = mock ? 0 : (-state.speed * state.curvature + noise.next(sigma: config.imuGyroNoiseRadPerSec)) * imuScale

            let reading = (-mount.up)
                + mount.forward.scaled(by: longitudinal)
                + mount.right.scaled(by: lateral)
                + mount.up.scaled(by: vertical)
            let gyro = mount.up.scaled(by: yawRate)
            imu.append(IMUSample(
                timestamp: timestamp,
                accelX: reading.x + (mock ? noise.next(sigma: 0.001) : 0),
                accelY: reading.y,
                accelZ: reading.z,
                gyroX: gyro.x, gyroY: gyro.y,
                gyroZ: gyro.z + (mock ? noise.next(sigma: 0.0005) : 0)
            ))

            // GPS at the configured divisor of the IMU rate. Real receivers
            // jitter their fix clock by milliseconds; a perfectly uniform
            // clock is a mock-GPS signature (integrity engine input).
            guard index % gpsStride == 0 else { continue }
            var fixTimestamp = timestamp
            if !mock {
                fixTimestamp += noise.next(sigma: 0.005)
                if let previous = gps.last?.timestamp, fixTimestamp <= previous {
                    fixTimestamp = previous + 0.001
                }
            }
            var coordinate = path.coordinate(at: state.distance)
            if !mock {
                coordinate = Self.offset(
                    coordinate,
                    north: noise.next(sigma: config.gpsPositionNoiseMeters),
                    east: noise.next(sigma: config.gpsPositionNoiseMeters)
                )
            }
            let speed = mock ? state.speed : max(0, state.speed + noise.next(sigma: config.gpsSpeedNoiseMps))
            let accuracy = mock
                ? config.gpsAccuracyMeters
                : max(1, config.gpsAccuracyMeters + noise.next(sigma: 1.2))
            gps.append(GPSSample(
                timestamp: fixTimestamp,
                coordinate: coordinate,
                altitude: 50,
                horizontalAccuracy: accuracy,
                course: state.speed > 0.5 ? state.heading : nil,
                speed: speed
            ))
            fixFractions.append(path.totalDistance > 0 ? state.distance / path.totalDistance : 0)
            fixHeadings.append(state.heading)
        }

        gps = applyInjector(to: gps, fractions: fixFractions, headings: fixHeadings, rng: &injector)

        return SimulatedRun(
            gps: gps,
            imu: imu,
            groundTruth: SimulationGroundTruth(
                profile: profile,
                seed: seed,
                routeDistanceMeters: path.totalDistance,
                expectedDurationSeconds: config.stationaryLeadSeconds + (movement.last?.time ?? 0),
                mountForwardDevice: mount.forward,
                mountRightDevice: mount.right,
                mountUpDevice: mount.up
            )
        )
    }

    // MARK: - Degradation & cheat injectors

    private func applyInjector(
        to fixes: [GPSSample],
        fractions: [Double],
        headings: [Double],
        rng: inout GaussianRandom
    ) -> [GPSSample] {
        guard fixes.count > 20 else { return fixes }
        var output = fixes

        switch profile {
        case .fastSmooth, .fastAggressive, .slowSmooth, .normal, .mockGPS, .sensorDisagreement:
            break  // clean emission (mock/sensor handled at emission time)

        case .gpsDrift:
            var biasNorth = 0.0
            var biasEast = 0.0
            for index in output.indices {
                biasNorth += rng.next(sigma: 0.5)
                biasEast += rng.next(sigma: 0.5)
                let magnitude = (biasNorth * biasNorth + biasEast * biasEast).squareRoot()
                if magnitude > 25 {
                    biasNorth *= 25 / magnitude
                    biasEast *= 25 / magnitude
                }
                output[index].coordinate = Self.offset(output[index].coordinate, north: biasNorth, east: biasEast)
            }

        case .gpsJump:
            let windowFixes = Int(2 * config.gpsHz)
            for _ in 0..<3 {
                let start = rng.uniformInt(in: (output.count / 5)...(output.count * 4 / 5))
                let north = rng.uniform(in: 30...80) * (rng.uniform(in: -1...1) < 0 ? -1 : 1)
                let east = rng.uniform(in: 30...80) * (rng.uniform(in: -1...1) < 0 ? -1 : 1)
                for index in start..<min(start + windowFixes, output.count) {
                    output[index].coordinate = Self.offset(output[index].coordinate, north: north, east: east)
                }
            }

        case .missingGPS:
            var drop = Set<Int>()
            for _ in 0..<3 {
                let start = rng.uniformInt(in: (output.count / 5)...(output.count * 3 / 4))
                let length = Int(rng.uniform(in: 5...15) * config.gpsHz)
                drop.formUnion(start..<min(start + length, output.count))
            }
            output = output.enumerated().filter { !drop.contains($0.offset) }.map(\.element)

        case .routeDeviation:
            for index in output.indices {
                let fraction = fractions[index]
                guard fraction > 0.4 && fraction < 0.6 else { continue }
                let magnitude = 250 * sin(.pi * (fraction - 0.4) / 0.2)
                output[index].coordinate = output[index].coordinate.destination(
                    bearingDegrees: headings[index] + 90,
                    distanceMeters: magnitude
                )
            }

        case .impossiblePhysics:
            // A 2s burst of ~150 m/s "travel", then an instant snap back.
            let start = rng.uniformInt(in: (output.count / 3)...(output.count / 2))
            let windowFixes = Int(2 * config.gpsHz)
            for (offsetIndex, index) in (start..<min(start + windowFixes, output.count)).enumerated() {
                let along = 150.0 * Double(offsetIndex + 1) / config.gpsHz
                output[index].coordinate = output[index].coordinate.destination(
                    bearingDegrees: headings[index],
                    distanceMeters: along
                )
                output[index].speed = 150 + rng.uniform(in: 0...50)
            }

        case .timestampManipulation:
            // Compress the second half's clock so implied speeds disagree
            // with reported speeds, plus one outright regression.
            let midpoint = output.count / 2
            let midTime = output[midpoint].timestamp
            for index in (midpoint + 1)..<output.count {
                output[index].timestamp = midTime + (output[index].timestamp - midTime) * 0.75
            }
            let regressionIndex = min(midpoint + 10, output.count - 1)
            output[regressionIndex].timestamp = output[regressionIndex - 1].timestamp - 0.05
        }

        return output
    }

    // MARK: - Helpers

    struct MountAxes: Sendable {
        var forward: Vector3
        var right: Vector3
        var up: Vector3
    }

    /// Uniformly random rigid rotation of the canonical vehicle triad
    /// (forward=+Y, right=+X, up=+Z) via Rodrigues' formula.
    static func randomMount(using rng: inout GaussianRandom) -> MountAxes {
        let axis = Vector3(x: rng.next(sigma: 1), y: rng.next(sigma: 1), z: rng.next(sigma: 1))
            .normalized() ?? Vector3(x: 0, y: 0, z: 1)
        let angle = rng.uniform(in: 0...(2 * .pi))

        func rotate(_ vector: Vector3) -> Vector3 {
            let cosA = cos(angle)
            let sinA = sin(angle)
            return vector.scaled(by: cosA)
                + axis.cross(vector).scaled(by: sinA)
                + axis.scaled(by: axis.dot(vector) * (1 - cosA))
        }

        return MountAxes(
            forward: rotate(Vector3(x: 0, y: 1, z: 0)),
            right: rotate(Vector3(x: 1, y: 0, z: 0)),
            up: rotate(Vector3(x: 0, y: 0, z: 1))
        )
    }

    /// Offsets a coordinate by metric north/east components.
    static func offset(_ coordinate: GeoCoordinate, north: Double, east: Double) -> GeoCoordinate {
        let distance = (north * north + east * east).squareRoot()
        guard distance > 0 else { return coordinate }
        let bearing = atan2(east, north) * 180 / .pi
        return coordinate.destination(bearingDegrees: (bearing + 360).truncatingRemainder(dividingBy: 360),
                                      distanceMeters: distance)
    }
}
