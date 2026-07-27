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
        .executable(name: "Mynah", targets: ["Mynah"]),
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
        //
        // A library, not an executable, and the distinction is load-bearing:
        // nothing can import an executable target, so while this was one it had
        // zero tests. That is how the app shipped recommending a brain it could
        // not build — `BrainSetupPlanner` emitted seven backend identifiers,
        // `BrainFactory` handled four, and no test could see both lists at once.
        .target(
            name: "MynahMac",
            dependencies: ["SageVoiceCore"]
        ),
        // Nothing but `@main`. Everything real lives in the library above so it
        // can be tested.
        .executableTarget(
            name: "Mynah",
            dependencies: ["MynahMac"]
        ),
        .testTarget(
            name: "SageVoiceCoreTests",
            dependencies: ["SageVoiceCore", "MynahMac"]
        ),
    ]
)
