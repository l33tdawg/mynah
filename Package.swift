// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "sage-voice-bridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SageVoiceCore", targets: ["SageVoiceCore"]),
        .executable(name: "sage-voiced", targets: ["sage-voiced"]),
    ],
    targets: [
        // Speech-to-text core, lifted from QuietType (github.com/l33tdawg/quiettype).
        // Deliberately has no external dependencies.
        .target(name: "SageVoiceCore"),
        .executableTarget(
            name: "sage-voiced",
            dependencies: ["SageVoiceCore"]
        ),
        .testTarget(
            name: "SageVoiceCoreTests",
            dependencies: ["SageVoiceCore"]
        ),
    ]
)
