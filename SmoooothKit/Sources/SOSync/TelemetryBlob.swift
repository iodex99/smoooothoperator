import Foundation
import SOCore
import SOTelemetry

/// The raw-telemetry wire format, and the only place it is defined.
///
/// This is the blob the phone uploads and `score-run` scores. It used to be
/// built inside the iOS uploader, which meant the one format that crosses
/// the language boundary lived in the half of the project Linux cannot test
/// — so the fixture the server was tested against was hand-written, and a
/// hand-written copy of a wire format drifts. It is here now, and
/// `sogen telemetry-blob` emits exactly what the app sends so the Deno side
/// can be held to real output. Same pattern as the course proposal.
///
/// **Compact by construction.** Samples are arrays, not objects: a JSON
/// object per sample would repeat the key names 72,000 times in a
/// 20-minute drive. `-9999` is the absent sentinel, because `null` in a
/// numeric array costs more bytes than it saves and the server's parser
/// reads positionally.
public enum TelemetryBlob {
    /// The value that means "the device did not report this".
    public static let absent = -9999.0

    /// Bump only alongside the server's parser. The field exists so a blob
    /// uploaded by an older build can still be read rather than guessed at.
    public static let formatVersion = 1

    /// How many decimal places each field is written with.
    ///
    /// **This is where most of the saving is, and it is not obvious.** Gzip
    /// alone takes a real drive from 2.05 MB to 846 KB — 2.4×, not the 8×
    /// this was assumed to be worth. The reason is that a `Double` serialises
    /// to its full round-trip precision: a latitude arrives as
    /// `34.0259007324108` and a gyro reading as `-0.0032592050051714794`.
    /// Seventeen significant digits of which perhaps eight mean anything is,
    /// to a compressor, seventeen digits of high-entropy noise — the worst
    /// possible input.
    ///
    /// Writing each field at the precision its sensor can actually resolve
    /// takes the same drive to **280 KB, 7.3×**. Three of those decimal
    /// places were never measurements; they were floating-point residue, and
    /// a driver was paying to upload them from a car.
    ///
    /// Every value below is coarser than the hardware — **except the
    /// timestamp, which is not rounded at all.**
    ///
    /// That exception was measured, not assumed, and it is the whole reason
    /// this table is a table rather than one number. Rounding timestamps to
    /// 1 ms — twenty times finer than the shortest interval between samples,
    /// and *obviously* harmless — moved real scores: fastSmooth 8800 → 8799,
    /// fastAggressive 8116 → 8112. Speed and acceleration are derived as
    /// Δx/Δt, and at 10 Hz a millisecond is 1% of Δt; smoothness and control
    /// are built on the derivatives of that, so the error compounds. The
    /// coordinates were innocent — the score is unchanged even at twelve
    /// decimal places of latitude, with the timestamp left alone.
    ///
    /// And rounding them bought **nothing**: 307,638 bytes against 307,661
    /// at 1 ms, because an epoch second already carries its digits either
    /// way. A real risk to a driver's score, for 23 bytes in the wrong
    /// direction.
    public enum Precision {
        /// ~1.1 cm of latitude. The best horizontal accuracy a phone ever
        /// reports is metres.
        public static let coordinate = 7
        /// 1 cm, on a number that is itself an error estimate in metres.
        public static let accuracy = 2
        /// 0.01°, against a compass whose real error is degrees.
        public static let course = 2
        /// 1 mm/s.
        public static let speed = 3
        /// 1 cm of altitude, which is not used in scoring at all.
        public static let altitude = 2
        /// 1e-5 g ≈ 1e-4 m/s². Accelerometer noise density puts real
        /// resolution three orders of magnitude above this.
        public static let acceleration = 5
        /// 1e-6 rad/s. Kept finer than acceleration because gyro readings
        /// are small numbers — a cornering rate is ~0.5 rad/s but the
        /// straight-line noise this is measured against is ~0.003.
        public static let rotation = 6
    }

    /// Round to `places` decimal places.
    ///
    /// The absent sentinel passes through unchanged: -9999 is exact at every
    /// precision here, so no special case is needed and none is written —
    /// the check would be untested code protecting nothing.
    static func quantise(_ value: Double, _ places: Int) -> Double {
        guard value.isFinite else { return value }
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }

    /// The uncompressed JSON payload.
    public static func encode(gps: [GPSSample], imu: [IMUSample]) throws -> Data {
        let payload: [String: Any] = [
            "formatVersion": formatVersion,
            "gps": gps.map { sample in
                [sample.timestamp,  // never rounded — see Precision
                 quantise(sample.coordinate.latitude, Precision.coordinate),
                 quantise(sample.coordinate.longitude, Precision.coordinate),
                 quantise(sample.horizontalAccuracy, Precision.accuracy),
                 quantise(sample.course ?? absent, Precision.course),
                 quantise(sample.speed ?? absent, Precision.speed),
                 quantise(sample.altitude ?? absent, Precision.altitude)]
            },
            "imu": imu.map { sample in
                [sample.timestamp,  // never rounded — see Precision
                 quantise(sample.accelX, Precision.acceleration),
                 quantise(sample.accelY, Precision.acceleration),
                 quantise(sample.accelZ, Precision.acceleration),
                 quantise(sample.gyroX, Precision.rotation),
                 quantise(sample.gyroY, Precision.rotation),
                 quantise(sample.gyroZ, Precision.rotation)]
            },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Read a blob back into samples — the server's parse, in Swift, so the
    /// effect of the wire format on a score can be measured here rather than
    /// discovered in production.
    public static func decode(_ data: Data) throws -> (gps: [GPSSample], imu: [IMUSample]) {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let gpsRows = root["gps"] as? [[Double]],
            let imuRows = root["imu"] as? [[Double]]
        else { throw DecodeFailure.malformed }

        let gps = try gpsRows.map { row -> GPSSample in
            guard row.count >= 7 else { throw DecodeFailure.malformed }
            return GPSSample(
                timestamp: row[0],
                coordinate: GeoCoordinate(latitude: row[1], longitude: row[2]),
                altitude: row[6] == absent ? nil : row[6],
                horizontalAccuracy: row[3],
                course: row[4] == absent ? nil : row[4],
                speed: row[5] == absent ? nil : row[5]
            )
        }
        let imu = try imuRows.map { row -> IMUSample in
            guard row.count >= 7 else { throw DecodeFailure.malformed }
            return IMUSample(
                timestamp: row[0],
                accelX: row[1], accelY: row[2], accelZ: row[3],
                gyroX: row[4], gyroY: row[5], gyroZ: row[6]
            )
        }
        return (gps, imu)
    }

    public enum DecodeFailure: Error, Equatable {
        case malformed
    }

    /// What actually goes over the wire, and the numbers the envelope must
    /// carry with it.
    public struct Upload: Sendable, Equatable {
        /// Gzip bytes. This is what is stored and what is hashed.
        public let bytes: Data
        /// sha256 of `bytes` — the **compressed** ones. The server hashes
        /// what it fetched before it decompresses anything, so hashing the
        /// uncompressed payload here would fail every run.
        public let sha256: String
        /// For the telemetry envelope's `byte_size`, which describes the
        /// stored object.
        public var byteSize: Int { bytes.count }
        /// Kept for the operator's benefit: the ratio is the only way to
        /// notice compression has silently stopped happening.
        public let uncompressedByteSize: Int

        public var compressionRatio: Double {
            bytes.isEmpty ? 0 : Double(uncompressedByteSize) / Double(bytes.count)
        }
    }

    /// Build the upload: encode, compress, hash the compressed bytes.
    ///
    /// Raw telemetry is ~4,000× the size of everything else this app stores
    /// and it leaves a phone over a mobile connection, from a car. Gzip takes
    /// roughly 20 MB to 2.5 MB — the largest single thing that can be done
    /// about both the bill and the driver's upload.
    public static func upload(
        gps: [GPSSample],
        imu: [IMUSample],
        level: Gzip.Level = .default
    ) throws -> Upload {
        let json = try encode(gps: gps, imu: imu)
        let compressed = try Gzip.compress(json, level: level)
        return Upload(
            bytes: compressed,
            sha256: SHA256Digest.hex(of: compressed),
            uncompressedByteSize: json.count
        )
    }

    /// The storage object name for a run's blob.
    ///
    /// The extension is part of the contract: the storage policy confines
    /// writes to the caller's own uid prefix and `validate_telemetry_path`
    /// re-checks it, so the prefix must stay exactly `<uid>/`.
    public static func storagePath(userId: String, objectId: UUID = UUID()) -> String {
        "\(userId)/\(objectId.uuidString.lowercased()).json.gz"
    }
}
