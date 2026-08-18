import Foundation
import SOCore
import SOScoring
import SOSimulator
import SOTelemetry
import Testing

@testable import SOSync

@Suite("The telemetry blob")
struct TelemetryBlobTests {
    private func simulatedRun(
        profile: SimulationProfile = .normal,
        seed: UInt64 = 3
    ) -> SimulatedRun {
        TelemetrySimulator(profile: profile, seed: seed)
            .simulate(route: TelemetrySimulator.demoRoute(seed: seed))
    }

    // MARK: - The question the whole design turns on

    /// **Quantising the wire format must not change what a drive scores.**
    ///
    /// The blob is written at each sensor's real resolution rather than at a
    /// Double's full precision, which is where most of the size saving is.
    /// That is only defensible if the server, reading the rounded values,
    /// reaches the same verdict as the phone reading the unrounded ones. A
    /// driver whose provisional score disagrees with their authoritative one
    /// has been shown a lie, and no amount of bandwidth is worth that.
    ///
    /// Measured here across every clean profile rather than argued from the
    /// decimal places.
    @Test(
        "rounding for the wire does not move the score",
        arguments: [SimulationProfile.normal, .fastSmooth, .fastAggressive]
    )
    func quantisationDoesNotChangeTheScore(profile: SimulationProfile) throws {
        let seed: UInt64 = 3
        let run = simulatedRun(profile: profile, seed: seed)
        let route = TelemetrySimulator.demoRoute(seed: seed)
        let gates = GoldenVectorFactory.gates(route: route)
        let config = try ScoringConfig.load(from: Data(contentsOf: scoringConfigURL))

        func score(gps: [GPSSample], imu: [IMUSample]) throws -> PipelineOutcome {
            guard let outcome = RunEvaluationPipeline.evaluate(
                gps: gps, imu: imu, route: route, gates: gates,
                benchmarkSeconds: 300, scoringConfig: config
            ) else { throw TelemetryBlob.DecodeFailure.malformed }
            return outcome
        }

        let direct = try score(gps: run.gps, imu: run.imu)
        let overTheWire = try TelemetryBlob.decode(
            Gzip.decompress(TelemetryBlob.upload(gps: run.gps, imu: run.imu).bytes)
        )
        let roundTripped = try score(gps: overTheWire.gps, imu: overTheWire.imu)

        #expect(roundTripped.score.finalScore == direct.score.finalScore)
        #expect(roundTripped.integrity.verdict == direct.integrity.verdict)
        #expect(roundTripped.score.breakdown.paceBps == direct.score.breakdown.paceBps)
        #expect(roundTripped.score.breakdown.smoothnessBps == direct.score.breakdown.smoothnessBps)
        #expect(roundTripped.score.breakdown.controlBps == direct.score.breakdown.controlBps)
        #expect(roundTripped.score.breakdown.complianceBps == direct.score.breakdown.complianceBps)
        #expect(Set(roundTripped.integrity.findings.map(\.flag.rawValue))
            == Set(direct.integrity.findings.map(\.flag.rawValue)))
        #expect(roundTripped.gatesHit == direct.gatesHit)
    }

    // MARK: - Size, which is the point

    @Test("gzip alone earns its keep")
    func compressionIsWorthIt() throws {
        let run = simulatedRun()
        let upload = try TelemetryBlob.upload(gps: run.gps, imu: run.imu)
        // Measured 3.35× on this fixture (1,031,920 → 307,638 bytes). The
        // bound sits below that so it fails when compression silently stops
        // happening, not when zlib changes by a percent.
        #expect(
            upload.compressionRatio > 3.0,
            Comment(rawValue: "expected >3×, got \(upload.compressionRatio)× "
                + "(\(upload.uncompressedByteSize) → \(upload.byteSize) bytes)")
        )
    }

    @Test("end to end, a drive is more than five times smaller")
    func endToEndSaving() throws {
        // What a driver's connection and the storage bill actually see:
        // the blob this code would have uploaded before any of this existed,
        // against the bytes that now go over the wire. Measured 6.7×
        // (2,052,197 → 307,638).
        let run = simulatedRun()
        let before = try fullPrecisionEncode(gps: run.gps, imu: run.imu)
        let after = try TelemetryBlob.upload(gps: run.gps, imu: run.imu)
        let saving = Double(before.count) / Double(after.byteSize)
        #expect(saving > 5.0, Comment(rawValue: "end-to-end saving was \(saving)×"))
    }

    @Test("rounding is worth more than gzip is")
    func quantisationCarriesTheSaving() throws {
        // Recorded because it was the surprise. Gzip on full-precision
        // doubles gives only ~2.4×, not the 8× OPERATIONS.md assumed: a
        // Double serialises to seventeen significant digits, and the trailing
        // ones are floating-point residue, which is the worst thing you can
        // hand a compressor. If someone later removes the rounding as
        // "unnecessary", this says what it was worth.
        let run = simulatedRun()
        let quantised = try Gzip.compress(TelemetryBlob.encode(gps: run.gps, imu: run.imu))
        let full = try Gzip.compress(fullPrecisionEncode(gps: run.gps, imu: run.imu))
        let gain = Double(full.count) / Double(quantised.count)
        #expect(gain > 2.0, Comment(rawValue: "rounding bought only \(gain)×"))
    }

    /// The finding that shaped the precision table, kept as a test so it
    /// cannot be undone by someone tidying up.
    @Test("timestamps are never rounded, because rounding them moved scores")
    func timestampsAreNotRounded() throws {
        let run = simulatedRun(profile: .fastAggressive)
        let decoded = try TelemetryBlob.decode(
            TelemetryBlob.encode(gps: run.gps, imu: run.imu)
        )
        // Not rounded — but not bit-exact either, and the difference
        // matters. JSON itself costs ~1e-7 s on an absolute epoch second,
        // because sixteen significant digits is what a serialiser will
        // spend on 1_754_982_000.2206213. That is ~0.4 ULP and four orders
        // of magnitude below the millisecond that cost this very profile
        // four points of final score. The bound asserted here is 1 µs:
        // comfortably above what JSON costs, comfortably below what the
        // pipeline can feel.
        var worst = 0.0
        for (original, restored) in zip(run.gps, decoded.gps) {
            worst = max(worst, abs(restored.timestamp - original.timestamp))
        }
        for (original, restored) in zip(run.imu, decoded.imu) {
            worst = max(worst, abs(restored.timestamp - original.timestamp))
        }
        #expect(worst < 1e-6, Comment(rawValue: "worst timestamp drift \(worst) s"))
        // And the thing that actually matters: it does not reach the score.
        #expect(worst < 1e-3 / 100)
    }

    // MARK: - The hash the server checks

    @Test("the declared sha256 is over the compressed bytes")
    func hashesTheStoredBytes() throws {
        // score-run fetches the object, hashes what it fetched, and compares
        // before decompressing anything. Hashing the uncompressed payload
        // here would fail every single run — and would do it in production,
        // because nothing local checks it.
        let run = simulatedRun()
        let upload = try TelemetryBlob.upload(gps: run.gps, imu: run.imu)
        #expect(upload.sha256 == SHA256Digest.hex(of: upload.bytes))
        #expect(upload.sha256 != SHA256Digest.hex(of: try Gzip.decompress(upload.bytes)))
        #expect(upload.byteSize == upload.bytes.count)
    }

    @Test("the same drive always produces the same bytes")
    func deterministic() throws {
        let run = simulatedRun()
        let a = try TelemetryBlob.upload(gps: run.gps, imu: run.imu)
        let b = try TelemetryBlob.upload(gps: run.gps, imu: run.imu)
        #expect(a.sha256 == b.sha256)
        #expect(a.bytes == b.bytes)
    }

    // MARK: - The format itself

    @Test("absent values survive as absent, not as zero")
    func absentSentinel() throws {
        // A missing speed is not a speed of zero, and a course of nil is not
        // due north. Collapsing either would change a score.
        let gps = [
            GPSSample(
                timestamp: 1_754_982_000.5,
                coordinate: GeoCoordinate(latitude: 34.02, longitude: -118.77),
                altitude: nil,
                horizontalAccuracy: 5,
                course: nil,
                speed: nil
            )
        ]
        let imu = [IMUSample(
            timestamp: 1_754_982_000.5,
            accelX: 0, accelY: 0, accelZ: 1, gyroX: 0, gyroY: 0, gyroZ: 0
        )]
        let decoded = try TelemetryBlob.decode(TelemetryBlob.encode(gps: gps, imu: imu))
        #expect(decoded.gps[0].course == nil)
        #expect(decoded.gps[0].speed == nil)
        #expect(decoded.gps[0].altitude == nil)
    }

    @Test("a real course of zero is not read as absent")
    func zeroIsNotAbsent() throws {
        // Due north, stationary. The sentinel is -9999 precisely so that
        // legitimate zeros survive.
        let gps = [
            GPSSample(
                timestamp: 1.0,
                coordinate: GeoCoordinate(latitude: 34.02, longitude: -118.77),
                altitude: 0,
                horizontalAccuracy: 5,
                course: 0,
                speed: 0
            )
        ]
        let decoded = try TelemetryBlob.decode(TelemetryBlob.encode(gps: gps, imu: []))
        #expect(decoded.gps[0].course == 0)
        #expect(decoded.gps[0].speed == 0)
        #expect(decoded.gps[0].altitude == 0)
    }

    @Test("sample order is preserved exactly")
    func preservesOrder() throws {
        let run = simulatedRun()
        let decoded = try TelemetryBlob.decode(TelemetryBlob.encode(gps: run.gps, imu: run.imu))
        #expect(decoded.gps.count == run.gps.count)
        #expect(decoded.imu.count == run.imu.count)
        for (original, restored) in zip(run.gps, decoded.gps) {
            #expect(abs(original.timestamp - restored.timestamp) < 1e-6)
            #expect(abs(original.coordinate.latitude - restored.coordinate.latitude) < 1e-7)
        }
    }

    @Test("quantisation is bounded by the precision it claims")
    func quantisationBounds() {
        // Each field must round to within half a unit of its last decimal
        // place — the guarantee the precision table is making.
        #expect(abs(TelemetryBlob.quantise(34.0259007324108, 7) - 34.0259007324108) <= 5e-8)
        #expect(abs(TelemetryBlob.quantise(-0.0032592050051714794, 6) + 0.0032592050051714794)
            <= 5e-7)
        #expect(TelemetryBlob.quantise(-9999, 3) == -9999)
        #expect(TelemetryBlob.quantise(2.5, 0) == 3)
        #expect(TelemetryBlob.quantise(-2.5, 0) == -3)
    }

    @Test("a non-finite reading does not become a valid-looking number")
    func nonFiniteSurvivesAsNonFinite() {
        // A NaN GPS fix voided an entire run once (audit 2026-08-13). The
        // quantiser must not launder one into 0 — the pipeline's finiteness
        // gate is what catches it, and it can only catch what reaches it.
        #expect(TelemetryBlob.quantise(.nan, 7).isNaN)
        #expect(TelemetryBlob.quantise(.infinity, 7).isInfinite)
    }

    @Test("the storage path keeps the owner prefix the database enforces")
    func storagePathShape() {
        let userId = "6f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"
        let path = TelemetryBlob.storagePath(userId: userId)
        // `validate_telemetry_path` requires `^<owner-uuid>/[A-Za-z0-9._-]+$`
        // and rejects anything else, so this is the shape the row must have.
        #expect(path.hasPrefix("\(userId)/"))
        #expect(path.hasSuffix(".json.gz"))
        let object = String(path.dropFirst(userId.count + 1))
        #expect(object.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) })
    }

    // MARK: - Helpers

    /// The pre-quantisation encoder, kept only so the saving can be measured.
    private func fullPrecisionEncode(gps: [GPSSample], imu: [IMUSample]) throws -> Data {
        let payload: [String: Any] = [
            "formatVersion": 1,
            "gps": gps.map {
                [$0.timestamp, $0.coordinate.latitude, $0.coordinate.longitude,
                 $0.horizontalAccuracy, $0.course ?? -9999, $0.speed ?? -9999,
                 $0.altitude ?? -9999]
            },
            "imu": imu.map {
                [$0.timestamp, $0.accelX, $0.accelY, $0.accelZ,
                 $0.gyroX, $0.gyroY, $0.gyroZ]
            },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private var scoringConfigURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SOSyncTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SmoooothKit
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("configs/scoring/v1.json")
    }
}
