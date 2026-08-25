// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LightAnchor",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "LightAnchor",
            targets: ["LightAnchor"]
        ),
        .library(
            name: "LightAnchorEventCore",
            targets: ["LightAnchorEventCore"]
        ),
        .executable(
            name: "LightAnchorEvent",
            targets: ["LightAnchorEvent"]
        )
    ],
    targets: [
        .executableTarget(
            name: "LightAnchor",
            path: "Sources/LightAnchor",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "LightAnchorEventCore",
            path: "Sources/LightAnchorEventCore"
        ),
        .executableTarget(
            name: "LightAnchorEvent",
            dependencies: ["LightAnchorEventCore"],
            path: "Sources/LightAnchorEvent"
        ),
        .testTarget(
            name: "LightAnchorTests",
            dependencies: ["LightAnchor", "LightAnchorEventCore"],
            path: "Tests/LightAnchorTests"
        )
    ]
)
