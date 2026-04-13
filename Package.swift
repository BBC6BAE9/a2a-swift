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
            name: "A2A",
            targets: ["A2A"]
        ),
    ],
    targets: [
        .target(
            name: "A2A",
            path: "Sources/A2A",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "A2ATests",
            dependencies: ["A2A"],
            path: "Tests/A2ATests"
        ),
    ]
)
