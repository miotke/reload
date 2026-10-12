// swift-tools-version: 6.4
import PackageDescription

/// Swift 6.2+ "approachable concurrency" behaviour for every target.
let modernConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "Reload",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "AddonKit", targets: ["AddonKit"]),
        .executable(name: "reload", targets: ["reload"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AddonKit",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: modernConcurrency
        ),
        .executableTarget(
            name: "reload",
            dependencies: [
                "AddonKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: modernConcurrency
        ),
        .testTarget(
            name: "AddonKitTests",
            dependencies: ["AddonKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: modernConcurrency
        ),
        .testTarget(
            name: "reloadTests",
            dependencies: ["reload", "AddonKit"],
            swiftSettings: modernConcurrency
        ),
    ]
)
