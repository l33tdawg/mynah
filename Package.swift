// swift-tools-version: 5.9

import Foundation
import PackageDescription

// **This manifest is Swift, and it is compiled for the machine doing the build.**
//
// So `#if os(macOS)` here does not mean "when the product runs on a Mac" — it
// means "when this package is being loaded on a Mac". That is exactly the knob
// needed: the Mac-only half of this package (AppKit/SwiftUI) cannot even be
// described on Linux, because `MynahMac` would drag `Mynah` and the app product
// into a graph that has no AppKit to build them against. A manifest that fails
// to *load* is a worse error than one that fails to build, so the Mac-only
// targets are simply not declared off-Darwin.
#if os(macOS)
let isDarwin = true
#else
let isDarwin = false
#endif

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

// The probe has to name the artefact the local linker would actually consume,
// which is not the same filename on every platform. Probing for a `.dylib` on
// Linux is a probe that can only ever answer "no" — and it would answer "no"
// even on a machine where the runtime *had* been provisioned, silently
// downgrading to the system voice with nothing to indicate why.
#if os(macOS)
let onnxLibraryPath = onnxRuntimeRoot + "/lib/libonnxruntime.dylib"
#else
let onnxLibraryPath = onnxRuntimeRoot + "/lib/libonnxruntime.so"
#endif

let hasOnnxRuntime = FileManager.default.fileExists(atPath: onnxLibraryPath)

/// Absolute rather than relative, because these reach the linker with no
/// promise about its working directory — and an `@rpath` that resolves during
/// `swift build` but not during `swift test` is a failure that only appears in
/// CI. The bundle-relative entry is what lets the shipped app find the copy
/// `package-app.sh` puts in `Contents/Frameworks`.
///
/// `@executable_path` is Mach-O syntax and `ld.lld` rejects it, so it is emitted
/// on Darwin only — there is no app bundle to find on the other two platforms
/// anyway.
#if os(macOS)
let onnxLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(onnxRuntimeRoot)/lib",
        "-lonnxruntime",
        "-Xlinker", "-rpath", "-Xlinker", "\(onnxRuntimeRoot)/lib",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
    ])
]
#else
let onnxLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(onnxRuntimeRoot)/lib",
        "-lonnxruntime",
        "-Xlinker", "-rpath", "-Xlinker", "\(onnxRuntimeRoot)/lib",
    ])
]
#endif

let onnxTargets: [Target] = hasOnnxRuntime ? [
    .systemLibrary(name: "COnnxRuntime", path: "Sources/COnnxRuntime"),
    .target(
        name: "KokoroEngine",
        dependencies: ["SageVoiceCore", "COnnxRuntime"],
        linkerSettings: onnxLinkerSettings
    ),
] : []

// **swift-crypto is a Linux dependency and is not declared on a Mac.**
//
// Off-Darwin there is no CryptoKit, so `Crypto` stands in for it — same API,
// BoringSSL underneath. On a Mac the whole dependency is absent from the
// manifest rather than merely unlinked: declaring it would put a checkout and a
// `Package.resolved` entry between a clean clone and a release build, and this
// package has had no dependencies to fetch at all until now. The
// `.when(platforms:)` condition below is the second lock on the same door.
//
// The consequence to know about: cross-compiling to Linux *from* a Mac host
// would load this manifest as the Mac one and find no `Crypto`. Build for Linux
// on Linux (the Docker image CI already uses).
let packageDependencies: [Package.Dependency]
let cryptoDependencies: [Target.Dependency]
if isDarwin {
    packageDependencies = []
    cryptoDependencies = []
} else {
    packageDependencies = [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0")
    ]
    cryptoDependencies = [
        .product(
            name: "Crypto",
            package: "swift-crypto",
            condition: .when(platforms: [.linux])
        )
    ]
}

// Operator documentation that lives next to the code it describes. Not a
// resource — it must not be copied into the bundle.
//
// `Call/` joins it off-Darwin: the live voice call is a Mac feature and is not
// being ported. Excluding the directory in the manifest, rather than `#if`-ing
// out thirteen files, keeps the exclusion in one auditable place.
var coreExclusions: [String] = ["Transport/SETUP.md"]
if !isDarwin {
    coreExclusions.append("Call")
}

// Hoisted out of the `Package(...)` literal, and explicitly typed.
//
// **These were inline ternaries and they broke CI.** `dependencies:
// ["SageVoiceCore"] + (hasOnnxRuntime ? ["KokoroEngine"] : [])` asks the type
// checker to infer array literals, an optional-ish branch and a `+` overload
// inside an already-large `Package` initialiser — and on a cold runner it gives
// up: *"the compiler is unable to type-check this expression in reasonable
// time"*. It compiled here because the manifest was already cached, so the
// failure only ever appeared on GitHub, on a tag, after the release was cut.
//
// Naming the type removes the inference entirely.
let daemonDependencies: [Target.Dependency] =
    hasOnnxRuntime ? ["SageVoiceCore", "KokoroEngine"] : ["SageVoiceCore"]
let macDependencies: [Target.Dependency] =
    hasOnnxRuntime ? ["SageVoiceCore", "KokoroEngine"] : ["SageVoiceCore"]

var coreDependencies: [Target.Dependency] = []
coreDependencies += cryptoDependencies

// The app a non-technical owner actually sees. The CLI stays as the debugging
// surface — every screen here drives the same SageVoiceCore types, so neither
// is a reimplementation of the other.
//
// A library, not an executable, and the distinction is load-bearing: nothing
// can import an executable target, so while this was one it had zero tests.
// That is how the app shipped recommending a brain it could not build —
// `BrainSetupPlanner` emitted seven backend identifiers, `BrainFactory` handled
// four, and no test could see both lists at once.
let macOnlyTargets: [Target] = isDarwin ? [
    .target(
        name: "MynahMac",
        // `KokoroEngine` for the same reason `sage-voiced` has it, and it was
        // missing for a reason worth writing down: the Listen button on the
        // call-voice row synthesized through `KokoroHTTPSynthesizer`, which
        // speaks to `python run.py` on port 8765. Nothing in this repository
        // ever starts that — it was a development service — so the button could
        // not work in any shipped build and said "Mynah couldn't play that
        // voice just now" on every Mac including this one.
        //
        // Guarded with `#if canImport(KokoroEngine)` at the call site, so a
        // fresh clone with no `vendor/onnxruntime` still builds.
        dependencies: macDependencies,
        linkerSettings: hasOnnxRuntime ? onnxLinkerSettings : []
    ),
    // Nothing but `@main`. Everything real lives in the library above so it can
    // be tested.
    .executableTarget(
        name: "Mynah",
        dependencies: ["MynahMac"]
    ),
] : []

let macOnlyProducts: [Product] = isDarwin ? [
    .executable(name: "Mynah", targets: ["Mynah"]),
] : []

// **`MynahMac` is AppKit, so the tests that cover it can only run where it
// exists — and the dependency edge below was only half of saying so.**
//
// The other half has to be written in the test files themselves. A
// `@testable import MynahMac` is a hard error off Darwin no matter what this
// manifest declares, so while those imports were unguarded this target could
// not *build* on Linux at all: `swift build --build-tests` came back with
// 398 × "no such module 'MynahMac'" from 59 files. The comment that used to sit
// here claimed the SageVoiceCore half of the suite kept working off Darwin. It
// did not. Nothing in this suite had ever run there — including the tests
// written specifically to prove the Linux port, which sit inside
// `#if !os(macOS)` and are therefore compiled out on the one platform that
// could build them. They had never executed anywhere.
//
// Each Mac-only file now carries `#if os(macOS)` around its whole contents, and
// the same is done for the four EventKit files, the WebKit one, the
// JavaScriptCore one and the twenty that cover the voice call — whose sources
// this manifest already excludes off Darwin (`coreExclusions`).
//
// Kept as one target rather than split into a second, Darwin-only one because
// the two halves share helpers: `SwiftSourceScan.swift` alone is used by
// sixteen files on both sides of the line, so a split would have to duplicate
// it or grow a third support target. A whole-file `#if` costs exactly the same
// granularity as a whole-file move, moves nothing, and states the platform fact
// in the file that depends on it.
var coreTestDependencies: [Target.Dependency] = ["SageVoiceCore"]
if isDarwin {
    coreTestDependencies.append("MynahMac")
}
coreTestDependencies += cryptoDependencies

let kokoroTestTargets: [Target] = hasOnnxRuntime ? [
    .testTarget(
        name: "KokoroEngineTests",
        dependencies: ["KokoroEngine"],
        linkerSettings: onnxLinkerSettings
    )
] : []

var packageTargets: [Target] = [
    // Speech-to-text core, lifted from QuietType (github.com/l33tdawg/quiettype).
    .target(
        name: "SageVoiceCore",
        dependencies: coreDependencies,
        exclude: coreExclusions
    ),
    .executableTarget(
        name: "sage-voiced",
        // `KokoroEngine` only where its runtime is staged, so the call sites
        // are guarded with `#if canImport(KokoroEngine)` and a fresh clone
        // still builds and still speaks — through the system voice.
        dependencies: daemonDependencies,
        linkerSettings: hasOnnxRuntime ? onnxLinkerSettings : []
    ),
]
packageTargets += macOnlyTargets
packageTargets += [
    .testTarget(
        name: "SageVoiceCoreTests",
        dependencies: coreTestDependencies
    ),
]
packageTargets += onnxTargets
packageTargets += kokoroTestTargets

var packageProducts: [Product] = [
    .library(name: "SageVoiceCore", targets: ["SageVoiceCore"]),
    .executable(name: "sage-voiced", targets: ["sage-voiced"]),
]
packageProducts += macOnlyProducts

let package = Package(
    name: "sage-voice-bridge",
    platforms: [
        .macOS(.v14)
    ],
    products: packageProducts,
    dependencies: packageDependencies,
    targets: packageTargets
)
