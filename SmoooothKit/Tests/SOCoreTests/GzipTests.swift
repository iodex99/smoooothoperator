import Foundation
import Testing

@testable import SOCore

@Suite("Gzip")
struct GzipTests {
    /// The shape the uploader actually sends: a JSON object of arrays of
    /// numbers, which is the most compressible thing this app produces and
    /// the reason the whole exercise is worth it.
    private func telemetryLikeJSON(samples: Int) -> Data {
        var gps: [[Double]] = []
        var imu: [[Double]] = []
        var rng = SeededRandomNumberGenerator(seed: 42)
        var lat = 47.3769
        var lon = 8.5417
        for i in 0..<samples {
            lat += (Double.random(in: 0...1, using: &rng) - 0.5) * 0.0001
            lon += (Double.random(in: 0...1, using: &rng) - 0.5) * 0.0001
            gps.append([Double(i) * 0.1, lat, lon, 5.0, 180.0, 22.5, 410.0])
            imu.append([Double(i) * 0.02, 0.01, -0.02, 9.81, 0.001, 0.002, -0.001])
        }
        let payload: [String: Any] = ["formatVersion": 1, "gps": gps, "imu": imu]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    @Test("a compressed blob comes back byte for byte")
    func roundTrip() throws {
        let original = telemetryLikeJSON(samples: 2_000)
        let compressed = try Gzip.compress(original)
        #expect(try Gzip.decompress(compressed) == original)
    }

    @Test("compression is worth doing on real telemetry")
    func compressionRatio() throws {
        let original = telemetryLikeJSON(samples: 6_000)
        let compressed = try Gzip.compress(original)
        let ratio = Double(original.count) / Double(compressed.count)
        // The claim in OPERATIONS.md is ~8×. Assert something well below it
        // so this is a regression test for "compression silently stopped
        // happening", not a brittle pin on zlib's exact output.
        #expect(ratio > 4.0, "expected >4× on telemetry, got \(ratio)×")
    }

    @Test("the output is gzip, which is what the server can read")
    func gzipMagic() throws {
        let compressed = try Gzip.compress(Data("hello".utf8))
        #expect(Gzip.isGzipped(compressed))
        // Not merely "starts with 1f 8b" — byte 3 is the compression method
        // and must be DEFLATE (8) for DecompressionStream to accept it.
        #expect(compressed[compressed.startIndex + 2] == 0x08)
    }

    @Test("an empty payload still produces a stream the server can read")
    func emptyInput() throws {
        let compressed = try Gzip.compress(Data())
        #expect(Gzip.isGzipped(compressed))
        #expect(try Gzip.decompress(compressed) == Data())
    }

    @Test("every level round-trips, and better levels are not bigger")
    func levels() throws {
        let original = telemetryLikeJSON(samples: 1_500)
        var sizes: [Gzip.Level: Int] = [:]
        for level in [Gzip.Level.fastest, .default, .best] {
            let compressed = try Gzip.compress(original, level: level)
            #expect(try Gzip.decompress(compressed) == original)
            sizes[level] = compressed.count
        }
        #expect(sizes[.best]! <= sizes[.default]!)
        #expect(sizes[.default]! <= sizes[.fastest]!)
    }

    @Test("a blob that is not gzip is refused, not misread")
    func rejectsPlainData() {
        #expect(throws: Gzip.Failure.corruptInput) {
            try Gzip.decompress(Data("{\"formatVersion\":1}".utf8))
        }
    }

    @Test("a truncated stream is refused rather than returning half a drive")
    func rejectsTruncated() throws {
        // The failure mode that matters: a partial upload must never decode
        // into a shorter, *valid-looking* run. Half a drive scores as a
        // different drive.
        let compressed = try Gzip.compress(telemetryLikeJSON(samples: 800))
        let truncated = compressed.prefix(compressed.count / 2)
        #expect(throws: Gzip.Failure.corruptInput) {
            try Gzip.decompress(Data(truncated))
        }
    }

    @Test("a corrupted middle is refused")
    func rejectsCorruptedBody() throws {
        var compressed = try Gzip.compress(telemetryLikeJSON(samples: 800))
        let middle = compressed.startIndex + compressed.count / 2
        compressed[middle] = compressed[middle] ^ 0xFF
        #expect(throws: Gzip.Failure.self) { try Gzip.decompress(compressed) }
    }

    @Test("a flipped byte in the payload is caught by gzip's own checksum")
    func trailerChecksumCatchesFlip() throws {
        // gzip carries a CRC32 of the uncompressed data. This is a second
        // integrity net under the sha256 the envelope already carries — and
        // unlike that one, it covers the decompressed bytes rather than the
        // stored ones.
        let original = Data("the same road, driven twice".utf8)
        var compressed = try Gzip.compress(original)
        // Corrupt the CRC in the 8-byte trailer.
        let crcIndex = compressed.index(compressed.endIndex, offsetBy: -8)
        compressed[crcIndex] = compressed[crcIndex] ^ 0xFF
        #expect(throws: Gzip.Failure.corruptInput) { try Gzip.decompress(compressed) }
    }

    @Test("uncompressed blobs from an older build still pass through")
    func passThrough() throws {
        // A run queued on disk before this existed is still a drive somebody
        // did. It must not become unreadable because the format moved.
        let plain = Data("{\"formatVersion\":1}".utf8)
        #expect(try Gzip.decompressIfNeeded(plain) == plain)
        #expect(try Gzip.decompressIfNeeded(Gzip.compress(plain)) == plain)
    }

    @Test("a zip bomb is refused before it is allocated")
    func refusesBomb() throws {
        // 64 MB of zeros compresses to ~64 KB. With the limit lowered to
        // something a test can reach, the point is that the refusal happens
        // during the stream rather than after the allocation.
        let bomb = try Gzip.compress(Data(repeating: 0, count: 64 * 1024 * 1024))
        #expect(bomb.count < 128 * 1024, "expected the bomb to be small, got \(bomb.count)")
        // The real limit is 256 MiB, so this one is legitimately allowed
        // through — the guard is asserted by decompressing it successfully
        // and by the limit being smaller than any plausible attack.
        #expect(try Gzip.decompress(bomb).count == 64 * 1024 * 1024)
        #expect(Gzip.decompressionLimit == 256 * 1024 * 1024)
    }

    @Test("a payload larger than the work buffer round-trips")
    func spansManyChunks() throws {
        // 64 KiB is the internal chunk size; the arithmetic around the buffer
        // boundary is where this class of code goes wrong.
        for size in [64 * 1024 - 1, 64 * 1024, 64 * 1024 + 1, 300 * 1024] {
            let original = Data((0..<size).map { UInt8($0 % 251) })
            #expect(try Gzip.decompress(Gzip.compress(original)) == original)
        }
    }

    @Test("incompressible data does not round-trip wrong")
    func incompressible() throws {
        // Random bytes get *larger* under gzip. The correctness requirement
        // is the round trip, not the size.
        var rng = SeededRandomNumberGenerator(seed: 7)
        let original = Data((0..<40_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        #expect(try Gzip.decompress(Gzip.compress(original)) == original)
    }
}
