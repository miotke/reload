// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForeverAddons",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AddonKit", targets: ["AddonKit"]),
        .executable(name: "addonctl", targets: ["addonctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AddonKit",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .executableTarget(
            name: "addonctl",
            dependencies: [
                "AddonKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "AddonKitTests",
            dependencies: ["AddonKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
