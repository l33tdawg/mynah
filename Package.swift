// swift-tools-version: 5.9

import Foundation
import PackageDescription

// **The native voice is built only where its runtime has been provisioned.**
//
// `vendor/` is gitignored and produced by the scripts in `scripts/` — the same
// arrangement `asr` and `signal` already use. So on a fresh clone the ONNX
// Runtime header genuinely is not there, and a target that referenced it
// unconditionally would make the package fail to load rather than fail to
// build, which is a much worse error to hand somebody.
//
// Run `scripts/provision-onnxruntime.sh` and the targets below appear.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let onnxRuntimeRoot = packageRoot + "/vendor/onnxruntime"
let hasOnnxRuntime = FileManager.default.fileExists(
    atPath: onnxRuntimeRoot + "/lib/libonnxruntime.dylib"
)

/// Absolute rather than relative, because these reach the linker with no
/// promise about its working directory — and an `@rpath` that resolves during
/// `swift build` but not during `swift test` is a failure that only appears in
/// CI. The bundle-relative entry is what lets the shipped app find the copy
/// `package-app.sh` puts in `Contents/Frameworks`.
let onnxLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(onnxRuntimeRoot)/lib",
        "-lonnxruntime",
        "-Xlinker", "-rpath", "-Xlinker", "\(onnxRuntimeRoot)/lib",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
    ])
]

let onnxTargets: [Target] = hasOnnxRuntime ? [
    .systemLibrary(name: "COnnxRuntime", path: "Sources/COnnxRuntime"),
    .target(
        name: "KokoroEngine",
        dependencies: ["SageVoiceCore", "COnnxRuntime"],
        linkerSettings: onnxLinkerSettings
    ),
] : []

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
            // `KokoroEngine` only where its runtime is staged, so the call sites
            // are guarded with `#if canImport(KokoroEngine)` and a fresh clone
            // still builds and still speaks — through the system voice.
            dependencies: ["SageVoiceCore"] + (hasOnnxRuntime ? ["KokoroEngine"] : []),
            linkerSettings: hasOnnxRuntime ? onnxLinkerSettings : []
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
    ] + onnxTargets + (hasOnnxRuntime ? [
        .testTarget(
            name: "KokoroEngineTests",
            dependencies: ["KokoroEngine"],
            linkerSettings: onnxLinkerSettings
        )
    ] : [])
)
