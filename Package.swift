// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalOCR",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LocalOCRCore", targets: ["LocalOCRCore"])],
    targets: [
        .target(
            name: "LocalOCRCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LocalOCRCoreTests",
            dependencies: ["LocalOCRCore"],
            path: "tests/LocalOCRCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
