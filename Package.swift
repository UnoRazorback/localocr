// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalOCR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalOCRCore", targets: ["LocalOCRCore"]),
        .library(name: "LocalOCRService", targets: ["LocalOCRService"]),
        .executable(name: "localocr", targets: ["LocalOCRCLIExecutable"]),
        .executable(name: "localocr-mcp", targets: ["LocalOCRMCPExecutable"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            exact: "1.8.2"
        ),
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk",
            exact: "0.12.1"
        )
    ],
    targets: [
        .target(
            name: "LocalOCRCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "LocalOCRService",
            dependencies: ["LocalOCRCore"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "LocalOCRCommandKit",
            dependencies: [
                "LocalOCRService",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "LocalOCRMCP",
            dependencies: [
                "LocalOCRService",
                .product(name: "MCP", package: "swift-sdk")
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "LocalOCRCLIExecutable",
            dependencies: ["LocalOCRCommandKit"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "LocalOCRMCPExecutable",
            dependencies: ["LocalOCRMCP"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LocalOCRCoreTests",
            dependencies: ["LocalOCRCore"],
            path: "tests/LocalOCRCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LocalOCRServiceTests",
            dependencies: ["LocalOCRService"],
            path: "tests/LocalOCRServiceTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LocalOCRCommandKitTests",
            dependencies: ["LocalOCRCommandKit"],
            path: "tests/LocalOCRCommandKitTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LocalOCRMCPTests",
            dependencies: ["LocalOCRMCP"],
            path: "tests/LocalOCRMCPTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        )
    ]
)
