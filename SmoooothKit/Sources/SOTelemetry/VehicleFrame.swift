import SOCore

/// One inertial sample transformed into the *vehicle* frame (spec §19):
/// the output of `VehicleOrientationEstimator.transform`, and the input to
/// event detection and scoring.
public struct VehicleFrameSample: Codable, Sendable, Equatable {
    /// Seconds since Unix epoch.
    public var timestamp: Double
    /// Forward(+)/backward(−) acceleration in g, gravity-removed.
    public var longitudinal: Double
    /// Right(+)/left(−) acceleration in g, gravity-removed.
    public var lateral: Double
    /// Up(+)/down(−) acceleration in g, gravity-removed (road bumps, crests).
    public var vertical: Double
    /// Rotation rate about the vehicle's vertical axis in rad/s
    /// (+ = turning left, right-hand rule about "up").
    public var yawRate: Double

    public init(
        timestamp: Double,
        longitudinal: Double,
        lateral: Double,
        vertical: Double,
        yawRate: Double
    ) {
        self.timestamp = timestamp
        self.longitudinal = longitudinal
        self.lateral = lateral
        self.vertical = vertical
        self.yawRate = yawRate
    }
}
