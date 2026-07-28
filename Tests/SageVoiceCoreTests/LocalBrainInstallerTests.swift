import XCTest
@testable import SageVoiceCore

/// Getting a local brain working.
///
/// The gap this closes has been open since the setup screen shipped:
/// `EnvironmentProbe` could see the model was missing and `BrainSetupPlanner`
/// could explain why "Fully on this Mac" was unavailable, but nothing could
/// *fetch* it — so the one option that keeps the owner's words on their machine
/// was permanently greyed out behind "go and do this yourself in a terminal".
final class LocalBrainInstallerTests: XCTestCase {

    // MARK: Progress arithmetic

    /// Weighted by bytes, not by step. The runtime is ~129 MB against a ~3.4 GB
    /// model, so a bar that sat at 50% through the pull would be lying about the
    /// half that actually takes the time.
    func testTheBarIsWeightedByBytesNotBySteps() {
        let runtimeDone = LocalBrainInstaller.Phase.startingRuntime.fraction
        XCTAssertNotNil(runtimeDone)
        XCTAssertLessThan(
            runtimeDone!,
            0.3,
            "finishing the runtime looked like a third of the job; it is a fraction of the bytes"
        )

        let halfTheModel = LocalBrainInstaller.Phase.downloadingModel(
            status: "pulling 61aa3858e9d3",
            completedBytes: LocalBrainModelCatalog.approximateModelDownloadBytes / 2,
            totalBytes: LocalBrainModelCatalog.approximateModelDownloadBytes
        ).fraction
        XCTAssertNotNil(halfTheModel)
        XCTAssertGreaterThan(halfTheModel!, runtimeDone!)
        XCTAssertLessThan(halfTheModel!, 1)
    }

    func testTheBarNeverGoesBackwardsOrPastTheEnd() {
        var previous = 0.0
        let steps: [LocalBrainInstaller.Phase] = [
            .idle,
            .downloadingRuntime(completedBytes: 0, totalBytes: 129_000_000),
            .downloadingRuntime(completedBytes: 129_000_000, totalBytes: 129_000_000),
            .startingRuntime,
            .downloadingModel(status: "", completedBytes: 0, totalBytes: 3_400_000_000),
            .downloadingModel(status: "", completedBytes: 3_400_000_000, totalBytes: 3_400_000_000),
            .downloadingEmbeddingModel(status: "", completedBytes: 0, totalBytes: 274_000_000),
            .downloadingEmbeddingModel(status: "", completedBytes: 274_000_000, totalBytes: 274_000_000),
            .verifyingModels,
            .ready
        ]
        for step in steps {
            guard let fraction = step.fraction else { continue }
            XCTAssertGreaterThanOrEqual(fraction, previous, "the bar went backwards at \(step)")
            XCTAssertLessThanOrEqual(fraction, 1)
            previous = fraction
        }
        XCTAssertEqual(LocalBrainInstaller.Phase.ready.fraction, 1)
    }

    /// A step that cannot report bytes must not stall the bar at zero.
    func testAnUnknownTotalStillPlacesTheBar() {
        XCTAssertNotNil(
            LocalBrainInstaller.Phase.downloadingRuntime(completedBytes: 0, totalBytes: nil).fraction
        )
        XCTAssertNotNil(
            LocalBrainInstaller.Phase.downloadingModel(status: "pulling manifest", completedBytes: nil, totalBytes: nil)
                .fraction
        )
        XCTAssertNotNil(
            LocalBrainInstaller.Phase.downloadingEmbeddingModel(
                status: "pulling manifest",
                completedBytes: nil,
                totalBytes: nil
            ).fraction
        )
    }

    // MARK: What the owner is told

    /// Ollama's status for the bulk of a pull is "pulling 61aa3858e9d3". That is
    /// a digest, and it means nothing to anyone.
    func testTheDigestNeverReachesTheOwner() {
        let sentence = LocalBrainInstaller.Phase.downloadingModel(
            status: "pulling 61aa3858e9d3022e8fca725550089addd9289c4446f33bd09dfd12f95f2a6792",
            completedBytes: 1,
            totalBytes: 2
        ).sentence
        XCTAssertFalse(sentence.contains("61aa"))
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("gigabyte"), "no sense of how long this takes")
    }

    /// The finish line is the product's actual promise, so it says it.
    func testReadyRepeatsTheOnlyReasonToChooseThis() {
        XCTAssertTrue(
            LocalBrainInstaller.Phase.ready.sentence.localizedCaseInsensitiveContains("leave this Mac")
        )
    }

    /// Disk and network are the two failures an owner can act on, so they are
    /// named. Everything else says plainly that it failed rather than
    /// pretending to diagnose.
    func testFailuresTheOwnerCanActOnAreNamed() {
        XCTAssertTrue(
            LocalBrainInstaller.explain(URLError(.notConnectedToInternet))
                .localizedCaseInsensitiveContains("internet")
        )
        XCTAssertTrue(
            LocalBrainInstaller.explain(URLError(.timedOut)).localizedCaseInsensitiveContains("timed out")
        )
        XCTAssertTrue(
            LocalBrainInstaller.explain(CocoaError(.fileWriteOutOfSpace))
                .localizedCaseInsensitiveContains("space")
        )
    }

    func testAnUnfinishedPhaseIsNotReportedAsFinished() {
        XCTAssertFalse(LocalBrainInstaller.Phase.idle.isFinished)
        XCTAssertFalse(LocalBrainInstaller.Phase.startingRuntime.isFinished)
        XCTAssertTrue(LocalBrainInstaller.Phase.ready.isFinished)
        XCTAssertTrue(LocalBrainInstaller.Phase.failed("nope").isFinished)
    }

    // MARK: Sequencing

    func testRuntimePinMatchesSAGEsKnownRelease() {
        XCTAssertEqual(OllamaRuntimeInstaller.release, "v0.31.1")
        XCTAssertEqual(OllamaRuntimeInstaller.archiveByteCount, 129_037_451)
        XCTAssertEqual(OllamaRuntimeInstaller.archiveSHA256.count, 64)
    }

    func testRuntimeArchiveCannotWriteOutsideItsStagingDirectory() {
        XCTAssertThrowsError(
            try OllamaRuntimeInstaller.validateArchiveEntries("ollama\n../Library/LaunchAgents/evil\n")
        )
        XCTAssertThrowsError(
            try OllamaRuntimeInstaller.validateArchiveEntries("/tmp/evil\n")
        )
        XCTAssertNoThrow(
            try OllamaRuntimeInstaller.validateArchiveEntries("ollama\nlib/ollama/libmetal.dylib\n")
        )
    }

    /// The last word must be `.ready` or `.failed` — a progress view that never
    /// receives a terminal phase spins forever.
    func testEveryRunEndsOnATerminalPhase() async {
        let installer = LocalBrainInstaller(
            client: OllamaClient(baseURL: URL(string: "http://127.0.0.1:1")!),
            runtime: FailingRuntime()
        )

        let phases = PhaseLog()
        let ok = await installer.install { phase in phases.record(phase) }

        XCTAssertFalse(ok)
        let last = phases.all.last
        XCTAssertNotNil(last)
        XCTAssertTrue(last!.isFinished, "the last phase was \(last!), so the view would spin forever")
        if case .failed(let reason) = last! {
            XCTAssertFalse(reason.isEmpty, "a failure with nothing to read is a spinner that stopped")
        } else {
            XCTFail("an unreachable daemon and no installer should fail, not succeed")
        }
    }

    /// Startup readiness is not enough for an unattended appliance. If Ollama
    /// dies later, the next completion must restore the managed sidecar instead
    /// of turning a Signal message into silence.
    func testRuntimeRecoveryReentersTheInstallerWhenTheSidecarDisappears() async {
        let runtime = RecordingFailingRuntime()
        let installer = LocalBrainInstaller(
            client: OllamaClient(baseURL: URL(string: "http://127.0.0.1:1")!),
            runtime: runtime
        )

        do {
            try await installer.ensureRuntimeAvailable()
            XCTFail("an unreachable runtime whose reinstall fails cannot be ready")
        } catch {
            XCTAssertEqual(error as? OllamaRuntimeInstaller.Failure, .downloadHTTP(503))
        }

        let counts = await runtime.counts
        XCTAssertEqual(counts.install, 1)
        XCTAssertEqual(counts.start, 0)
    }

    private struct FailingRuntime: OllamaRuntimeInstalling {
        func install(onProgress: @Sendable (Int64, Int64?) -> Void) async throws {
            throw OllamaRuntimeInstaller.Failure.downloadHTTP(503)
        }

        func start() async throws {}
    }

    private actor RecordingFailingRuntime: OllamaRuntimeInstalling {
        private var installCount = 0
        private var startCount = 0

        func install(onProgress: @Sendable (Int64, Int64?) -> Void) async throws {
            installCount += 1
            throw OllamaRuntimeInstaller.Failure.downloadHTTP(503)
        }

        func start() async throws {
            startCount += 1
        }

        var counts: (install: Int, start: Int) {
            (installCount, startCount)
        }
    }

    /// A thread-safe recorder — `install` reports from its own actor context.
    private final class PhaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [LocalBrainInstaller.Phase] = []

        func record(_ phase: LocalBrainInstaller.Phase) {
            lock.lock(); defer { lock.unlock() }
            phases.append(phase)
        }

        var all: [LocalBrainInstaller.Phase] {
            lock.lock(); defer { lock.unlock() }
            return phases
        }
    }
}
