/// The most important seam in the codebase.
///
/// The iOS app conforms CoreLocation/CoreMotion adapters to these protocols;
/// the telemetry simulator conforms its synthetic profiles to the same
/// protocols. Everything downstream (fusion, trajectory, events, scoring,
/// integrity) consumes only these — which is what guarantees simulated data
/// exercises the *same production pipeline* as a real drive (spec §58).
public protocol LocationSource: Sendable {
    /// Ordered stream of GPS fixes. Finishes when the source stops.
    var updates: AsyncStream<GPSSample> { get }
}

public protocol MotionSource: Sendable {
    /// Ordered stream of inertial samples. Finishes when the source stops.
    var updates: AsyncStream<IMUSample> { get }
}
