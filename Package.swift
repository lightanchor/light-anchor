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
        .testTarget(
            name: "LightAnchorTests",
            dependencies: ["LightAnchor"],
            path: "Tests/LightAnchorTests"
        )
    ]
)
