// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickScribe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SpecCatch",
            path: "Sources/SpecCatch",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "QuickScribe",
            dependencies: ["SpecCatch"],
            path: "Sources/QuickScribe"
        )
    ]
)
