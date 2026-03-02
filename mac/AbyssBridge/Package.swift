// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AbyssBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "AbyssBridge", targets: ["AbyssBridgeApp"]),
    ],
    dependencies: [
        .package(path: "../BridgeCore"),
    ],
    targets: [
        .executableTarget(
            name: "AbyssBridgeApp",
            dependencies: [
                .product(name: "BridgeCore", package: "BridgeCore"),
            ]
        ),
    ]
)
