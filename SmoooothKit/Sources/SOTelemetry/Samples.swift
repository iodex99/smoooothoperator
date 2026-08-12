import SOCore
import SOModels

/// One GPS fix as delivered by the platform location source.
/// Timestamps are absolute epoch seconds; raw samples are never mutated
/// by the pipeline (raw and processed telemetry stay separate — spec §22).
public struct GPSSample: Codable, Sendable, Equatable {
    /// Seconds since Unix epoch.
    public var timestamp: Double
    public var coordinate: GeoCoordinate
    /// Meters above sea level; nil when the fix has no altitude.
    public var altitude: Double?
    /// 1-sigma horizontal error estimate in meters; negative means invalid fix.
    public var horizontalAccuracy: Double
    /// Direction of travel in degrees from true north (0..<360); nil when unknown.
    public var course: Double?
    /// Ground speed in m/s; nil when unknown.
    public var speed: Double?

    public init(
        timestamp: Double,
        coordinate: GeoCoordinate,
        altitude: Double? = nil,
        horizontalAccuracy: Double,
        course: Double? = nil,
        speed: Double? = nil
    ) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.course = course
        self.speed = speed
    }
}

/// One inertial sample (accelerometer + gyroscope) in the *device* frame.
/// The VehicleOrientationEstimator transforms these into the vehicle frame
/// (longitudinal/lateral/vertical) after calibration — spec §19.
public struct IMUSample: Codable, Sendable, Equatable {
    /// Seconds since Unix epoch.
    public var timestamp: Double
    /// Acceleration in g, device axes.
    public var accelX: Double
    public var accelY: Double
    public var accelZ: Double
    /// Rotation rate in rad/s, device axes.
    public var gyroX: Double
    public var gyroY: Double
    public var gyroZ: Double

    public init(
        timestamp: Double,
        accelX: Double, accelY: Double, accelZ: Double,
        gyroX: Double, gyroY: Double, gyroZ: Double
    ) {
        self.timestamp = timestamp
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
    }
}
