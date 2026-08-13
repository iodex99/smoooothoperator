import Foundation

/// Durable storage for finished runs awaiting upload.
///
/// The contract is deliberately small and total: saving is atomic, loading
/// never throws away readable runs because an unreadable one exists beside
/// them, and nothing is deleted except on an explicit acknowledged upload.
public protocol RunStore: Sendable {
    func save(_ run: PendingRun) throws
    /// Every run still owed to the server, oldest first.
    func loadAll() throws -> [PendingRun]
    func delete(id: UUID) throws
}

/// File-backed store: one JSON document per run in a directory.
///
/// Crash safety: writes go to a temporary file and are then renamed into
/// place, so a process death mid-write can leave a stray `.tmp` but never a
/// truncated run that decodes into a *wrong* drive. Unreadable files are
/// quarantined rather than deleted — a corrupt run is a support case, not
/// something to silently destroy.
public struct FileRunStore: RunStore {
    private let directory: URL
    private let quarantine: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.quarantine = directory.appendingPathComponent("quarantine", isDirectory: true)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func save(_ run: PendingRun) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(run)
        // `.atomic` writes to a sibling temp file and renames it into place,
        // so a reader (or a crash) sees either the whole previous record or
        // the whole new one — never a truncated drive.
        try data.write(to: url(for: run.id), options: .atomic)
    }

    public func loadAll() throws -> [PendingRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var runs: [PendingRun] = []
        for file in contents where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let run = try? decoder.decode(PendingRun.self, from: data) {
                runs.append(run)
            } else {
                // Damaged or written by a future/older schema: move it aside so
                // the queue keeps draining, and keep the bytes for support.
                try? quarantineFile(file)
            }
        }
        return runs.sorted { $0.createdAt < $1.createdAt }
    }

    public func delete(id: UUID) throws {
        let target = url(for: id)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    /// Runs set aside as unreadable — surfaced for diagnostics, never silently
    /// discarded.
    public func quarantinedCount() -> Int {
        (try? fileManager.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil).count)
            ?? 0
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func quarantineFile(_ file: URL) throws {
        try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let destination = quarantine.appendingPathComponent(file.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: file, to: destination)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryRunStore: RunStore, @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [UUID: PendingRun] = [:]

    public init() {}

    public func save(_ run: PendingRun) throws {
        lock.lock()
        defer { lock.unlock() }
        runs[run.id] = run
    }

    public func loadAll() throws -> [PendingRun] {
        lock.lock()
        defer { lock.unlock() }
        return runs.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        runs[id] = nil
    }
}
