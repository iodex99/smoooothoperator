import Foundation
import SOCore

/// Emission parameters for the telemetry simulator. Everything is
/// deterministic: timestamps derive from `startTimestamp`, all noise flows
/// from the seed — never from the wall clock.
public struct SimulationConfig: Codable, Sendable, Equatable {
    /// GPS fix rate, Hz. Must divide `imuHz` evenly.
    public var gpsHz: Double
    /// Inertial sample rate, Hz.
    public var imuHz: Double
    /// Epoch seconds of the first sample. Fixed default keeps golden
    /// fixtures reproducible forever.
    public var startTimestamp: Double
    /// Nominal reported horizontal accuracy, meters.
    public var gpsAccuracyMeters: Double
    /// 1-sigma of the position noise applied to clean fixes, meters.
    public var gpsPositionNoiseMeters: Double
    /// 1-sigma of the reported-speed noise, m/s.
    public var gpsSpeedNoiseMps: Double
    /// 1-sigma accelerometer noise, g.
    public var imuAccelNoiseG: Double
    /// 1-sigma gyro noise, rad/s.
    public var imuGyroNoiseRadPerSec: Double
    /// Stationary lead-in before the vehicle moves, seconds — gives the
    /// orientation estimator its calibration window (spec §16).
    public var stationaryLeadSeconds: Double

    public init(
        gpsHz: Double,
        imuHz: Double,
        startTimestamp: Double,
        gpsAccuracyMeters: Double,
        gpsPositionNoiseMeters: Double,
        gpsSpeedNoiseMps: Double,
        imuAccelNoiseG: Double,
        imuGyroNoiseRadPerSec: Double,
        stationaryLeadSeconds: Double
    ) {
        self.gpsHz = gpsHz
        self.imuHz = imuHz
        self.startTimestamp = startTimestamp
        self.gpsAccuracyMeters = gpsAccuracyMeters
        self.gpsPositionNoiseMeters = gpsPositionNoiseMeters
        self.gpsSpeedNoiseMps = gpsSpeedNoiseMps
        self.imuAccelNoiseG = imuAccelNoiseG
        self.imuGyroNoiseRadPerSec = imuGyroNoiseRadPerSec
        self.stationaryLeadSeconds = stationaryLeadSeconds
    }

    public static let `default` = SimulationConfig(
        gpsHz: 10,
        imuHz: 50,
        startTimestamp: 1_754_982_000,
        gpsAccuracyMeters: 5,
        gpsPositionNoiseMeters: 1.5,
        gpsSpeedNoiseMps: 0.15,
        imuAccelNoiseG: 0.015,
        imuGyroNoiseRadPerSec: 0.01,
        stationaryLeadSeconds: 2
    )
}

/// How a profile drives: the limits and roughness of its inputs.
/// Degraded-signal and cheat profiles drive like `.normal` and add their
/// corruption at the sensor-emission layer instead.
struct ProfileDynamics: Sendable {
    /// Top speed, m/s.
    var vMaxMps: Double
    /// Peak throttle acceleration, m/s².
    var maxAccelMps2: Double
    /// Peak braking deceleration, m/s².
    var maxBrakeMps2: Double
    /// Peak lateral acceleration budget for cornering speed, m/s².
    var maxLateralMps2: Double
    /// How fast commanded acceleration may change, m/s³. Low = smooth.
    var jerkLimitMps3: Double
    /// Amplitude of deliberate throttle oscillation, m/s² (aggressive habit).
    var oscillationMps2: Double

    static func dynamics(for profile: SimulationProfile) -> ProfileDynamics {
        switch profile {
        case .fastSmooth:
            ProfileDynamics(vMaxMps: 24, maxAccelMps2: 2.7, maxBrakeMps2: 3.1,
                            maxLateralMps2: 3.1, jerkLimitMps3: 1.2, oscillationMps2: 0)
        case .fastAggressive:
            ProfileDynamics(vMaxMps: 26, maxAccelMps2: 4.1, maxBrakeMps2: 4.9,
                            maxLateralMps2: 4.4, jerkLimitMps3: 12, oscillationMps2: 0.8)
        case .slowSmooth:
            ProfileDynamics(vMaxMps: 12, maxAccelMps2: 1.5, maxBrakeMps2: 1.5,
                            maxLateralMps2: 1.8, jerkLimitMps3: 0.8, oscillationMps2: 0)
        case .normal, .gpsDrift, .gpsJump, .missingGPS, .sensorDisagreement,
             .routeDeviation, .mockGPS, .impossiblePhysics, .timestampManipulation:
            ProfileDynamics(vMaxMps: 19, maxAccelMps2: 2.5, maxBrakeMps2: 2.8,
                            maxLateralMps2: 2.6, jerkLimitMps3: 2.5, oscillationMps2: 0.1)
        }
    }
}

/// Seeded gaussian noise (Box–Muller over the shared deterministic RNG).
struct GaussianRandom: Sendable {
    private var rng: SeededRandomNumberGenerator

    init(seed: UInt64) {
        self.rng = SeededRandomNumberGenerator(seed: seed)
    }

    mutating func next(sigma: Double) -> Double {
        guard sigma > 0 else { return 0 }
        let u1 = Double.random(in: Double.ulpOfOne...1, using: &rng)
        let u2 = Double.random(in: 0...1, using: &rng)
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    mutating func uniform(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &rng)
    }

    mutating func uniformInt(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &rng)
    }
}
