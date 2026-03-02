// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftProtocol",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SwiftProtocol", targets: ["SwiftProtocol"]),
    ],
    targets: [
        .target(name: "SwiftProtocol"),
        .testTarget(name: "SwiftProtocolTests", dependencies: ["SwiftProtocol"]),
    ]
)
