import XCTest
@testable import SageVoiceCore

/// **A 626 MB model was resident on every Mac, whether or not anybody spoke.**
///
/// `LocalASRRuntime.prepare()` ran at daemon boot and called `ensureRunning()`,
/// which starts a whisper-large-v3 server with encoder and decoder both on
/// `cpuAndGPU` and no quality-of-service. `stop()` is only reached from `deinit`,
/// so once started it stayed for the life of the daemon. On a Mac that never
/// receives a voice note it did nothing but occupy the machine, and it is the
/// leading candidate for the tester's *"it's made my laptop very laggy"*.
///
/// The comment defending the eager start argued "better to know now than when
/// the first voice note arrives", which is a diagnosis argument and a correct
/// one — a bundle shipped with no ASR helper once crash-looped the daemon under
/// launchd. But the thing being diagnosed is a **missing file**, and a missing
/// file is visible without loading the weights.
///
/// Measured on the owner's Mac, 6 August 2026, and it is why he could never
/// reproduce the complaint: port 50060 was owned by
/// `/Applications/QuietType.app/Contents/MacOS/argmax-cli`, so `ensureRunning`
/// found it healthy and returned before starting anything. Mynah had been
/// transcribing through another application's process, and nothing said so.
final class ASRStartsWhenSpokenToTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// A missing helper is still caught at boot, and without a process.
    func testAMissingHelperIsRefusedWithoutStartingAnything() throws {
        let supervisor = WhisperKitServerSupervisor(
            executableURL: URL(fileURLWithPath: "/nowhere/argmax-cli")
        )

        XCTAssertThrowsError(try supervisor.verifyInstallation()) { error in
            guard case WhisperKitServerSupervisorError.missingExecutable = error else {
                return XCTFail("expected missingExecutable, got \(error)")
            }
        }
        XCTAssertFalse(
            supervisor.isProcessRunning,
            "checking the installation started a server, which is the whole cost this avoids"
        )
    }

    /// **The regression guard.** Preparation must check the files and must not
    /// start the process; the process belongs to the first transcription.
    func testPreparationChecksTheFilesAndDoesNotStartTheServer() throws {
        let discovery = try source("Sources/SageVoiceCore/LocalASRDiscovery.swift")
        guard let prepare = discovery.range(of: "public func prepare(") else {
            return XCTFail("LocalASRRuntime.prepare has been renamed")
        }
        // The body up to the cascading transcriber it returns.
        let body = String(discovery[prepare.lowerBound...].prefix(3000))

        XCTAssertTrue(
            body.contains("verifyInstallation()"),
            "preparation no longer checks that the helper and model are present, so a bundle "
                + "shipped without them fails at the first voice note instead of at boot"
        )
        XCTAssertFalse(
            body.contains("await supervisor.ensureRunning()"),
            "preparation starts the ASR server again, which puts a 626MB model on every Mac "
                + "at boot whether or not anybody ever speaks to it"
        )
    }

    /// And the first transcription is what starts it — otherwise the change
    /// above would simply have removed speech recognition.
    func testTranscribingStartsTheServerOnDemand() throws {
        let discovery = try source("Sources/SageVoiceCore/LocalASRDiscovery.swift")
        guard let wrapper = discovery.range(of: "struct ManagedWhisperKitTranscriber") else {
            return XCTFail("the managed transcriber has been renamed")
        }
        let body = String(discovery[wrapper.lowerBound...].prefix(2000))

        XCTAssertTrue(
            body.contains("try await supervisor.ensureRunning()"),
            "nothing starts the ASR server on demand, so moving it off the boot path removed "
                + "speech recognition rather than deferring it"
        )
        XCTAssertTrue(
            body.contains("inner.transcribe("),
            "the wrapper never delegates, so it cannot transcribe anything"
        )
    }

    /// **Checked before every transcription, not once at boot.** The endpoint
    /// used to be pinned when the daemon started, so a server that went away
    /// took speech recognition with it until somebody restarted the daemon —
    /// and on this owner's Mac that server belongs to QuietType.
    func testTheServerIsRecheckedRatherThanTrustedFromBoot() throws {
        let discovery = try source("Sources/SageVoiceCore/LocalASRDiscovery.swift")
        guard let wrapper = discovery.range(of: "func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String"),
              discovery.distance(from: discovery.startIndex, to: wrapper.lowerBound)
                > discovery.distance(from: discovery.startIndex,
                                     to: discovery.range(of: "struct ManagedWhisperKitTranscriber")!.lowerBound)
        else {
            return XCTFail("the managed transcriber's transcribe method has moved")
        }
        let body = String(discovery[wrapper.lowerBound...].prefix(1200))
        XCTAssertTrue(
            body.contains("ensureRunning"),
            "the transcription path trusts a server it checked once at boot"
        )
    }

    /// The timing #34 asked for, on every request rather than in an average.
    /// "5.8 s to transcribe 521 ms of speech" is invisible in a mean.
    func testEveryTranscriptionIsTimedAndSaysWhoseServerDidIt() throws {
        let discovery = try source("Sources/SageVoiceCore/LocalASRDiscovery.swift")
        guard let wrapper = discovery.range(of: "struct ManagedWhisperKitTranscriber") else {
            return XCTFail("the managed transcriber has been renamed")
        }
        let body = String(discovery[wrapper.lowerBound...].prefix(2500))

        XCTAssertTrue(body.contains("[asr] transcribed"), "no per-request ASR timing is emitted")
        XCTAssertTrue(
            body.contains("isUsingSomebodyElsesServer"),
            "the timing line does not say whose server did the work, which is the difference "
                + "between a Mac carrying its own copy of the model and one borrowing another's"
        )
    }

    /// The daemon is the process somebody complained about, so the daemon is the
    /// one that has to write the numbers down.
    func testTheDaemonPassesItsOwnLog() throws {
        let daemon = try source("Sources/sage-voiced/main.swift")
        XCTAssertTrue(
            daemon.contains("LocalASRRuntime.shared.prepare(log: { note($0) })"),
            "the daemon prepares ASR without a log, so the per-request timing goes nowhere and "
                + "the lag complaint stays unmeasured"
        )
    }
}
