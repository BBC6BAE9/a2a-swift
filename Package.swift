// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "A2A",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "A2AClient",
            targets: ["A2AClient"]
        ),
        .library(
            name: "A2AServer",
            targets: ["A2AServer"]
        ),
        .library(
            name: "A2ACore",
            targets: ["A2ACore"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.29.0"
        ),
    ],
    targets: [
        .target(
            name: "A2ACore",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/A2ACore"
        ),
        .target(
            name: "A2AClient",
            dependencies: [
                "A2ACore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/A2AClient",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "A2AServer",
            dependencies: [
                "A2ACore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/A2AServer",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "A2ATests",
            dependencies: ["A2AClient", "A2AServer"],
            path: "Tests/A2ATests"
        ),
    ]
)
