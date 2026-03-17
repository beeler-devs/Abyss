// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AbyssBridge",
    platforms: [
        .macOS(.v14),
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
            ],
            resources: [
                .process("Assets.xcassets"),
                .copy("AppIcon.icns"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
