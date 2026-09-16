// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Gmail",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Gmail",
            path: "Sources/Gmail"
        )
    ]
)
