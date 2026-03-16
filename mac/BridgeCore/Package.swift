// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BridgeCore",
    platforms: [
        .macOS(.v14),
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
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
