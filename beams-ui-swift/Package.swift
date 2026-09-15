// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Beams",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Beams",
            path: "Sources/Beams",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "BeamsTests",
            dependencies: ["Beams"],
            path: "Tests/BeamsTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
