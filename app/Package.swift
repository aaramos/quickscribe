// swift-tools-version:5.9
import PackageDescription

// Apple frameworks only. Do not add package dependencies: needing nothing else
// is the point of this version.
let package = Package(
    name: "QuickScribe",
    // macOS 27 is the only release this has been tested on, and the one with
    // Apple's rebuilt on-device model.
    platforms: [.macOS("27.0")],
    targets: [
        .target(
            name: "SpecCatch",
            path: "Sources/SpecCatch",
            publicHeadersPath: "include"
        ),
        .target(
            name: "QuickScribeCore",
            path: "Sources/QuickScribeCore"
        ),
        .executableTarget(
            name: "QuickScribe",
            dependencies: ["SpecCatch", "QuickScribeCore"],
            path: "Sources/QuickScribe"
        ),
        .executableTarget(
            name: "apple-eval",
            dependencies: ["QuickScribeCore"],
            path: "Sources/AppleEval"
        ),
        .testTarget(
            name: "QuickScribeTests",
            dependencies: ["QuickScribe", "QuickScribeCore"],
            path: "Tests/QuickScribeTests"
        )
    ]
)
