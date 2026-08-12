import Foundation
import Testing
import SOCore
@testable import SOTelemetry

// MARK: - Test helpers

/// A rigid mount rotation taking vehicle-frame vectors into the device frame.
private struct MountRotation {
    /// Unit rotation axis.
    var axis: Vector3
    var angleRadians: Double

    /// Rodrigues' rotation formula: v cosθ + (k×v) sinθ + k(k·v)(1−cosθ).
    func rotate(_ v: Vector3) -> Vector3 {
        let c = cos(angleRadians)
        let s = sin(angleRadians)
        return v.scaled(by: c)
            + axis.cross(v).scaled(by: s)
            + axis.scaled(by: axis.dot(v) * (1 - c))
    }

    static let identity = MountRotation(axis: Vector3(x: 0, y: 0, z: 1), angleRadians: 0)

    /// Uniformly random axis (uniform on the sphere) and angle in 0..<2π.
    static func random(using rng: inout SeededRandomNumberGenerator) -> MountRotation {
        let z = Double.random(in: -1...1, using: &rng)
        let phi = Double.random(in: 0..<(2 * Double.pi), using: &rng)
        let r = max(0, 1 - z * z).squareRoot()
        let axis = Vector3(x: r * cos(phi), y: r * sin(phi), z: z)
        let angle = Double.random(in: 0..<(2 * Double.pi), using: &rng)
        return MountRotation(axis: axis, angleRadians: angle)
    }
}

/// Vehicle-frame conventions: with the device aligned to the vehicle,
/// forward = +Y, up = +Z, right = +X (right-handed).
private let vehicleForward = Vector3(x: 0, y: 1, z: 0)
private let vehicleRight = Vector3(x: 1, y: 0, z: 0)
private let vehicleUp = Vector3(x: 0, y: 0, z: 1)
private let gravityMps2 = 9.81
private let runStart = 1_755_000_000.0
private let baseCoordinate = GeoCoordinate(latitude: 37.334, longitude: -122.009)

private func randomVector(halfWidth: Double, using rng: inout SeededRandomNumberGenerator) -> Vector3 {
    Vector3(
        x: .random(in: -halfWidth...halfWidth, using: &rng),
        y: .random(in: -halfWidth...halfWidth, using: &rng),
        z: .random(in: -halfWidth...halfWidth, using: &rng)
    )
}

/// Scripts the spec §16 calibration flow in the vehicle frame — a steady
/// phase (constant speed, 1 g gravity only) followed by a constant
/// longitudinal-acceleration phase with a matching 1 Hz GPS speed ramp —
/// then rotates all IMU into the device frame through `rotation` and adds
/// seeded sensor noise. IMU runs at 50 Hz.
private func calibrationRun(
    rotation: MountRotation,
    rng: inout SeededRandomNumberGenerator,
    initialSpeedMps: Double = 0,
    longitudinalG: Double = 0.3,
    yawRateRadPerSec: Double = 0,
    steadySeconds: Double = 2,
    maneuverSeconds: Double = 6,
    accelNoiseG: Double = 0.02,
    gyroNoiseRadPerSec: Double = 0.005,
    horizontalAccuracy: Double = 5
) -> (imu: [IMUSample], gps: [GPSSample]) {
    let imuHz = 50.0
    let total = steadySeconds + maneuverSeconds

    var imu: [IMUSample] = []
    for i in 0...Int(total * imuHz) {
        let rel = Double(i) / imuHz
        let maneuvering = rel >= steadySeconds && rel < total
        // Raw reading = unit down vector + true acceleration (in g).
        let readingVehicle = Vector3(x: 0, y: maneuvering ? longitudinalG : 0, z: -1)
        let gyroVehicle = Vector3(x: 0, y: 0, z: maneuvering ? yawRateRadPerSec : 0)
        let reading = rotation.rotate(readingVehicle) + randomVector(halfWidth: accelNoiseG, using: &rng)
        let gyro = rotation.rotate(gyroVehicle) + randomVector(halfWidth: gyroNoiseRadPerSec, using: &rng)
        imu.append(IMUSample(
            timestamp: runStart + rel,
            accelX: reading.x, accelY: reading.y, accelZ: reading.z,
            gyroX: gyro.x, gyroY: gyro.y, gyroZ: gyro.z
        ))
    }

    var gps: [GPSSample] = []
    for k in 0...Int(total) {
        let rel = Double(k)
        let speed = initialSpeedMps
            + longitudinalG * gravityMps2 * min(max(rel - steadySeconds, 0), maneuverSeconds)
        gps.append(GPSSample(
            timestamp: runStart + rel,
            coordinate: baseCoordinate,
            horizontalAccuracy: horizontalAccuracy,
            speed: speed
        ))
    }
    return (imu, gps)
}

/// Feeds IMU and GPS interleaved in timestamp order; on ties the IMU sample
/// goes first (a fix closes the window that ends at its own timestamp).
private func feed(
    _ estimator: inout VehicleOrientationEstimator,
    imu: [IMUSample],
    gps: [GPSSample]
) {
    var next = 0
    for sample in imu {
        while next < gps.count, gps[next].timestamp < sample.timestamp {
            estimator.ingest(gps: gps[next])
            next += 1
        }
        estimator.ingest(imu: sample)
        while next < gps.count, gps[next].timestamp == sample.timestamp {
            estimator.ingest(gps: gps[next])
            next += 1
        }
    }
    for fix in gps[next...] {
        estimator.ingest(gps: fix)
    }
}

// MARK: - Tests

@Suite("VehicleOrientationEstimator")
struct VehicleOrientationEstimatorTests {
    @Test(
        "random mount rotation is recovered and transform() inverts it",
        arguments: 1...24
    )
    func recoversRandomMountOrientation(seed: Int) throws {
        var rng = SeededRandomNumberGenerator(seed: UInt64(seed))
        let mount = MountRotation.random(using: &rng)
        let (imu, gps) = calibrationRun(rotation: mount, rng: &rng)

        var estimator = VehicleOrientationEstimator()
        feed(&estimator, imu: imu, gps: gps)
        let estimate = try #require(estimator.estimate)

        // Each recovered axis matches the true (rotated) vehicle axis.
        #expect(estimate.forwardDevice.dot(mount.rotate(vehicleForward)) > 0.98)
        #expect(estimate.rightDevice.dot(mount.rotate(vehicleRight)) > 0.98)
        #expect(estimate.upDevice.dot(mount.rotate(vehicleUp)) > 0.98)
        #expect(estimate.confidence >= 0 && estimate.confidence <= 1)

        // Axes form an orthonormal right-handed frame.
        #expect(abs(estimate.forwardDevice.norm - 1) < 1e-9)
        #expect(abs(estimate.rightDevice.norm - 1) < 1e-9)
        #expect(abs(estimate.upDevice.norm - 1) < 1e-9)
        #expect(abs(estimate.forwardDevice.dot(estimate.upDevice)) < 1e-9)
        #expect(abs(estimate.rightDevice.dot(estimate.upDevice)) < 1e-9)
        #expect(abs(estimate.rightDevice.dot(estimate.forwardDevice)) < 1e-9)
        #expect((estimate.forwardDevice.cross(estimate.upDevice) - estimate.rightDevice).norm < 1e-9)

        // transform() of a known vehicle-frame sample (rotated to the device
        // frame) recovers the vehicle-frame components.
        let knownTrue = vehicleForward.scaled(by: 0.2)
            + vehicleRight.scaled(by: -0.1)
            + vehicleUp.scaled(by: 0.05)
        let reading = mount.rotate(knownTrue - vehicleUp)   // + unit down vector
        let gyro = mount.rotate(vehicleUp.scaled(by: 0.3))
        let out = estimate.transform(IMUSample(
            timestamp: runStart + 10,
            accelX: reading.x, accelY: reading.y, accelZ: reading.z,
            gyroX: gyro.x, gyroY: gyro.y, gyroZ: gyro.z
        ))
        #expect(abs(out.longitudinal - 0.2) < 0.03)
        #expect(abs(out.lateral - (-0.1)) < 0.03)
        #expect(abs(out.vertical - 0.05) < 0.03)
        #expect(abs(out.yawRate - 0.3) < 0.02)
        #expect(out.timestamp == runStart + 10)
    }

    @Test("no data, a single IMU sample, or a single GPS fix yield nil")
    func degenerateInputsYieldNil() {
        let empty = VehicleOrientationEstimator()
        #expect(empty.estimate == nil)

        var oneIMU = VehicleOrientationEstimator()
        oneIMU.ingest(imu: IMUSample(
            timestamp: runStart,
            accelX: 0, accelY: 0, accelZ: -1,
            gyroX: 0, gyroY: 0, gyroZ: 0
        ))
        #expect(oneIMU.estimate == nil)

        var oneGPS = VehicleOrientationEstimator()
        oneGPS.ingest(gps: GPSSample(
            timestamp: runStart,
            coordinate: baseCoordinate,
            horizontalAccuracy: 5,
            speed: 3
        ))
        #expect(oneGPS.estimate == nil)
    }

    @Test("stationary-only input never converges: gravity settles but there is no forward evidence")
    func stationaryOnlyYieldsNil() {
        var rng = SeededRandomNumberGenerator(seed: 11)
        let (imu, gps) = calibrationRun(rotation: .identity, rng: &rng, longitudinalG: 0)
        var estimator = VehicleOrientationEstimator()
        feed(&estimator, imu: imu, gps: gps)
        #expect(estimator.estimate == nil)
    }

    @Test("acceleration without GPS corroboration yields nil")
    func imuOnlyYieldsNil() {
        var rng = SeededRandomNumberGenerator(seed: 12)
        let (imu, _) = calibrationRun(rotation: .identity, rng: &rng)
        var estimator = VehicleOrientationEstimator()
        for sample in imu {
            estimator.ingest(imu: sample)
        }
        #expect(estimator.estimate == nil)
    }

    @Test("noise-only input never converges")
    func noiseOnlyNeverConverges() {
        var rng = SeededRandomNumberGenerator(seed: 99)

        // Jittery low-speed GPS: |dv/dt| stays below the acceptance threshold.
        var gps: [GPSSample] = []
        for k in 0...10 {
            gps.append(GPSSample(
                timestamp: runStart + Double(k),
                coordinate: baseCoordinate,
                horizontalAccuracy: 5,
                speed: Double.random(in: 0...0.5, using: &rng)
            ))
        }

        // (a) Pure noise, no gravity at all — the quasi-static gate never opens.
        var pureNoiseIMU: [IMUSample] = []
        // (b) At rest with sensor noise — gravity settles, but no window is accepted.
        var restIMU: [IMUSample] = []
        for i in 0...500 {
            let t = runStart + Double(i) / 50
            let n1 = randomVector(halfWidth: 0.02, using: &rng)
            let g1 = randomVector(halfWidth: 0.005, using: &rng)
            pureNoiseIMU.append(IMUSample(
                timestamp: t,
                accelX: n1.x, accelY: n1.y, accelZ: n1.z,
                gyroX: g1.x, gyroY: g1.y, gyroZ: g1.z
            ))
            let n2 = randomVector(halfWidth: 0.02, using: &rng)
            let g2 = randomVector(halfWidth: 0.005, using: &rng)
            restIMU.append(IMUSample(
                timestamp: t,
                accelX: n2.x, accelY: n2.y, accelZ: -1 + n2.z,
                gyroX: g2.x, gyroY: g2.y, gyroZ: g2.z
            ))
        }

        var pureNoise = VehicleOrientationEstimator()
        feed(&pureNoise, imu: pureNoiseIMU, gps: gps)
        #expect(pureNoise.estimate == nil)

        var restWithJitter = VehicleOrientationEstimator()
        feed(&restWithJitter, imu: restIMU, gps: gps)
        #expect(restWithJitter.estimate == nil)
    }

    @Test("face-up rest reading gives up = (0,0,+1) and a right-handed aligned frame")
    func faceUpGravityAndHandedness() throws {
        var rng = SeededRandomNumberGenerator(seed: 7)
        let (imu, gps) = calibrationRun(rotation: .identity, rng: &rng)
        var estimator = VehicleOrientationEstimator()
        feed(&estimator, imu: imu, gps: gps)
        let estimate = try #require(estimator.estimate)

        // Rest reading ≈ (0,0,-1) → up = -normalize(gravity) = (0,0,+1).
        #expect(estimate.upDevice.dot(vehicleUp) > 0.999)
        // Device aligned with vehicle: forward=+Y, up=+Z → right = fwd × up = +X.
        #expect(estimate.forwardDevice.dot(vehicleForward) > 0.99)
        #expect(estimate.rightDevice.dot(vehicleRight) > 0.99)
        #expect(estimate.confidence > 0.5)
        #expect(estimate.confidence <= 1)
    }

    @Test("braking windows contribute forward (not backward) evidence")
    func brakingGivesForwardEvidence() throws {
        var rng = SeededRandomNumberGenerator(seed: 21)
        let (imu, gps) = calibrationRun(
            rotation: .identity,
            rng: &rng,
            initialSpeedMps: 20,
            longitudinalG: -0.3
        )
        var estimator = VehicleOrientationEstimator()
        feed(&estimator, imu: imu, gps: gps)
        let estimate = try #require(estimator.estimate)
        #expect(estimate.forwardDevice.dot(vehicleForward) > 0.98)
    }

    @Test("acceleration windows with high yaw rate are rejected: turning never converges")
    func turningWindowsRejected() {
        var rng = SeededRandomNumberGenerator(seed: 31)
        let (imu, gps) = calibrationRun(rotation: .identity, rng: &rng, yawRateRadPerSec: 0.5)
        var estimator = VehicleOrientationEstimator()
        feed(&estimator, imu: imu, gps: gps)
        #expect(estimator.estimate == nil)
    }

    @Test("invalid GPS fixes (negative accuracy or missing speed) are ignored")
    func invalidGPSFixesIgnored() {
        var rng = SeededRandomNumberGenerator(seed: 41)
        let (imu, gps) = calibrationRun(rotation: .identity, rng: &rng)

        var negativeAccuracy = VehicleOrientationEstimator()
        feed(
            &negativeAccuracy,
            imu: imu,
            gps: gps.map {
                GPSSample(
                    timestamp: $0.timestamp,
                    coordinate: $0.coordinate,
                    horizontalAccuracy: -1,
                    speed: $0.speed
                )
            }
        )
        #expect(negativeAccuracy.estimate == nil)

        var missingSpeed = VehicleOrientationEstimator()
        feed(
            &missingSpeed,
            imu: imu,
            gps: gps.map {
                GPSSample(
                    timestamp: $0.timestamp,
                    coordinate: $0.coordinate,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    speed: nil
                )
            }
        )
        #expect(missingSpeed.estimate == nil)
    }

    @Test("transform math is exact for a device aligned with the vehicle")
    func transformDeviceAligned() {
        let estimate = VehicleOrientationEstimate(
            forwardDevice: vehicleForward,
            rightDevice: vehicleRight,
            upDevice: vehicleUp,
            confidence: 1
        )
        let out = estimate.transform(IMUSample(
            timestamp: runStart,
            accelX: 0.1, accelY: 0.2, accelZ: -0.95,
            gyroX: 0, gyroY: 0, gyroZ: 0.3
        ))
        // Gravity removal: aTrue = reading + up = (0.1, 0.2, 0.05).
        #expect(abs(out.longitudinal - 0.2) < 1e-12)
        #expect(abs(out.lateral - 0.1) < 1e-12)
        #expect(abs(out.vertical - 0.05) < 1e-12)
        #expect(abs(out.yawRate - 0.3) < 1e-12)

        // Pure gravity at rest transforms to all zeros.
        let rest = estimate.transform(IMUSample(
            timestamp: runStart,
            accelX: 0, accelY: 0, accelZ: -1,
            gyroX: 0, gyroY: 0, gyroZ: 0
        ))
        #expect(rest.longitudinal == 0 && rest.lateral == 0 && rest.vertical == 0 && rest.yawRate == 0)
    }

    @Test("identical seeds replay to bit-identical estimates")
    func deterministicBySeed() throws {
        func run(seed: UInt64) -> VehicleOrientationEstimate? {
            var rng = SeededRandomNumberGenerator(seed: seed)
            let mount = MountRotation.random(using: &rng)
            let (imu, gps) = calibrationRun(rotation: mount, rng: &rng)
            var estimator = VehicleOrientationEstimator()
            feed(&estimator, imu: imu, gps: gps)
            return estimator.estimate
        }
        let first = try #require(run(seed: 12_345))
        let second = try #require(run(seed: 12_345))
        #expect(first == second)
    }

    @Test("out-of-order samples after convergence are tolerated")
    func outOfOrderSamplesAreSafe() throws {
        var rng = SeededRandomNumberGenerator(seed: 51)
        let (imu, gps) = calibrationRun(rotation: .identity, rng: &rng)
        var estimator = VehicleOrientationEstimator()
        feed(&estimator, imu: imu, gps: gps)
        #expect(estimator.estimate != nil)

        // Stale IMU and GPS samples must neither crash nor corrupt the estimate.
        estimator.ingest(imu: IMUSample(
            timestamp: runStart + 1,
            accelX: 0, accelY: 0, accelZ: -1,
            gyroX: 0, gyroY: 0, gyroZ: 0
        ))
        estimator.ingest(gps: GPSSample(
            timestamp: runStart + 1,
            coordinate: baseCoordinate,
            horizontalAccuracy: 5,
            speed: 0
        ))
        let estimate = try #require(estimator.estimate)
        #expect(estimate.upDevice.dot(vehicleUp) > 0.99)
        #expect(estimate.forwardDevice.dot(vehicleForward) > 0.98)
    }

    @Test("config default is sane and round-trips through Codable")
    func configDefaultAndCodable() throws {
        let config = OrientationConfig.default
        #expect(config.gravityTimeConstantSeconds > 0)
        #expect(config.maxGravityDeviationG > 0)
        #expect(config.quasiStaticDebounceSeconds > 0)
        #expect(config.minStationaryDurationSeconds > 0)
        #expect(config.minAccelerationMps2 > 0)
        #expect(config.maxYawRateRadPerSec > 0)
        #expect(config.maxGPSGapSeconds > 0)
        #expect(config.minForwardEvidenceGSeconds > 0)
        #expect(config.evidenceSaturationGSeconds >= config.minForwardEvidenceGSeconds)
        #expect(config.minConsistencyRatio > 0 && config.minConsistencyRatio <= 1)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OrientationConfig.self, from: data)
        #expect(decoded == config)
    }
}
