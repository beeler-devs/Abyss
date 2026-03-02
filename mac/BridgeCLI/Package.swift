// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BridgeCLI",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "abyss-bridge", targets: ["BridgeCLI"]),
    ],
    dependencies: [
        .package(path: "../BridgeCore"),
    ],
    targets: [
        .executableTarget(
            name: "BridgeCLI",
            dependencies: [
                .product(name: "BridgeCore", package: "BridgeCore"),
            ]
        ),
    ]
)
