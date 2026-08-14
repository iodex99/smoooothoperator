import Foundation
import SOCore
import Testing
@testable import SOCourse

/// You make a course by driving it. These tests hold the line that whatever
/// comes out of a real drive is something the shared validator will accept —
/// because a creation flow that produces courses the server then rejects is
/// worse than no creation flow at all.
@Suite("Building a course from a drive")
struct CourseBuilderTests {
    /// A drive along a road, sampled at 10 Hz with realistic GPS noise.
    static func drive(
        metres: Double,
        curviness: Double = 0,
        noiseMetres: Double = 0,
        seed: UInt64 = 7
    ) -> [GeoCoordinate] {
        var rng = SeededRandomNumberGenerator(seed: seed)
        var points: [GeoCoordinate] = []
        let stepMetres = 2.0            // ~20 m/s at 10 Hz
        let steps = Int(metres / stepMetres)
        var lat = 34.0
        var lon = -118.0
        var heading = 0.0
        for index in 0..<max(steps, 2) {
            heading += sin(Double(index) / 40.0) * curviness
            let dLat = cos(heading) * stepMetres / 111_320
            let dLon = sin(heading) * stepMetres / (111_320 * cos(lat * .pi / 180))
            lat += dLat
            lon += dLon
            let jitterLat = noiseMetres > 0
                ? (Double.random(in: 0...1, using: &rng) - 0.5) * noiseMetres / 111_320 : 0
            let jitterLon = noiseMetres > 0
                ? (Double.random(in: 0...1, using: &rng) - 0.5) * noiseMetres / 111_320 : 0
            points.append(GeoCoordinate(latitude: lat + jitterLat, longitude: lon + jitterLon))
        }
        return points
    }

    static func validate(_ proposal: CourseBuilder.Proposal) -> [CourseValidationIssue] {
        CourseValidator(config: .default).validate(
            polyline: proposal.polyline,
            checkpoints: proposal.checkpoints
        )
    }

    // MARK: - The contract that matters

    @Test("a course built from a real drive passes the server's own validator")
    func builtCoursesValidate() throws {
        // This is the whole point. The app builds it, the server validates it
        // with the same rules, and the driver must not be told "invalid
        // course" for a road they just drove.
        for metres in [1_500.0, 4_300, 12_000, 40_000] {
            let proposal = try #require(
                CourseBuilder.build(from: Self.drive(metres: metres, curviness: 0.04)),
                "no proposal for a \(metres) m drive"
            )
            let issues = Self.validate(proposal)
            #expect(issues.isEmpty, "\(metres) m drive produced \(issues)")
        }
    }

    @Test("noisy GPS still yields a valid course")
    func noiseIsTolerated() throws {
        // Real fixes wander by several metres. If that broke creation, the
        // feature would work only in the simulator.
        let proposal = try #require(
            CourseBuilder.build(from: Self.drive(metres: 6_000, curviness: 0.05, noiseMetres: 12))
        )
        #expect(Self.validate(proposal).isEmpty)
    }

    @Test("simplification keeps the shape but not every fix")
    func simplifies() throws {
        let raw = Self.drive(metres: 8_000, curviness: 0.05)
        let proposal = try #require(CourseBuilder.build(from: raw))
        #expect(proposal.polyline.count < raw.count / 4, "barely simplified")
        #expect(proposal.polyline.count > 8, "over-simplified into a straight line")
        // The length must survive: distance is what pace is scored against.
        let rawLength = CourseBuilder.cumulativeDistances(raw).last ?? 0
        #expect(
            abs(proposal.distanceMeters - rawLength) / rawLength < 0.05,
            "length drifted from \(rawLength) to \(proposal.distanceMeters)"
        )
    }

    @Test("no segment exceeds the spacing the validator allows")
    func noExcessiveSpacing() throws {
        // Simplification will happily leave one 3 km straight, which the
        // validator rejects — correctly, since two points cannot be matched
        // against. Re-splitting is what makes a motorway course possible.
        let proposal = try #require(
            CourseBuilder.build(from: Self.drive(metres: 30_000, curviness: 0.001))
        )
        for (a, b) in zip(proposal.polyline, proposal.polyline.dropFirst()) {
            #expect(a.distance(to: b) <= 500, "gap of \(a.distance(to: b)) m")
        }
        #expect(Self.validate(proposal).isEmpty)
    }

    // MARK: - Gates

    @Test("gates sit on the route, in order, and far enough apart")
    func gatesAreWellFormed() throws {
        let proposal = try #require(
            CourseBuilder.build(from: Self.drive(metres: 5_000, curviness: 0.04))
        )
        #expect(proposal.checkpoints.count == 5)
        #expect(proposal.checkpoints.map(\.sequence) == [0, 1, 2, 3, 4])
        // Every gate centre must BE a vertex, not merely near one.
        for gate in proposal.checkpoints {
            #expect(
                proposal.polyline.contains { $0.distance(to: gate.center) < 0.5 },
                "gate \(gate.sequence) is not on the line"
            )
        }
        for (a, b) in zip(proposal.checkpoints, proposal.checkpoints.dropFirst()) {
            #expect(
                a.center.distance(to: b.center) >= 200,
                "gates \(a.sequence)/\(b.sequence) only \(a.center.distance(to: b.center)) m apart"
            )
        }
    }

    @Test("the first and last gates are the start and the finish")
    func endGatesAreEnds() throws {
        let proposal = try #require(CourseBuilder.build(from: Self.drive(metres: 4_000)))
        let first = try #require(proposal.polyline.first)
        let last = try #require(proposal.polyline.last)
        #expect(proposal.checkpoints.first?.center.distance(to: first) ?? 999 < 1)
        #expect(proposal.checkpoints.last?.center.distance(to: last) ?? 999 < 1)
    }

    // MARK: - What a driver will actually hand it

    @Test("a drive that never left the car park is refused")
    func tooShortIsRefused() throws {
        // Not a crash and not a bad course — the validator says tooShort and
        // the UI can tell the driver to drive further.
        let proposal = try #require(CourseBuilder.build(from: Self.drive(metres: 300)))
        let issues = Self.validate(proposal)
        #expect(issues.contains { if case .tooShort = $0 { true } else { false } })
    }

    @Test("standing still produces nothing rather than a degenerate course")
    func stationaryProducesNothing() {
        let parked = [GeoCoordinate](
            repeating: GeoCoordinate(latitude: 34, longitude: -118), count: 500
        )
        #expect(CourseBuilder.build(from: parked) == nil)
    }

    @Test("garbage coordinates never reach the server")
    func garbageIsRejected() {
        let poison = [
            GeoCoordinate(latitude: .nan, longitude: -118),
            GeoCoordinate(latitude: 34, longitude: .infinity),
            GeoCoordinate(latitude: 999, longitude: -118),
        ]
        #expect(CourseBuilder.build(from: poison) == nil)
        // A drive with a couple of bad fixes in the middle still works —
        // they are dropped, not fatal.
        var mixed = Self.drive(metres: 3_000)
        mixed.insert(GeoCoordinate(latitude: .nan, longitude: .nan), at: 100)
        let proposal = CourseBuilder.build(from: mixed)
        #expect(proposal != nil)
        #expect(Self.validate(proposal!).isEmpty)
    }

    @Test("a lap that returns to its start is refused, not silently broken")
    func loopIsRefused() throws {
        // Out and back to the same point puts the start and finish gates on
        // top of each other. The validator has a rule for exactly this, and
        // the driver needs to hear it rather than get a course whose finish
        // triggers instantly.
        let out = Self.drive(metres: 2_000)
        let loop = out + out.reversed()
        let proposal = try #require(CourseBuilder.build(from: loop))
        let issues = Self.validate(proposal)
        #expect(
            !issues.isEmpty,
            "a there-and-back lap should not validate as a point-to-point course"
        )
    }

    @Test("a twistier road counts more turns")
    func turnCountTracksCurviness() throws {
        let straight = try #require(
            CourseBuilder.build(from: Self.drive(metres: 5_000, curviness: 0.001))
        )
        let twisty = try #require(
            CourseBuilder.build(from: Self.drive(metres: 5_000, curviness: 0.09))
        )
        #expect(
            twisty.turnCount > straight.turnCount,
            "straight \(straight.turnCount) vs twisty \(twisty.turnCount)"
        )
    }

    @Test("building is deterministic")
    func deterministic() throws {
        // Two creators driving the identical trace must get the identical
        // course, or the same road becomes two catalog entries.
        let raw = Self.drive(metres: 6_000, curviness: 0.04, noiseMetres: 5)
        let a = try #require(CourseBuilder.build(from: raw))
        let b = try #require(CourseBuilder.build(from: raw))
        #expect(a == b)
    }
}
