// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BridgeCore",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
    ],
    dependencies: [
        .package(path: "../../shared/libs/swift-protocol"),
    ],
    targets: [
        .target(
            name: "BridgeCore",
            dependencies: [
                .product(name: "SwiftProtocol", package: "swift-protocol"),
            ]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
