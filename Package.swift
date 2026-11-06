// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Platform-independent game logic: math, beatmaps, level generation,
    // music synthesis, calibration, swing tracking and scoring.
    .target(name: "SaberCore"),
    .testTarget(name: "SaberCoreTests", dependencies: ["SaberCore"]),
]

var products: [Product] = [
    .library(name: "SaberCore", targets: ["SaberCore"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "SwiftSaber",
        dependencies: ["SaberCore"],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SceneKit"),
            .linkedFramework("CoreMotion"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("CoreAudio"),
            .linkedFramework("AudioToolbox"),
        ]
    )
)
products.append(.executable(name: "SwiftSaber", targets: ["SwiftSaber"]))
#endif

let package = Package(
    name: "SwiftSaber",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
