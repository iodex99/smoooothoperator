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
                // Chunked pacing: one sleep per ~50ms of wall time, then a
                // burst of events. Per-event sleeps drown in the simulator's
                // timer coalescing (~10ms each × 15k events = minutes).
                var flushedAt = first.timestamp
                for event in events {
                    if Task.isCancelled { break }
                    let wallDelay = (event.timestamp - flushedAt) / speedup
                    if wallDelay >= 0.05 {
                        try? await Task.sleep(nanoseconds: UInt64(wallDelay * 1e9))
                        flushedAt = event.timestamp
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}
#endif
