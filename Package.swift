// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "winMgr",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "WinMgrCore", targets: ["WinMgrCore"]),
        .library(name: "WinMgrIPC", targets: ["WinMgrIPC"]),
        .executable(name: "WinMgrApp", targets: ["WinMgrApp"]),
        .executable(name: "WinMgrCtl", targets: ["WinMgrCtl"])
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
        .target(
            name: "WinMgrIPC",
            dependencies: ["WinMgrCore"]
        ),
        .executableTarget(
            name: "WinMgrApp",
            dependencies: ["WinMgrCore", "WinMgrIPC", "CLua"]
        ),
        .executableTarget(
            name: "WinMgrCtl",
            dependencies: ["WinMgrCore", "WinMgrIPC"]
        ),
        .testTarget(
            name: "WinMgrCoreTests",
            dependencies: [
                "WinMgrCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "WinMgrIPCTests",
            dependencies: [
                "WinMgrCore",
                "WinMgrIPC",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
