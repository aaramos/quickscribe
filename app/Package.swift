// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickScribe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuickScribe",
            path: "Sources/QuickScribe"
        )
    ]
)
