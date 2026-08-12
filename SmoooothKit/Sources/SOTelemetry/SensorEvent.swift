/// One sensor delivery, unified so downstream consumers see a SINGLE
/// timestamp-ordered stream. Two independent per-sensor streams cannot
/// guarantee interleaving order; the drive session's calibration and
/// gating logic depends on it. iOS adapters push both callback families
/// into one continuation; the simulator merges its arrays by timestamp.
public enum SensorEvent: Sendable, Equatable {
    case gps(GPSSample)
    case imu(IMUSample)

    public var timestamp: Double {
        switch self {
        case .gps(let sample): sample.timestamp
        case .imu(let sample): sample.timestamp
        }
    }

    /// Merges raw sample arrays into one timestamp-ordered event sequence
    /// (IMU first on exact ties — matches the evaluation pipeline's
    /// ingestion order, which feeds GPS with `<=` before each IMU sample).
    public static func merge(gps: [GPSSample], imu: [IMUSample]) -> [SensorEvent] {
        var events: [SensorEvent] = []
        events.reserveCapacity(gps.count + imu.count)
        var gpsIndex = 0
        var imuIndex = 0
        while gpsIndex < gps.count || imuIndex < imu.count {
            if imuIndex >= imu.count {
                events.append(.gps(gps[gpsIndex]))
                gpsIndex += 1
            } else if gpsIndex >= gps.count {
                events.append(.imu(imu[imuIndex]))
                imuIndex += 1
            } else if gps[gpsIndex].timestamp <= imu[imuIndex].timestamp {
                events.append(.gps(gps[gpsIndex]))
                gpsIndex += 1
            } else {
                events.append(.imu(imu[imuIndex]))
                imuIndex += 1
            }
        }
        return events
    }
}
