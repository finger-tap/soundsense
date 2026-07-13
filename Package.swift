// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "soundsense",
    platforms: [
        .macOS(.v11),
        .iOS(.v14),
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
