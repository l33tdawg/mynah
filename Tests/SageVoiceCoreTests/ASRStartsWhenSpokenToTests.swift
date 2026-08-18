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

    private static let discoveryPath = "Sources/SageVoiceCore/LocalASRDiscovery.swift"

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    // MARK: - Reading one declaration, and only that declaration

    /// A refusal that names itself, rather than a trap or a silently wrong slice.
    ///
    /// Four of the tests below read product source and assert on what is in it.
    /// When the thing they read has moved, the useful outcome is a sentence
    /// saying which declaration went missing and what to do about it. The
    /// alternative this replaces was `range(of:)!` — a rename crashed the test
    /// process, taking every test scheduled after it in that process with it,
    /// and reported nothing about why.
    private struct DeclarationNotFound: Error, CustomStringConvertible {
        let marker: String
        let detail: String

        var description: String {
            "could not read `\(marker)` out of \(ASRStartsWhenSpokenToTests.discoveryPath): \(detail). "
                + "Re-point this test at the declaration's new name — do not widen the search, "
                + "because a window that spans more than one declaration can be satisfied by the wrong one."
        }
    }

    /// One declaration in full: from the line that opens it to the line that
    /// closes it at the same indentation.
    ///
    /// **Why this exists, with the numbers that made it necessary.** These tests
    /// used to slice a fixed character count after the declaration they were
    /// about — `prefix(3000)`, `prefix(2500)`, `prefix(2000)`, `prefix(1200)` —
    /// and a character count is wrong in both directions at once. Measured
    /// against `LocalASRDiscovery.swift` on 18 August 2026:
    ///
    /// - `LocalASRRuntime.prepare` is **4,326 characters** (lines 625–710). The
    ///   3,000-character window stopped 1,327 characters short of its closing
    ///   brace, so the regression guard — *preparation must not start the
    ///   server* — never looked at the last third of the function, including the
    ///   entire off-Darwin branch. Reintroducing the eager start anywhere in
    ///   that third would not have failed a thing.
    /// - `ManagedWhisperKitTranscriber` is **1,472 characters** (lines 739–768).
    ///   The 2,500-character window ran 1,028 characters *past* its closing brace
    ///   and into `CascadingAudioFileTranscriber`, so every
    ///   `XCTAssertTrue(body.contains(...))` about the managed transcriber could
    ///   have been satisfied by a neighbouring type's text instead.
    ///
    /// Both shapes are the same defect: a guard that reports success without
    /// doing the work. Anchoring on the closing brace cannot truncate and cannot
    /// overrun, and when the anchor is not there it throws rather than guessing.
    ///
    /// An ambiguous marker throws too. `func transcribe(audioFile:options:)` is
    /// declared three times in this one file — on `ManagedWhisperKitTranscriber`,
    /// on `CascadingAudioFileTranscriber` and on `WhisperCommandASRBackend` — so
    /// "first match in the file" is a coin toss dressed as a lookup. Search
    /// inside the type you mean, and let a second match be a failure.
    private func declaration(startingWith marker: String, in text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        let matches = lines.indices.filter { lines[$0].contains(marker) }

        guard let opening = matches.first else {
            throw DeclarationNotFound(
                marker: marker,
                detail: "no line contains it, so it has been renamed or removed"
            )
        }
        guard matches.count == 1 else {
            throw DeclarationNotFound(
                marker: marker,
                detail: "\(matches.count) lines contain it (\(matches.map { $0 + 1 }.map(String.init).joined(separator: ", "))), "
                    + "so which declaration this test is about is ambiguous"
            )
        }

        let indent = String(lines[opening].prefix { $0 == " " })
        let closingLine = indent + "}"
        guard let closing = lines[(opening + 1)...].firstIndex(of: closingLine) else {
            throw DeclarationNotFound(
                marker: marker,
                detail: "it opens at line \(opening + 1) but no later line is exactly \"\(closingLine)\", "
                    + "so its closing brace cannot be found and any slice would be a guess"
            )
        }

        return lines[opening...closing].joined(separator: "\n")
    }

    // MARK: - Tests

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
    ///
    /// Read over the whole of `prepare`, closing brace included. The window this
    /// replaces covered 69% of the function.
    func testPreparationChecksTheFilesAndDoesNotStartTheServer() throws {
        let discovery = try source(Self.discoveryPath)
        let prepare = try declaration(startingWith: "public func prepare(", in: discovery)

        XCTAssertTrue(
            prepare.contains("verifyInstallation()"),
            "preparation no longer checks that the helper and model are present, so a bundle "
                + "shipped without them fails at the first voice note instead of at boot"
        )
        XCTAssertFalse(
            prepare.contains("await supervisor.ensureRunning()"),
            "preparation starts the ASR server again, which puts a 626MB model on every Mac "
                + "at boot whether or not anybody ever speaks to it"
        )
    }

    /// And the first transcription is what starts it — otherwise the change
    /// above would simply have removed speech recognition.
    func testTranscribingStartsTheServerOnDemand() throws {
        let discovery = try source(Self.discoveryPath)
        let transcriber = try declaration(
            startingWith: "struct ManagedWhisperKitTranscriber",
            in: discovery
        )

        XCTAssertTrue(
            transcriber.contains("try await supervisor.ensureRunning()"),
            "nothing starts the ASR server on demand, so moving it off the boot path removed "
                + "speech recognition rather than deferring it"
        )
        XCTAssertTrue(
            transcriber.contains("inner.transcribe("),
            "the wrapper never delegates, so it cannot transcribe anything"
        )
    }

    /// **Checked before every transcription, not once at boot.** The endpoint
    /// used to be pinned when the daemon started, so a server that went away
    /// took speech recognition with it until somebody restarted the daemon —
    /// and on this owner's Mac that server belongs to QuietType.
    ///
    /// The method is looked up *inside* `ManagedWhisperKitTranscriber`. Taking
    /// the first `func transcribe(audioFile:options:)` in the file, as this test
    /// used to, picks whichever of the three declarations happens to be written
    /// first — and it would have gone on passing while asserting about
    /// `CascadingAudioFileTranscriber` or `WhisperCommandASRBackend`.
    func testTheServerIsRecheckedRatherThanTrustedFromBoot() throws {
        let discovery = try source(Self.discoveryPath)
        let transcriber = try declaration(
            startingWith: "struct ManagedWhisperKitTranscriber",
            in: discovery
        )
        let transcribe = try declaration(
            startingWith: "func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String",
            in: transcriber
        )

        XCTAssertTrue(
            transcribe.contains("ensureRunning"),
            "the transcription path trusts a server it checked once at boot"
        )
    }

    /// The timing #34 asked for, on every request rather than in an average.
    /// "5.8 s to transcribe 521 ms of speech" is invisible in a mean.
    func testEveryTranscriptionIsTimedAndSaysWhoseServerDidIt() throws {
        let discovery = try source(Self.discoveryPath)
        let transcriber = try declaration(
            startingWith: "struct ManagedWhisperKitTranscriber",
            in: discovery
        )

        XCTAssertTrue(
            transcriber.contains("[asr] transcribed"),
            "no per-request ASR timing is emitted"
        )
        XCTAssertTrue(
            transcriber.contains("isUsingSomebodyElsesServer"),
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
