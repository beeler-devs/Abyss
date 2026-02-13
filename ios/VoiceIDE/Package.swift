// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceIDE",
    platforms: [
        .iOS(.v17)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceIDE",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "VoiceIDE"
        ),
        .testTarget(
            name: "VoiceIDETests",
            dependencies: ["VoiceIDE"],
            path: "VoiceIDETests"
        )
    ]
)
