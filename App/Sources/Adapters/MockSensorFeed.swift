#if DEBUG
import Foundation
import SOCore
import SOSimulator
import SOTelemetry

/// MOCK MODE (spec §89): synthetic profiles through the REAL production
/// pipeline — the exact same DriveSession the road uses. Development only.
enum MockSensorFeed {
    /// Emits a simulated run's events paced to wall-clock (`speedup`× real
    /// time) so the driving screen behaves like a live drive.
    static func stream(
        profile: SimulationProfile,
        route: [GeoCoordinate],
        seed: UInt64 = 42,
        speedup: Double = 10
    ) -> AsyncStream<SensorEvent> {
        let run = TelemetrySimulator(profile: profile, seed: seed).simulate(route: route)
        let events = SensorEvent.merge(gps: run.gps, imu: run.imu)
        return AsyncStream { continuation in
            Task {
                guard let first = events.first else {
                    continuation.finish()
                    return
                }
                let start = first.timestamp
                for event in events {
                    if Task.isCancelled { break }
                    let delay = (event.timestamp - start) / speedup
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1e9))
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}
#endif
