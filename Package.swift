// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AutoThemeSwitcher",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AutoThemeSwitcherCore",
            targets: ["AutoThemeSwitcherCore"]
        ),
        .executable(
            name: "AutoThemeSwitcher",
            targets: ["AutoThemeSwitcher"]
        )
    ],
    targets: [
        .target(
            name: "AutoThemeSwitcherCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "AutoThemeSwitcher",
            dependencies: ["AutoThemeSwitcherCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "AutoThemeSwitcherCoreTests",
            dependencies: ["AutoThemeSwitcherCore"]
        )
    ]
)
