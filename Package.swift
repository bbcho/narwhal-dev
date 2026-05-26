// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "narwhal",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "NarwhalCore", targets: ["NarwhalCore"]),
        .library(name: "NarwhalIPC", targets: ["NarwhalIPC"]),
        .executable(name: "NarwhalApp", targets: ["NarwhalApp"]),
        .executable(name: "NarwhalCtl", targets: ["NarwhalCtl"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2")
    ],
    targets: [
        .systemLibrary(
            name: "CLua",
            pkgConfig: "lua5.4",
            providers: [
                .brew(["lua"])
            ]
        ),
        .target(
            name: "NarwhalCore"
        ),
        .target(
            name: "NarwhalIPC",
            dependencies: ["NarwhalCore"]
        ),
        .target(
            name: "NarwhalAppSupport",
            dependencies: ["NarwhalCore"]
        ),
        .target(
            name: "NarwhalAppRuntime",
            dependencies: ["NarwhalCore", "NarwhalIPC", "NarwhalAppSupport", "CLua"]
        ),
        .executableTarget(
            name: "NarwhalApp",
            dependencies: ["NarwhalAppRuntime"]
        ),
        .executableTarget(
            name: "NarwhalCtl",
            dependencies: ["NarwhalCore", "NarwhalIPC"]
        ),
        .testTarget(
            name: "NarwhalCoreTests",
            dependencies: [
                "NarwhalCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "NarwhalIPCTests",
            dependencies: [
                "NarwhalCore",
                "NarwhalIPC",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "NarwhalAppSupportTests",
            dependencies: [
                "NarwhalCore",
                "NarwhalAppSupport",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "NarwhalAppRuntimeTests",
            dependencies: [
                "NarwhalAppRuntime",
                "NarwhalAppSupport",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "NarwhalLiveVerifierTests",
            dependencies: [
                "NarwhalAppRuntime",
                "NarwhalCore",
                "NarwhalAppSupport",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
