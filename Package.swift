// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CCBarCore", targets: ["CCBarCore"]),
        .executable(name: "ccbar-cli", targets: ["ccbar-cli"]),
        .executable(name: "ccbar-app", targets: ["ccbar-app"]),
    ],
    dependencies: [
        // Sparkle — macOS app auto-update framework. Used by the app target
        // only; CCBarCore stays dependency-free for headless testability.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "CCBarCore",
            path: "Sources/CCBarCore"
        ),
        .executableTarget(
            name: "ccbar-cli",
            dependencies: ["CCBarCore"],
            path: "Sources/ccbar-cli"
        ),
        .executableTarget(
            name: "ccbar-app",
            dependencies: [
                "CCBarCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ccbar-app"
        ),
        .testTarget(
            name: "CCBarCoreTests",
            dependencies: ["CCBarCore"],
            path: "Tests/CCBarCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
