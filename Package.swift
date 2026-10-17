// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Paneflo",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PanefloCore", targets: ["PanefloCore"]),
        .executable(name: "Paneflo", targets: ["PanefloApp"]),
    ],
    targets: [
        .target(name: "PanefloCore"),
        .executableTarget(name: "PanefloApp", dependencies: ["PanefloCore"]),
        .testTarget(name: "PanefloCoreTests", dependencies: ["PanefloCore"]),
    ]
)
