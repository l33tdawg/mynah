// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "sage-voice-bridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SageVoiceCore", targets: ["SageVoiceCore"]),
        .executable(name: "sage-voiced", targets: ["sage-voiced"]),
        .executable(name: "MynahMac", targets: ["MynahMac"]),
    ],
    targets: [
        // Speech-to-text core, lifted from QuietType (github.com/l33tdawg/quiettype).
        // Deliberately has no external dependencies.
        .target(
            name: "SageVoiceCore",
            // Operator documentation that lives next to the code it describes.
            // Not a resource — it must not be copied into the bundle.
            exclude: ["Transport/SETUP.md"]
        ),
        .executableTarget(
            name: "sage-voiced",
            dependencies: ["SageVoiceCore"]
        ),
        // The app a non-technical owner actually sees. The CLI above stays as
        // the debugging surface — every screen here drives the same
        // SageVoiceCore types, so neither is a reimplementation of the other.
        .executableTarget(
            name: "MynahMac",
            dependencies: ["SageVoiceCore"]
        ),
        .testTarget(
            name: "SageVoiceCoreTests",
            dependencies: ["SageVoiceCore"]
        ),
    ]
)
