// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "soundsense",
    platforms: [
        .macOS(.v11),
        .iOS(.v15),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "SoundSenseCore", targets: ["SoundSenseCore"]),
        .executable(name: "soundsense", targets: ["soundsense"]),
    ],
    targets: [
        .target(
            name: "SoundSenseCore",
            path: "Sources/SoundSenseCore"
        ),
        .executableTarget(
            name: "soundsense",
            dependencies: ["SoundSenseCore"],
            path: "Sources/soundsense"
        ),
    ]
)
