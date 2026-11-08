// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QidianKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "QidianKit", targets: ["QidianKit"]),
        .executable(name: "QidianReader", targets: ["QidianReader"]),
    ],
    targets: [
        .target(
            name: "QidianKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "QidianReader",
            dependencies: ["QidianKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QidianKitTests",
            dependencies: ["QidianKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QidianReaderTests",
            dependencies: ["QidianReader"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
