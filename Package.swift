// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacDirStat",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "MacDirStat",
            path: "Sources/MacDirStat",
            resources: [
                .copy("AppIcon.icns")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(name: "MacDirStatTests", dependencies: ["MacDirStat"])
    ]
)
