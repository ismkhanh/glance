// swift-tools-version:5.9
import PackageDescription

// Glance VR for Mac: streams your Mac's windows to the Glance VR app on Meta Quest and acts in them.
//   swift run -c release GlanceVR
let package = Package(
    name: "GlanceVR",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "GlanceVR", path: "Sources/GlanceVR"),
    ],
    swiftLanguageVersions: [.v5]
)
