// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Eco",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Solo la parte de separación de voces (diarización), sin TTS.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: ["Diarizer"]),
    ],
    targets: [
        .executableTarget(
            name: "Eco",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
