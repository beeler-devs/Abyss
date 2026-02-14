// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceIDE",
    platforms: [
        .macOS(.v13),  // required by WhisperKit; needed for `swift test` on Mac
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
            path: "VoiceIDE",
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "VoiceIDE/Info.plist"],
                    .when(platforms: [.iOS])
                )
            ]
        ),
        .testTarget(
            name: "VoiceIDETests",
            dependencies: ["VoiceIDE"],
            path: "VoiceIDETests"
        )
    ]
)
