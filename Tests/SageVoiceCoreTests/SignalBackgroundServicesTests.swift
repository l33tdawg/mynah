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
        let runner = RecordingLaunchctlRunner()
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

        await manager.disable()

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
        defaults.set(false, forKey: "mynah.paused")

        let services = RecordingBackgroundServices()
        let configuration = fixture()
        let app = AppModel(
            defaults: defaults,
            backgroundServices: services,
            serviceConfiguration: { configuration }
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

    func enable(_ configuration: SignalServiceConfiguration) async throws {
        enabledConfigurations.append(configuration)
    }

    func disable() async {
        disableCount += 1
    }
}

private actor RecordingLaunchctlRunner: ProbeCommandRunning {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var calls: [Call] = []

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async -> ProbeCommandResult? {
        calls.append(Call(executable: executable, arguments: arguments))
        let isBootout = arguments.first == "bootout"
        return ProbeCommandResult(
            exitCode: isBootout ? 3 : 0,
            standardOutput: "",
            standardError: ""
        )
    }
}
