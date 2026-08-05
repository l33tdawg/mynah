import XCTest
@testable import MynahMac
@testable import SageVoiceCore

final class SignalBackgroundServicesTests: XCTestCase {
    func testPlistsCarryTheLinkedAccountAndNeverIgnoreAttachments() throws {
        let configuration = fixture()
        let home = URL(fileURLWithPath: "/Users/owner", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/Mynah", isDirectory: true)

        let signal = SignalBackgroundServiceManager.signalPlist(
            configuration,
            logs: logs,
            home: home
        )
        let signalArguments = try XCTUnwrap(signal["ProgramArguments"] as? [String])
        XCTAssertTrue(signalArguments.contains("+60123456789"))
        XCTAssertTrue(signalArguments.contains("--receive-mode=on-start"))
        XCTAssertFalse(signalArguments.contains("--ignore-attachments"))
        XCTAssertEqual(signal["KeepAlive"] as? Bool, true)

        let bridge = SignalBackgroundServiceManager.bridgePlist(
            configuration,
            logs: logs,
            home: home
        )
        let bridgeArguments = try XCTUnwrap(bridge["ProgramArguments"] as? [String])
        XCTAssertEqual(value(after: "--allow", in: bridgeArguments), "+60123456789")
        XCTAssertEqual(value(after: "--account", in: bridgeArguments), "+60123456789")
        XCTAssertEqual(value(after: "--provider", in: bridgeArguments), "ollama")
        XCTAssertEqual(value(after: "--model", in: bridgeArguments), "qwen3.5:4b")
        XCTAssertEqual(value(after: "--socket", in: bridgeArguments), configuration.socketPath)
    }

    func testValuesAreSerializedAsPlistStringsNotInterpolatedXML() throws {
        var configuration = fixture()
        configuration = SignalServiceConfiguration(
            account: "+60<&>\"",
            signalCLI: configuration.signalCLI,
            bridge: configuration.bridge,
            sage: configuration.sage,
            provider: configuration.provider,
            model: configuration.model,
            socketPath: configuration.socketPath
        )
        let object = SignalBackgroundServiceManager.bridgePlist(
            configuration,
            logs: URL(fileURLWithPath: "/tmp/logs"),
            home: URL(fileURLWithPath: "/tmp/home")
        )
        let data = try SignalBackgroundServiceManager.plistData(object)
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let arguments = try XCTUnwrap(decoded["ProgramArguments"] as? [String])
        XCTAssertEqual(value(after: "--allow", in: arguments), "+60<&>\"")
    }

    /// The daemon's own logs, which are the ones with his life in them.
    ///
    /// `bridge.log` carries his phone number twenty-six times and the text of
    /// what he sent; `signal.log` carries the number sixteen times. Both were
    /// `0644` on his Mac — readable by every account on it — because launchd
    /// creates them from `StandardOutPath` under the job's umask, so no write
    /// path this codebase owns ever touched them.
    ///
    /// The assertion is the mode on disk after `enable`, not the presence of a
    /// key in a plist. A plist key is a claim; `stat` is a measurement, and the
    /// difference is the whole reason this was missed.
    func testEnableMakesTheDaemonLogsOwnerOnly() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-logmode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        func executable(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        // Logs that already exist, world-readable, exactly as launchd left them.
        let logs = scratch.appendingPathComponent("Library/Logs/Mynah", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for name in ["bridge.log", "signal.log"] {
            let file = logs.appendingPathComponent(name)
            try Data("[daemon] syncSent from +60123456789\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }

        let configuration = SignalServiceConfiguration(
            account: "+60123456789",
            signalCLI: try executable("signal-cli"),
            bridge: try executable("sage-voiced"),
            sage: try executable("sage-gui"),
            provider: "ollama",
            model: "qwen3.5:4b",
            socketPath: scratch.appendingPathComponent("daemon.socket").path
        )
        let manager = SignalBackgroundServiceManager(
            runner: FakeLaunchd(),
            homeDirectory: scratch,
            userID: 501
        )

        try await manager.enable(configuration)

        for name in ["bridge.log", "signal.log"] {
            let perms = try FileManager.default.attributesOfItem(
                atPath: logs.appendingPathComponent(name).path
            )[.posixPermissions] as? NSNumber
            XCTAssertEqual(perms, 0o600, "\(name) is still readable by every account on the Mac")
        }
        let directory = try FileManager.default
            .attributesOfItem(atPath: logs.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directory, 0o700)
    }

    func testEnableWritesAndBootstrapsSignalBeforeTheBridge() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-services-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        func executable(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let configuration = SignalServiceConfiguration(
            account: "+60123456789",
            signalCLI: try executable("signal-cli"),
            bridge: try executable("sage-voiced"),
            sage: try executable("sage-gui"),
            provider: "ollama",
            model: "qwen3.5:4b",
            socketPath: scratch.appendingPathComponent("daemon.socket").path
        )
        let runner = FakeLaunchd()
        let manager = SignalBackgroundServiceManager(
            runner: runner,
            homeDirectory: scratch,
            userID: 501
        )

        try await manager.enable(configuration)

        let calls = await runner.calls
        let bootstraps = calls.filter { $0.arguments.first == "bootstrap" }
        XCTAssertEqual(bootstraps.count, 2)
        XCTAssertTrue(bootstraps[0].arguments.last?.contains(".signal.plist") == true)
        XCTAssertTrue(bootstraps[1].arguments.last?.hasSuffix("local.sage.voicebridge.plist") == true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent(
                    "Library/LaunchAgents/local.sage.voicebridge.signal.plist"
                ).path
            )
        )

        await manager.disable(because: "the test is checking the plists are removed")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent(
                    "Library/LaunchAgents/local.sage.voicebridge.signal.plist"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent(
                    "Library/LaunchAgents/local.sage.voicebridge.plist"
                ).path
            )
        )
    }

    @MainActor
    func testAppReconcilesPersistedChoicesAndPauseControlsTheJobs() async {
        let suite = "SignalBackgroundServicesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "mynah.setupComplete")
        defaults.set(true, forKey: "mynah.keepAnsweringWhenClosed")

        // Pause comes from the marker file, not from `UserDefaults` — the two
        // stores disagreeing is the bug that removed the defaults copy. This
        // used to set "mynah.paused" and pass, which was luck: with no marker
        // injected, `AppModel` reads the real one in the *developer's own*
        // Application Support, so the test enabled or disabled the jobs
        // depending on whether whoever ran it happened to have Mynah paused.
        // A temporary directory with no marker in it is an appliance that is
        // answering, on any machine.
        let pauseRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pauseRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pauseRoot) }

        let services = RecordingBackgroundServices()
        let configuration = fixture()
        let app = AppModel(
            defaults: defaults,
            backgroundServices: services,
            serviceConfiguration: { configuration },
            pauseState: PauseState(fileURL: pauseRoot.appendingPathComponent("paused"))
        )

        await app.reconcileAnsweringService()
        let enabled = await services.enabledConfigurations
        XCTAssertEqual(enabled, [configuration])

        app.isPaused = true
        await app.reconcileAnsweringService()
        let disables = await services.disableCount
        XCTAssertGreaterThanOrEqual(disables, 1)
    }

    private func fixture() -> SignalServiceConfiguration {
        SignalServiceConfiguration(
            account: "+60123456789",
            signalCLI: URL(fileURLWithPath: "/opt/homebrew/bin/signal-cli"),
            bridge: URL(fileURLWithPath: "/Applications/Mynah.app/Contents/MacOS/sage-voiced"),
            sage: URL(fileURLWithPath: "/Applications/Mynah.app/Contents/Resources/SAGE.app/Contents/MacOS/sage-gui"),
            provider: "ollama",
            model: "qwen3.5:4b",
            socketPath: "/Users/owner/.local/share/signal-cli/daemon.socket"
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private actor RecordingBackgroundServices: SignalBackgroundServicing {
    private(set) var enabledConfigurations: [SignalServiceConfiguration] = []
    private(set) var disableCount = 0

    /// What launchd would say if it were asked. Settable so a test can put the
    /// helper in the state that matters — the owner having switched it off in
    /// Login Items, which is the one nothing in the app could previously see.
    var reportedState: BackgroundHelperState = .absent

    func enable(_ configuration: SignalServiceConfiguration) async throws {
        enabledConfigurations.append(configuration)
        reportedState = .running
    }

    func disable(because reason: String) async {
        disableCount += 1
        reasons.append(reason)
        reportedState = .absent
    }

    /// Kept because the reason is the point of the parameter: a removal that
    /// cannot say why is the state this whole area was in on 29 July.
    private(set) var reasons: [String] = []

    func state() async -> BackgroundHelperState { reportedState }

    func setReportedState(_ state: BackgroundHelperState) { reportedState = state }
}
