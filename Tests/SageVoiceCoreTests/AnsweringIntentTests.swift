import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// Why the appliance stops, and the difference between meaning to and failing to.
///
/// On 29 July the owner's Signal went silent for half an hour. `signal.log`
/// showed twelve shutdown/restart pairs and then nothing; both LaunchAgent
/// plists had been *deleted* at 11:40. The window carried on working the whole
/// time, because the window does not go through the bridge — so the fault
/// looked, from the only side he could see, like Signal being broken.
///
/// Two defects produced it, and they compound:
///
/// 1. `reconcileAnsweringService` had one `guard` with four conditions and a
///    single else-branch. "The owner turned answering off" and "I could not read
///    the configuration" were the same outcome, and that outcome removes the
///    appliance rather than stopping it. So one unlucky file read uninstalled
///    the phone bridge for good.
/// 2. `enable` tore both jobs down and rebuilt them every single time, so the
///    unlucky read had a great many chances to happen.
///
/// The rule these tests hold in place: **uncertainty must never destroy.**
@MainActor
final class AnsweringIntentTests: XCTestCase {

    // MARK: The third answer

    /// The one that matters. A configuration the app cannot assemble is a
    /// question it failed to answer, not an instruction it received — so
    /// nothing is enabled and, crucially, nothing is disabled.
    func testAConfigurationItCannotReadChangesNothing() async {
        let services = RecordingServices()
        let app = makeApp(services: services, configuration: nil)

        guard case .cannotTell = app.answeringIntent() else {
            return XCTFail("an unreadable configuration is being treated as a decision")
        }

        await app.reconcileAnsweringService()

        let disables = await services.disableCount
        XCTAssertEqual(
            disables, 0,
            "failing to read the configuration deleted the owner's LaunchAgents"
        )
        let enables = await services.enabled
        XCTAssertTrue(enables.isEmpty, "it enabled something it could not describe")
    }

    /// The three ways the owner can mean it. Each is a decision, so each is
    /// carried out — a stop that quietly declined to stop would be the opposite
    /// bug and just as bad, because Pause is a promise.
    func testTheOwnersOwnDecisionsStillStopIt() async {
        for (name, prepare) in stops {
            let services = RecordingServices()
            let app = makeApp(services: services, configuration: .fixture)
            prepare(app)

            guard case .stop = app.answeringIntent() else {
                return XCTFail("\(name) no longer stops the appliance")
            }
            await app.reconcileAnsweringService()

            let disables = await services.disableCount
            XCTAssertGreaterThanOrEqual(disables, 1, "\(name) did not stop the appliance")
        }
    }

    private var stops: [(String, @MainActor (AppModel) -> Void)] {
        [
            ("pausing", { $0.isPaused = true }),
            ("turning off answering from the phone", { $0.keepsAnsweringWhenClosed = false })
        ]
    }

    /// **This test was called `testUnfinishedSetupIsADecisionAndNotADoubt`, and
    /// the name was the belief that cost the owner his phone.**
    ///
    /// The reasoning was that a re-run may invalidate the configuration, so
    /// unfinished setup should stop the appliance. Defensible in the abstract,
    /// and wrong about the moment: he opened "Change where your words go" to
    /// take a screenshot of the provider list, and **every screenshot deleted
    /// both LaunchAgents.** Looking at your options took your phone away.
    ///
    /// He has not chosen anything. The configuration that was answering a
    /// second ago is still on disk and still valid. So this is the third case —
    /// *I cannot currently tell what the configuration should be* — and
    /// `cannotTell` changes nothing.
    ///
    /// Third time today a test name has encoded a wrong belief and then
    /// defended it. The others were "does not claim to read widely" and "says
    /// it cannot read grants".
    func testUnfinishedSetupIsADoubtAndNotADecision() {
        let app = makeApp(services: RecordingServices(), configuration: .fixture, setupComplete: false)

        guard case .cannotTell = app.answeringIntent() else {
            return XCTFail("opening setup is being treated as a decision to stop answering")
        }
    }

    /// The owner's bug, pinned directly.
    ///
    /// Entering setup must leave a working appliance alone — not stop it, not
    /// restart it, not touch it at all.
    func testOpeningSetupDoesNotTakeThePhoneAway() async {
        let services = RecordingServices()
        let defaults = makeDefaults()
        BrainSelectionStore.save(.fixtureBrain, defaults: defaults)
        let app = makeApp(services: services, configuration: .fixture, defaults: defaults)

        app.restartSetup()
        await app.reconcileAnsweringService()

        let removed = await services.disableCount
        XCTAssertEqual(removed, 0, "opening the brain picker deleted the owner's LaunchAgents")
    }

    /// Whatever removes the appliance has to say why, in the line that records
    /// the removal. Four possibilities had to be eliminated by hand on 29 July
    /// because nothing did.
    func testTheRemovalCarriesItsReason() async {
        let services = RecordingServices()
        let app = makeApp(services: services, configuration: .fixture)
        app.isPaused = true

        await app.reconcileAnsweringService()

        // Not a count: setting `isPaused` reconciles through its own `didSet`
        // as well, so more than one removal is expected and correct here.
        let reasons = await services.reasons
        XCTAssertFalse(reasons.isEmpty, "the appliance was not removed at all")
        XCTAssertTrue(
            reasons.allSatisfy { $0.contains("paused") },
            "the appliance was removed without recording why: \(reasons)"
        )
    }

    // MARK: Reading reality back

    /// The gap nothing else covers.
    ///
    /// Reconciliation used to happen only on launch and on change, so an
    /// appliance that went away for a reason the app did not cause — the owner
    /// switching it off in Login Items, a test run deleting the plists — stayed
    /// away. The window went on saying it was answering his phone, and only
    /// quitting and relaunching fixed it.
    ///
    /// Nothing here has changed: same marker, same settings, same
    /// configuration. Coming forward still has to ask.
    func testComingForwardAsksTheMachineEvenWhenNothingChanged() async {
        let services = RecordingServices()
        let app = makeApp(services: services, configuration: .fixture)

        await app.catchUpWithTheMachine()

        let enabled = await services.enabled
        XCTAssertEqual(
            enabled.count, 1,
            "coming back to the window did not check whether the appliance still exists"
        )
    }

    /// And it must still adopt a marker another process changed, which is the
    /// job activation already had.
    func testComingForwardStillAdoptsAPauseFromAnotherProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = PauseState(fileURL: root.appendingPathComponent("paused"))
        let defaults = makeDefaults()
        defaults.set(true, forKey: "mynah.setupComplete")
        let services = RecordingServices()
        let app = AppModel(
            defaults: defaults,
            backgroundServices: services,
            serviceConfiguration: { .fixture },
            pauseState: marker
        )
        XCTAssertFalse(app.isPaused)

        // Something outside this app paused it — the daemon, a second window,
        // the owner deleting the file by hand.
        try marker.setPaused(true)
        await app.catchUpWithTheMachine()

        XCTAssertTrue(app.isPaused, "the window kept saying it was answering")
        let disables = await services.disableCount
        XCTAssertGreaterThanOrEqual(disables, 1, "it adopted the pause but left the jobs running")
    }

    // MARK: Coming back

    /// Backing out of "Change where your words go" has to put the appliance
    /// back. While a restart is in progress `hasCompletedSetup` is false, which
    /// is a stop — so any reconcile in that window removes both LaunchAgents.
    /// Restoring the flag without reconciling left the owner with a window that
    /// says it is answering and a phone that is not, recoverable only by
    /// quitting and relaunching.
    func testBackingOutOfARestartPutsTheApplianceBack() async {
        let services = RecordingServices()
        let defaults = makeDefaults()
        BrainSelectionStore.save(.fixtureBrain, defaults: defaults)
        let app = makeApp(services: services, configuration: .fixture, defaults: defaults)

        // **The precondition this used to rely on is gone, deliberately.**
        //
        // It asserted that restarting setup removed the appliance first, then
        // that cancelling brought it back. Entering setup no longer removes
        // anything — see `testOpeningSetupDoesNotTakeThePhoneAway` — so the
        // interesting property is now the weaker, still-necessary one: backing
        // out reconciles, so an appliance that *was* stopped for some other
        // reason during the flow is restored rather than left down.
        app.restartSetup()
        await app.reconcileAnsweringService()

        XCTAssertTrue(app.canCancelSetupRestart, "there is nothing to back out to")
        app.cancelSetupRestart()

        let cameBack = await poll { await services.enabled.isEmpty == false }
        XCTAssertTrue(cameBack, "cancelling a restart did not reconcile the appliance")
    }

    // MARK: Helpers

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "mynah.answering.\(UUID().uuidString)")!
    }

    private func makeApp(
        services: RecordingServices,
        configuration: SignalServiceConfiguration?,
        defaults: UserDefaults? = nil,
        setupComplete: Bool = true
    ) -> AppModel {
        let defaults = defaults ?? makeDefaults()
        defaults.set(setupComplete, forKey: "mynah.setupComplete")
        // A temporary marker path, never the developer's own: `AppModel`
        // otherwise reads `~/Library/Application Support/SAGE Voice Bridge/
        // paused`, and the test would pass or fail depending on whether
        // whoever ran it happened to have Mynah paused.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("answering-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppModel(
            defaults: defaults,
            backgroundServices: services,
            serviceConfiguration: { configuration },
            pauseState: PauseState(fileURL: root.appendingPathComponent("paused"))
        )
    }

    /// `cancelSetupRestart` reconciles in a detached task, so there is nothing
    /// to await. Polling with a ceiling rather than sleeping a fixed time: it
    /// finishes as soon as the work does, and still fails rather than hanging.
    private func poll(
        until condition: @Sendable () async -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

/// Reconciling something that is already right.
///
/// Every caller of `reconcileAnsweringService` — launch, the phone-link sheet,
/// the model picker, the reply-style switch — used to reach `bootout`, which
/// SIGTERMs signal-cli and drops the socket the daemon holds. Each one costs the
/// owner a gap of a few seconds during which a message from his phone is simply
/// never seen, and he spends his testing afternoon inside those gaps.
final class ApplianceIdempotenceTests: XCTestCase {

    func testReconcilingAnUnchangedApplianceDoesNotRestartSignal() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let configuration = try configuration(in: scratch)
        let runner = LoadedLaunchctl()
        let manager = SignalBackgroundServiceManager(
            runner: runner, homeDirectory: scratch, userID: 501
        )

        try await manager.enable(configuration)
        let firstPass = await runner.counts
        XCTAssertEqual(firstPass.bootstraps, 2, "the first install did not start both jobs")

        try await manager.enable(configuration)

        let secondPass = await runner.counts
        XCTAssertEqual(
            secondPass.bootouts, firstPass.bootouts,
            "reconciling an unchanged appliance stopped signal-cli, which loses "
                + "every message sent while it restarts"
        )
        XCTAssertEqual(secondPass.bootstraps, firstPass.bootstraps)
    }

    /// The other half, and the reason the check above cannot simply be "have I
    /// run before". Changing the model has to reach the daemon, which reads it
    /// once at start-up — so a changed configuration must still restart.
    func testAChangedConfigurationStillRestarts() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let original = try configuration(in: scratch)
        let runner = LoadedLaunchctl()
        let manager = SignalBackgroundServiceManager(
            runner: runner, homeDirectory: scratch, userID: 501
        )

        try await manager.enable(original)
        let before = await runner.counts

        try await manager.enable(
            SignalServiceConfiguration(
                account: original.account,
                signalCLI: original.signalCLI,
                bridge: original.bridge,
                sage: original.sage,
                provider: original.provider,
                model: "a-different-model",
                socketPath: original.socketPath
            )
        )

        let after = await runner.counts
        XCTAssertGreaterThan(
            after.bootstraps, before.bootstraps,
            "the appliance kept running the model the owner replaced"
        )
    }

    /// The skip compares the bytes it would write against the bytes on disk, so
    /// serialisation has to be stable for identical input. If this ever fails,
    /// the skip silently stops working and the churn comes back — quietly,
    /// which is the worst way for it to come back.
    func testTheSamePlistSerialisesToTheSameBytes() throws {
        let home = URL(fileURLWithPath: "/Users/owner", isDirectory: true)
        let object = SignalBackgroundServiceManager.bridgePlist(
            .fixture, logs: home.appendingPathComponent("Library/Logs/Mynah"), home: home
        )
        XCTAssertEqual(
            try SignalBackgroundServiceManager.plistData(object),
            try SignalBackgroundServiceManager.plistData(object)
        )
    }

    /// The one that would have saved the afternoon.
    ///
    /// `AppModel` defaults its `backgroundServices` to the shared manager, so a
    /// test that builds one to check something else entirely — pause, the home
    /// split — is holding the real thing, aimed at the real machine. Setting
    /// `isPaused` reconciles, and a reconcile can decide to remove both
    /// LaunchAgents. `swift test` therefore uninstalled the developer's own
    /// phone bridge, twice, and it read as a product fault because the window
    /// carried on working.
    ///
    /// Pointed at the real home with executables that do not exist: without the
    /// guard this throws `missingExecutable` long before touching launchd, so
    /// the assertion is safe to run — it can fail, but it cannot break the
    /// machine it fails on.
    func testATestRunCannotReachTheRealLaunchd() async throws {
        let manager = SignalBackgroundServiceManager(
            runner: LoadedLaunchctl(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        try await manager.enable(.fixture)
    }

    /// `disable` is the destructive half and cannot be exercised the same way —
    /// proving it does not delete the real plists would mean risking the real
    /// plists. Asserted structurally instead, which is weaker but is the only
    /// check that does not cost what it is protecting.
    func testTheRemovalPathCarriesTheSameGuard() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/SignalBackgroundServices.swift"),
            encoding: .utf8
        )
        let removal = try XCTUnwrap(
            source.range(of: "func disable(because reason: String) async {"),
            "the removal method was renamed; this check is now watching nothing"
        )
        let body = source[removal.upperBound...].prefix(400)
        XCTAssertTrue(
            body.contains("isTestReachingTheRealMachine"),
            "disable() can delete the developer's own LaunchAgents from a test run again"
        )
    }

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-idempotence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func configuration(in scratch: URL) throws -> SignalServiceConfiguration {
        func executable(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
            return url
        }
        return SignalServiceConfiguration(
            account: "+60123456789",
            signalCLI: try executable("signal-cli"),
            bridge: try executable("sage-voiced"),
            sage: try executable("sage-gui"),
            provider: "ollama",
            model: "qwen3.5:4b",
            socketPath: scratch.appendingPathComponent("daemon.socket").path
        )
    }
}

// MARK: - Doubles

private actor RecordingServices: SignalBackgroundServicing {
    private(set) var enabled: [SignalServiceConfiguration] = []
    private(set) var disableCount = 0

    func enable(_ configuration: SignalServiceConfiguration) async throws {
        enabled.append(configuration)
    }

    func disable(because reason: String) async {
        disableCount += 1
        reasons.append(reason)
    }

    private(set) var reasons: [String] = []

    func state() async -> BackgroundHelperState {
        enabled.isEmpty ? .absent : .running
    }
}

/// A launchctl that reports both jobs loaded, which is the state the skip has to
/// recognise. `bootout` answers non-zero the way the real one does when there
/// was nothing to stop.
private actor LoadedLaunchctl: ProbeCommandRunning {
    struct Counts: Sendable {
        var bootouts = 0
        var bootstraps = 0
    }

    private(set) var counts = Counts()

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async -> ProbeCommandResult? {
        switch arguments.first {
        case "bootout":
            counts.bootouts += 1
            return ProbeCommandResult(exitCode: 3, standardOutput: "", standardError: "")
        case "bootstrap":
            counts.bootstraps += 1
            return ProbeCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        default:
            return ProbeCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
    }
}

private extension SignalServiceConfiguration {
    static let fixture = SignalServiceConfiguration(
        account: "+60123456789",
        signalCLI: URL(fileURLWithPath: "/opt/homebrew/bin/signal-cli"),
        bridge: URL(fileURLWithPath: "/Applications/Mynah.app/Contents/MacOS/sage-voiced"),
        sage: URL(fileURLWithPath: "/Applications/SAGE.app/Contents/MacOS/sage-gui"),
        provider: "ollama",
        model: "qwen3.5:4b",
        socketPath: "/Users/owner/.local/share/signal-cli/daemon.socket"
    )
}

private extension BrainSetupOption {
    static let fixtureBrain = BrainSetupOption(
        id: .anthropicAPIKey,
        label: "Anthropic API key",
        summary: "Test",
        requirement: .apiKey,
        keepsWordsOnDevice: false,
        availability: .available,
        tier: .typedAPIKey,
        backendIdentifier: "anthropic",
        modelName: "claude-sonnet-4-5"
    )
}
