import CZlib
import Foundation

/// Gzip, for the one payload in this product whose size actually matters.
///
/// Raw telemetry is roughly **4,000× everything else** the app stores: a
/// 20-minute drive is ~72,000 samples and ~20 MB of JSON, against ~5 KB for
/// the run row and ~9 KB for the ghost. It is also the one blob that travels
/// over a driver's mobile connection, from a car, often on the edge of
/// coverage. Compressing it is the single largest thing that can be done
/// about both the bill and the upload.
///
/// **Why gzip and not raw deflate or zstd.** The server sniffs the two magic
/// bytes `1f 8b` and pipes the blob through `DecompressionStream("gzip")`,
/// which is the Web Streams API and takes the gzip *container* — a raw
/// deflate stream would be rejected as corrupt. The container costs 18 bytes
/// and is what makes the format self-identifying, so a blob uploaded by an
/// older build still scores.
///
/// **Why this is in the Kit.** zlib is in the iOS SDK and on Linux; Apple's
/// `Compression` framework is only in the former. Everything here is
/// therefore tested on this machine rather than being one more thing that
/// can only be checked on a Mac.
public enum Gzip {
    /// Compression level. `deflate` accepts 0–9; anything else is a
    /// programming error rather than something to fail a drive over, so it is
    /// clamped rather than trapped.
    public enum Level: Int, Sendable {
        /// zlib's default (6). Chosen for the uploader: on real telemetry it
        /// gives within ~2% of `.best` for a fraction of the CPU, and this
        /// runs on a phone that has just finished a drive.
        case `default` = 6
        case best = 9
        case fastest = 1
    }

    public enum Failure: Error, Equatable {
        /// zlib refused to start — in practice only out-of-memory.
        case initialisationFailed(Int32)
        /// The stream ended mid-block, or was never gzip to begin with.
        case corruptInput
        /// zlib returned an error mid-stream.
        case streamFailed(Int32)
        /// Refused before doing any work: see `decompressionLimit`.
        case tooLarge
    }

    /// Work buffer. 64 KiB is large enough that a 20 MB blob is ~320 round
    /// trips rather than ~20,000, and small enough to be irrelevant on a
    /// phone.
    private static let chunkSize = 64 * 1024

    /// The ceiling on what `decompress` will produce, defending against a
    /// zip bomb: a few hundred KB of gzip can expand to gigabytes, and the
    /// only party who benefits from finding that out the slow way is the
    /// attacker. 256 MiB is four times the largest legitimate run
    /// (`DriveSessionConfig`'s sample caps come to ~60 MB of JSON) and well
    /// under any device's tolerance.
    public static let decompressionLimit = 256 * 1024 * 1024

    /// The gzip magic number. A blob starting with these two bytes is gzip;
    /// anything else is passed through untouched by `decompressIfNeeded`.
    public static func isGzipped(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Compress to a gzip stream.
    public static func compress(_ data: Data, level: Level = .default) throws -> Data {
        // An empty input still produces a valid (20-byte) gzip stream, and
        // that is the right answer: the caller gets something the server can
        // decompress rather than an empty file that fails a hash check later.
        var stream = z_stream()
        // windowBits 15 + 16 selects the gzip wrapper rather than zlib's own.
        // This single constant is the difference between a blob the server
        // can read and one it rejects.
        let status = deflateInit2_(
            &stream,
            Int32(level.rawValue),
            Z_DEFLATED,
            15 + 16,
            8,                       // memLevel: zlib's default
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw Failure.initialisationFailed(status) }
        defer { deflateEnd(&stream) }

        return try run(
            &stream,
            input: data,
            step: { deflate(&$0, $1) },
            finishFlag: Z_FINISH,
            limit: nil
        )
    }

    /// Decompress a gzip stream.
    ///
    /// Throws `.tooLarge` rather than allocating without bound; see
    /// `decompressionLimit`.
    public static func decompress(_ data: Data) throws -> Data {
        guard isGzipped(data) else { throw Failure.corruptInput }
        var stream = z_stream()
        // 15 + 16 again: accept the gzip wrapper only. `15 + 32` would also
        // accept a zlib stream, which nothing here produces — and quietly
        // accepting a format we never write is how a format bug survives.
        let status = inflateInit2_(
            &stream,
            15 + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw Failure.initialisationFailed(status) }
        defer { inflateEnd(&stream) }

        return try run(
            &stream,
            input: data,
            step: { inflate(&$0, $1) },
            finishFlag: Z_NO_FLUSH,
            limit: decompressionLimit
        )
    }

    /// Decompress if it is gzip, pass through if it is not.
    ///
    /// The queue on a phone can hold runs recorded by an older build, and a
    /// blob written before compression existed is still a run somebody drove.
    public static func decompressIfNeeded(_ data: Data) throws -> Data {
        isGzipped(data) ? try decompress(data) : data
    }

    // MARK: - The loop both directions share

    /// deflate and inflate have the same shape: feed input, drain output
    /// until the stream says it is done. Writing it once means the buffer
    /// arithmetic — which is where this kind of code goes wrong — is written
    /// once and tested from both ends.
    private static func run(
        _ stream: inout z_stream,
        input: Data,
        step: (inout z_stream, Int32) -> Int32,
        finishFlag: Int32,
        limit: Int?
    ) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        // A mutable copy so the pointer handed to zlib stays valid for the
        // whole call — `withUnsafeBytes` on a slice does not promise that.
        var source = input

        return try source.withUnsafeMutableBytes { raw -> Data in
            stream.next_in = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            stream.avail_in = uInt(raw.count)

            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    return step(&stream, finishFlag)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    if let limit, output.count + produced > limit { throw Failure.tooLarge }
                    output.append(contentsOf: buffer[0..<produced])
                }

                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK, Z_BUF_ERROR:
                    // Z_BUF_ERROR with no progress possible means the input
                    // ended mid-stream — a truncated file, not a full buffer.
                    if status == Z_BUF_ERROR, produced == 0, stream.avail_in == 0 {
                        throw Failure.corruptInput
                    }
                    // Inflate stops asking for input at the end of a truncated
                    // stream without ever reporting Z_STREAM_END.
                    if stream.avail_in == 0, produced == 0 { throw Failure.corruptInput }
                case Z_DATA_ERROR, Z_NEED_DICT:
                    throw Failure.corruptInput
                default:
                    throw Failure.streamFailed(status)
                }
            }
        }
    }
}
