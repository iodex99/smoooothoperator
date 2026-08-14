import Foundation
import SOTelemetry

/// Writes a drive to disk *while it is happening*, so a crash, a force-quit
/// or a dead battery mid-run does not destroy it.
///
/// The upload queue already protects a run that reached the result screen.
/// This protects the twenty minutes before that, which is where the driver's
/// actual effort is — nobody re-drives a mountain pass because the app died
/// at minute nineteen.
///
/// Format is newline-delimited JSON, appended as it goes, chosen for one
/// property: a file truncated mid-write by a crash is still readable up to
/// the last complete line. A single JSON array would be unparseable, and a
/// binary format would need its own recovery scanner.
///
/// The samples are encoded with `Codable` rather than mapped field by field,
/// so a sample type that gains a field does not silently stop being recorded.
///
/// Pure Foundation, no Apple frameworks — exercised on Linux by the same
/// tests that will run on a device.
public actor InFlightRecorder {
    /// One line of the file. Exactly one payload is present per line.
    private struct Line: Codable {
        var kind: String
        var courseId: String?
        var startedAt: Double?
        var gps: GPSSample?
        var imu: IMUSample?
    }

    public struct Recovered: Sendable, Equatable {
        public var courseId: String
        public var startedAt: Double
        public var gps: [GPSSample]
        public var imu: [IMUSample]
    }

    private let fileURL: URL
    private var handle: FileHandle?
    private var pending = Data()
    /// Written in batches: a write per sample at 50 Hz costs more battery
    /// than the data is worth, and a crash loses at most this many samples —
    /// a fraction of a second of driving.
    private let flushEvery: Int
    private var sinceFlush = 0

    private static let fileExtension = "sodrive"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public init(directory: URL, courseId: String, startedAt: Double, flushEvery: Int = 50) throws {
        self.flushEvery = max(1, flushEvery)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        // The filename carries the start time so recovery can order sessions
        // and two sessions can never collide.
        self.fileURL = Self.url(in: directory, startedAt: startedAt)

        // The header names the course, so a recovered file is uploadable
        // rather than an orphaned set of coordinates. Written directly here
        // rather than through `append`, which is actor-isolated and cannot be
        // called before `self` is fully initialised.
        var header = try Self.encoder.encode(
            Line(kind: "h", courseId: courseId, startedAt: startedAt)
        )
        header.append(0x0A)
        FileManager.default.createFile(atPath: fileURL.path, contents: header)
        self.handle = try FileHandle(forWritingTo: fileURL)
        try self.handle?.seekToEnd()
    }

    public func record(gps sample: GPSSample) {
        append(Line(kind: "g", gps: sample))
    }

    public func record(imu sample: IMUSample) {
        append(Line(kind: "i", imu: sample))
    }

    /// One batch, in order. The session buffers and calls this rather than
    /// spawning a task per sample: independent tasks calling an actor have
    /// no ordering guarantee, and a recovered file with shuffled samples is
    /// worse than no file.
    public func record(gps: [GPSSample], imu: [IMUSample]) {
        for sample in gps { append(Line(kind: "g", gps: sample)) }
        for sample in imu { append(Line(kind: "i", imu: sample)) }
        flush()
    }

    /// Call once the run is safely in the upload queue. Keeping the file
    /// after that would mean recovering a run that already exists.
    public func finish() {
        flush()
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Call when the session gave up — there is no run to recover.
    public func discard() { finish() }

    private func append(_ line: Line) {
        guard var data = try? Self.encoder.encode(line) else { return }
        data.append(0x0A)
        pending.append(data)
        sinceFlush += 1
        if sinceFlush >= flushEvery { flush() }
    }

    private func flush() {
        guard !pending.isEmpty, let handle else { return }
        try? handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        sinceFlush = 0
    }

    // MARK: - Recovery

    static func url(in directory: URL, startedAt: Double) -> URL {
        directory.appendingPathComponent(
            "drive-\(Int(startedAt * 1000)).\(fileExtension)"
        )
    }

    /// Anything left on disk is a run that never reached the upload queue.
    ///
    /// A trailing partial line — the signature of a crash mid-write — is
    /// dropped rather than failing the whole file. Losing a twentieth of a
    /// second is not a reason to lose the drive.
    public static func recover(in directory: URL) -> [Recovered] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(parse)
    }

    public static func discardAll(in directory: URL) {
        for url in (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [] where url.pathExtension == fileExtension {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func discard(_ recovered: Recovered, in directory: URL) {
        try? FileManager.default.removeItem(
            at: url(in: directory, startedAt: recovered.startedAt)
        )
    }

    private static func parse(_ url: URL) -> Recovered? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        var courseId: String?
        var startedAt: Double?
        var gps: [GPSSample] = []
        var imu: [IMUSample] = []

        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // A torn final line fails to decode and is skipped; everything
            // before it is intact and is kept.
            guard let line = try? decoder.decode(Line.self, from: Data(lineData)) else { continue }
            switch line.kind {
            case "h":
                courseId = line.courseId
                startedAt = line.startedAt
            case "g":
                if let sample = line.gps { gps.append(sample) }
            case "i":
                if let sample = line.imu { imu.append(sample) }
            default:
                continue
            }
        }

        // A header and nothing else is a session that died before the driver
        // moved. There is no drive in it to recover.
        guard let courseId, let startedAt, !gps.isEmpty else { return nil }
        return Recovered(courseId: courseId, startedAt: startedAt, gps: gps, imu: imu)
    }
}
