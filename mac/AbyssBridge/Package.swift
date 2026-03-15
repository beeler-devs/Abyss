// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AbyssBridge",
    platforms: [
        .macOS(.v26),
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
