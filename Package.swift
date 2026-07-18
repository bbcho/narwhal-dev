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
        // Immutable revision for the upstream swift-6.2.4-RELEASE tag.
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170"
        )
    ],
    targets: [
        .systemLibrary(
            name: "CLua",
            pkgConfig: "lua5.5",
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
            dependencies: ["NarwhalAppRuntime"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Packaging/NarwhalCLIInfo.plist"
                ])
            ]
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
