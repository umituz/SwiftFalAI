// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SwiftFalAI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwiftFalAI",
            targets: ["SwiftFalAI"])
    ],
    targets: [
        .target(
            name: "SwiftFalAI",
            dependencies: [],
            path: "Sources/SwiftFalAI"
        ),
        .testTarget(
            name: "SwiftFalAITests",
            dependencies: ["SwiftFalAI"],
            path: "Tests/SwiftFalAITests"
        )
    ]
)
