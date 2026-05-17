// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "winMgr",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "WinMgrCore", targets: ["WinMgrCore"]),
        .executable(name: "WinMgrApp", targets: ["WinMgrApp"])
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
            name: "WinMgrCore"
        ),
        .executableTarget(
            name: "WinMgrApp",
            dependencies: ["WinMgrCore", "CLua"]
        ),
        .testTarget(
            name: "WinMgrCoreTests",
            dependencies: [
                "WinMgrCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
