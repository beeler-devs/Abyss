// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Abyss",
    platforms: [
        .macOS(.v13),  // required by WhisperKit; needed for `swift test` on Mac
        .iOS(.v17)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Abyss",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Abyss",
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Abyss/Info.plist"],
                    .when(platforms: [.iOS])
                )
            ]
        ),
        .testTarget(
            name: "AbyssTests",
            dependencies: ["Abyss"],
            path: "AbyssTests"
        )
    ]
)
