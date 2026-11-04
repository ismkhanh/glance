// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glance",
    platforms: [.macOS(.v13)],
    targets: [
        // Eye-tracking test (stretch goal: Glance's own eye + head tracker).
        .executableTarget(
            name: "GazeTest",
            path: "Sources/GazeTest"
        ),
        // Glance: talk to the window under the pointer. Command-line version first.
        .executableTarget(
            name: "Glance",
            path: "Sources/Glance"
        ),
        // Unit tests of the safety rules and the agent loop; live evals of the agent when GLANCE_LIVE_EVAL=1.
        .testTarget(
            name: "GlanceTests",
            dependencies: ["Glance"],
            path: "Tests/GlanceTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
