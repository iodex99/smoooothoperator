import CoreLocation
import CoreMotion
import Foundation
import SOTelemetry

/// Bridges CoreLocation + CoreMotion into the Kit's unified, timestamp-
/// ordered `SensorEvent` stream (ADR-0001: adapters carry no logic).
/// Location updates continue in background during an active challenge only
/// (spec §72); rates per spec §18 targets.
///
/// @unchecked Sendable: the managers are configured/torn down only through
/// this feed's start/stop lifecycle; CoreLocation delivers on the main
/// thread and CoreMotion on its own serial queue — no shared mutation.
final class SensorFeed: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private var continuation: AsyncStream<SensorEvent>.Continuation?

    static let gpsHz = 10.0
    static let imuHz = 50.0

    func requestPermissions() {
        locationManager.requestWhenInUseAuthorization()
    }

    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    /// Starts both sensors and returns the unified event stream. One
    /// consumer at a time; `stop()` finishes the stream.
    func start() -> AsyncStream<SensorEvent> {
        AsyncStream { continuation in
            self.continuation = continuation

            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            locationManager.activityType = .automotiveNavigation
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
            locationManager.startUpdatingLocation()

            motionManager.accelerometerUpdateInterval = 1 / Self.imuHz
            motionManager.gyroUpdateInterval = 1 / Self.imuHz
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1

            // Pair the freshest gyro reading with each accelerometer tick —
            // the Kit convention is one IMUSample carrying both.
            nonisolated(unsafe) var latestGyro: CMGyroData?
            motionManager.startGyroUpdates(to: queue) { data, _ in
                latestGyro = data
            }
            motionManager.startAccelerometerUpdates(to: queue) { data, _ in
                guard let accel = data else { return }
                let gyro = latestGyro
                continuation.yield(.imu(IMUSample(
                    timestamp: Date(
                        timeIntervalSinceReferenceDate: accel.timestamp
                            + Self.referenceToEpochOffset
                    ).timeIntervalSince1970,
                    accelX: accel.acceleration.x,
                    accelY: accel.acceleration.y,
                    accelZ: accel.acceleration.z,
                    gyroX: gyro?.rotationRate.x ?? 0,
                    gyroY: gyro?.rotationRate.y ?? 0,
                    gyroZ: gyro?.rotationRate.z ?? 0
                )))
            }

            continuation.onTermination = { _ in
                self.locationManager.stopUpdatingLocation()
                self.motionManager.stopAccelerometerUpdates()
                self.motionManager.stopGyroUpdates()
            }
        }
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    // CMLogItem timestamps are seconds since boot; CLLocation uses Date.
    // Compute the boot→reference offset once per feed start.
    private static let referenceToEpochOffset: TimeInterval = {
        let now = Date().timeIntervalSinceReferenceDate
        let uptime = ProcessInfo.processInfo.systemUptime
        return now - uptime - Date.timeIntervalBetween1970AndReferenceDate
            + Date.timeIntervalBetween1970AndReferenceDate
    }()

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            continuation?.yield(.gps(GPSSample(
                timestamp: location.timestamp.timeIntervalSince1970,
                coordinate: .init(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                ),
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                horizontalAccuracy: location.horizontalAccuracy,
                course: location.course >= 0 ? location.course : nil,
                speed: location.speed >= 0 ? location.speed : nil
            )))
        }
    }
}
