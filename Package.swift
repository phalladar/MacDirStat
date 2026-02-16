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
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
