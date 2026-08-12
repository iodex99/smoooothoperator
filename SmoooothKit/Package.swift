// swift-tools-version: 6.1
// SmoooothKit — the platform-independent core of Smooooth Operator.
//
// Every engine (telemetry, scoring, integrity, ghosts, courses, sync) lives
// here and must build and test on Linux (`swift build && swift test`).
// Apple-only frameworks (SwiftUI, CoreLocation, CoreMotion, StoreKit,
// SwiftData, MapKit) are forbidden in this package — the iOS layer in /App
// adapts them behind the protocols defined here. tools/kit-purity-check.sh
// enforces this in CI.

import PackageDescription

let package = Package(
    name: "SmoooothKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SmoooothKit",
            targets: [
                "SOCore", "SOModels", "SOTelemetry", "SOCourse", "SOScoring",
                "SOIntegrity", "SOGhost", "SOSync", "SOSimulator",
            ]
        ),
        .executable(name: "sogen", targets: ["sogen"]),
    ],
    targets: [
        // MARK: Libraries
        .target(name: "SOCore"),
        .target(name: "SOModels", dependencies: ["SOCore"]),
        .target(name: "SOTelemetry", dependencies: ["SOModels"]),
        .target(name: "SOCourse", dependencies: ["SOModels", "SOTelemetry"]),
        .target(name: "SOScoring", dependencies: ["SOTelemetry", "SOCourse"]),
        .target(name: "SOIntegrity", dependencies: ["SOModels", "SOTelemetry"]),
        .target(name: "SOGhost", dependencies: ["SOTelemetry", "SOCourse"]),
        .target(name: "SOSync", dependencies: ["SOModels"]),
        .target(
            name: "SOSimulator",
            dependencies: ["SOTelemetry", "SOCourse", "SOScoring", "SOIntegrity", "SOGhost"]
        ),

        // MARK: Executable — simulate / score / verify / emit golden vectors
        .executableTarget(name: "sogen", dependencies: ["SOSimulator", "SOSync"]),

        // MARK: Tests
        .testTarget(name: "SOCoreTests", dependencies: ["SOCore"]),
        .testTarget(name: "SOModelsTests", dependencies: ["SOModels"]),
        .testTarget(name: "SOTelemetryTests", dependencies: ["SOTelemetry"]),
        .testTarget(name: "SOCourseTests", dependencies: ["SOCourse"]),
        .testTarget(name: "SOScoringTests", dependencies: ["SOScoring"]),
        .testTarget(name: "SOIntegrityTests", dependencies: ["SOIntegrity"]),
        .testTarget(name: "SOGhostTests", dependencies: ["SOGhost"]),
        .testTarget(name: "SOSyncTests", dependencies: ["SOSync"]),
        .testTarget(name: "SOSimulatorTests", dependencies: ["SOSimulator"]),
    ]
)
