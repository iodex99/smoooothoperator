import Foundation
import Testing
import SOCore
@testable import SOCourse

/// Contract fixtures shared with the TypeScript validate-course port: the
/// server must reject exactly what the client rejects (spec §25 / L8).
@Suite("Course validation contract")
struct CourseValidationContractTests {
    struct Fixture: Codable {
        struct Case: Codable {
            var name: String
            var polyline: [[Double]]
            var checkpoints: [[Double]]
            var expectedIssues: [String]
        }

        var formatVersion: Int
        var cases: [Case]
    }

    static let fixture: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/contracts/course-validation.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    private func kindName(_ issue: CourseValidationIssue) -> String {
        switch issue {
        case .tooShort: "tooShort"
        case .tooLong: "tooLong"
        case .insufficientRoutePoints: "insufficientRoutePoints"
        case .invalidCoordinate: "invalidCoordinate"
        case .excessivePointSpacing: "excessivePointSpacing"
        case .insufficientCheckpoints: "insufficientCheckpoints"
        case .duplicateCheckpointSequence: "duplicateCheckpointSequence"
        case .nonContiguousCheckpointSequence: "nonContiguousCheckpointSequence"
        case .checkpointOffRoute: "checkpointOffRoute"
        case .checkpointsOutOfOrder: "checkpointsOutOfOrder"
        case .checkpointsTooClose: "checkpointsTooClose"
        case .startNotAtRouteStart: "startNotAtRouteStart"
        case .finishNotAtRouteEnd: "finishNotAtRouteEnd"
        }
    }

    @Test("every fixture case produces exactly the expected issue kinds",
          arguments: fixture.cases.map(\.name))
    func contractCase(name: String) throws {
        let testCase = try #require(Self.fixture.cases.first { $0.name == name })
        let polyline = testCase.polyline.map { GeoCoordinate(latitude: $0[0], longitude: $0[1]) }
        let checkpoints = testCase.checkpoints.map {
            Checkpoint(
                sequence: Int($0[0]),
                center: GeoCoordinate(latitude: $0[1], longitude: $0[2]),
                radiusMeters: $0[3]
            )
        }
        let issues = CourseValidator().validate(polyline: polyline, checkpoints: checkpoints)
        let kinds = Set(issues.map(kindName)).sorted()
        #expect(kinds == testCase.expectedIssues,
                "\(name): got \(kinds), expected \(testCase.expectedIssues)")
    }
}
