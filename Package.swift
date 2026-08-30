// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalOCR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalOCRCore", targets: ["LocalOCRCore"]),
        .library(name: "LocalOCRModelCore", targets: ["LocalOCRModelCore"]),
        .library(name: "LocalOCRService", targets: ["LocalOCRService"]),
        .library(name: "LocalOCRIntelligence", targets: ["LocalOCRIntelligence"]),
        .library(name: "LocalOCRStudioKit", targets: ["LocalOCRStudioKit"]),
        .executable(name: "localocr", targets: ["LocalOCRCLIExecutable"]),
        .executable(name: "localocr-mcp", targets: ["LocalOCRMCPExecutable"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            exact: "1.8.2"
        ),
        .package(
            url: "https://github.com/apple/swift-system.git",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "LocalOCRModelCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
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
            name: "LocalOCRIntelligence",
            dependencies: ["LocalOCRModelCore", "LocalOCRService"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "LocalOCRStudioKit",
            dependencies: ["LocalOCRIntelligence", "LocalOCRService", "LocalOCRCore"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "LocalOCRCommandKit",
            dependencies: [
                "LocalOCRIntelligence",
                "LocalOCRService",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "MCPStdio",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: ["Upstream"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "LocalOCRMCP",
            dependencies: [
                "LocalOCRIntelligence",
                "LocalOCRService",
                "MCPStdio"
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
            name: "LocalOCRModelCoreTests",
            dependencies: ["LocalOCRModelCore"],
            path: "tests/LocalOCRModelCoreTests",
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
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LocalOCRStudioKitTests",
            dependencies: ["LocalOCRStudioKit", "LocalOCRService", "LocalOCRCore"],
            path: "tests/LocalOCRStudioKitTests",
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
            dependencies: [
                "LocalOCRMCP",
                "LocalOCRService",
                "LocalOCRCore",
                "MCPStdio"
            ],
            path: "tests/LocalOCRMCPTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "MCPStdioTests",
            dependencies: ["MCPStdio"],
            path: "tests/MCPStdioTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LocalOCRIntelligenceTests",
            dependencies: [
                "LocalOCRIntelligence",
                "LocalOCRModelCore",
                "LocalOCRService",
                "LocalOCRCore"
            ],
            path: "tests/LocalOCRIntelligenceTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        )
    ]
)
