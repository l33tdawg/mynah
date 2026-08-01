import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **That the nice voice repairs itself, and that failing to fetch it is loud.**
///
/// The owner heard a robot on `//call` and reasonably blamed the model: *"i am
/// reaching 'robot voice' instead of the nice sounding one and i am already on
/// deepseekv4 api"*. It had nothing to do with the model. Kokoro's weights were
/// never on his Mac —
/// `~/Library/Application Support/SAGE Voice Bridge/Kokoro/` did not exist — so
/// `CallVoiceLibrary.load()` answered `.missing` and calls fell back to the
/// macOS built-in voice.
///
/// The silence was structural. The only trigger lived inside the Signal link
/// flow, which was a deliberate and good choice — *"the signal part //call only
/// comes in once you link signal - download it then"* — and the wrong *only*
/// choice: anybody who linked a phone before that code shipped never runs it.
/// And its outcome went to the log at info, so a failed 354 MB download and a
/// successful one read identically.
///
/// *"seems like a silent failure in the voice download thing bro - thought we
/// said it would download in the background."*
@MainActor
final class CallVoiceProvisioningTests: XCTestCase {

    /// Counts calls from a `@Sendable` closure. A captured `var` is a data race
    /// the compiler already warns about and Swift 6 rejects outright.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func tick() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// A scratch pause marker, so nothing here reads or writes the *developer's*
    /// own `~/Library/Application Support/SAGE Voice Bridge/paused` — the
    /// hazard `AppModel.init` warns about at length.
    private func makeApp() -> AppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("call-voice-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppModel(
            defaults: UserDefaults(suiteName: "call-voice-\(UUID().uuidString)")!,
            pauseState: PauseState(fileURL: root.appendingPathComponent("paused"))
        )
    }

    /// Asking again when the files are already there must cost nothing, because
    /// that is what makes running it on *every* launch defensible.
    func testAnAlreadyInstalledVoiceIsNotFetchedAgain() async {
        let app = makeApp()
        let asked = Counter()

        await app.installCallVoiceIfNeeded {
            _ = asked.tick()
            return .alreadyInstalled
        }

        XCTAssertEqual(asked.count, 1, "the installer was not consulted")
    }

    /// **The one that would have caught this.** Every failure shape has to reach
    /// the installer and come back — none of them may be quietly treated as
    /// success, because the owner hears all four as the same robot.
    func testEveryFailureShapeIsReported() async {
        let failures: [KokoroAssets.Outcome] = [
            .notEnoughSpace(needed: 354_000_000, free: 1_000),
            .couldNotReach(asset: "kokoro-v1.0.onnx", reason: "the network dropped"),
            .corrupted(asset: "voices-v1.0.bin"),
            .couldNotSave("permission denied")
        ]

        for outcome in failures {
            let app = makeApp()
            await app.installCallVoiceIfNeeded { outcome }
            XCTAssertFalse(
                outcome.isReady,
                "\(outcome) is being counted as a working voice"
            )
            XCTAssertFalse(
                outcome.logLine.isEmpty,
                "\(outcome) would be recorded as an empty line, which is the silence again"
            )
        }
    }

    /// A failure must not be the end of it. The installer is consulted on every
    /// launch precisely so yesterday's dropped connection is retried today.
    func testAFailureIsRetriedOnTheNextLaunch() async {
        let attempts = Counter()
        let install: @Sendable () async -> KokoroAssets.Outcome = {
            attempts.tick() == 1
                ? .couldNotReach(asset: "kokoro-v1.0.onnx", reason: "offline")
                : .installed(byteCount: 353_746_785)
        }

        await makeApp().installCallVoiceIfNeeded(install: install)
        await makeApp().installCallVoiceIfNeeded(install: install)

        XCTAssertEqual(attempts.count, 2, "a failed fetch was never tried again")
    }
}
