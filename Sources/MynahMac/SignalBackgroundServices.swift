import Foundation
import SageVoiceCore

/// Everything launchd needs after Signal has confirmed the QR scan.
///
/// Kept as values rather than rediscovered while writing each plist so setup,
/// Settings and relaunch all reconcile the exact same appliance.
struct SignalServiceConfiguration: Sendable, Equatable {
    let account: String
    let signalCLI: URL
    let bridge: URL
    let sage: URL
    let provider: String
    let model: String?
    let socketPath: String

    static func current(
        appBundle: URL = Bundle.main.bundleURL,
        defaults: UserDefaults = .standard
    ) -> SignalServiceConfiguration? {
        guard let account = SignalTooling.linkedNumber(),
              let signalCLI = SignalTooling.helper(),
              let brain = BrainSelectionStore.current(defaults) else {
            return nil
        }
        let contents = appBundle.appendingPathComponent("Contents", isDirectory: true)

        // The owner's node when they have one, ours only when they do not.
        //
        // This pointed at the vendored copy unconditionally, which on a Mac that
        // already runs SAGE meant starting a second one beside it. Two nodes do
        // not share memories, so the appliance would appear to forget everything
        // it had been told through the other — and the owner would have two
        // brains where they asked for one agent.
        let vendored = contents.appendingPathComponent("Resources/SAGE.app/Contents/MacOS/sage-gui")
        let node = SageNodeChoice.resolve(vendored: vendored)

        return SignalServiceConfiguration(
            account: account,
            signalCLI: signalCLI,
            bridge: contents.appendingPathComponent("MacOS/sage-voiced"),
            sage: node?.executable ?? vendored,
            provider: brain.backendIdentifier,
            model: brain.modelName,
            socketPath: SignalTooling.socketPath
        )
    }
}

protocol SignalBackgroundServicing: Sendable {
    func enable(_ configuration: SignalServiceConfiguration) async throws
    func disable() async
}

/// Installs the two per-user services that make the phone bridge an appliance.
///
/// No privilege prompt is involved. LaunchAgents run as the signed-in owner,
/// which is also the only account that can read Signal's linked-device keys,
/// provider credentials and SAGE identity.
actor SignalBackgroundServiceManager: SignalBackgroundServicing {
    static let shared = SignalBackgroundServiceManager()

    static let signalLabel = "local.sage.voicebridge.signal"
    static let bridgeLabel = "local.sage.voicebridge"

    private let runner: ProbeCommandRunning
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let userID: UInt32

    init(
        runner: ProbeCommandRunning = ProbeCommandRunner(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: UInt32 = getuid()
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.userID = userID
    }

    func enable(_ configuration: SignalServiceConfiguration) async throws {
        for executable in [configuration.signalCLI, configuration.bridge, configuration.sage] {
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                throw Failure.missingExecutable(executable.path)
            }
        }

        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = homeDirectory.appendingPathComponent("Library/Logs/Mynah", isDirectory: true)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)

        let signalURL = launchAgents.appendingPathComponent("\(Self.signalLabel).plist")
        let bridgeURL = launchAgents.appendingPathComponent("\(Self.bridgeLabel).plist")
        try Self.plistData(Self.signalPlist(configuration, logs: logs, home: homeDirectory))
            .write(to: signalURL, options: .atomic)
        try Self.plistData(Self.bridgePlist(configuration, logs: logs, home: homeDirectory))
            .write(to: bridgeURL, options: .atomic)

        // Reconciliation is deliberately idempotent. bootout returns non-zero
        // on a first install; that only means there was nothing stale to stop.
        _ = await bootout(Self.bridgeLabel)
        let stoppedManagedSignal = await bootout(Self.signalLabel)
        if stoppedManagedSignal {
            try? fileManager.removeItem(atPath: configuration.socketPath)
        }
        try await bootstrap(signalURL, label: Self.signalLabel)
        try await bootstrap(bridgeURL, label: Self.bridgeLabel)
    }

    func disable() async {
        _ = await bootout(Self.bridgeLabel)
        _ = await bootout(Self.signalLabel)

        // A booted-out LaunchAgent whose plist is left behind can be loaded
        // again at the next login. Removing only Mynah's two managed plists
        // makes Pause and the Settings switch survive a restart; enable()
        // recreates them from the persisted choices when the owner turns
        // answering back on.
        let launchAgents = homeDirectory.appendingPathComponent(
            "Library/LaunchAgents",
            isDirectory: true
        )
        for label in [Self.bridgeLabel, Self.signalLabel] {
            try? fileManager.removeItem(
                at: launchAgents.appendingPathComponent("\(label).plist")
            )
        }
    }

    private func bootout(_ label: String) async -> Bool {
        let result = await runner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootout", "\(domain)/\(label)"],
            timeout: 15
        )
        return result?.succeeded == true
    }

    private func bootstrap(_ plist: URL, label: String) async throws {
        guard let result = await runner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootstrap", domain, plist.path],
            timeout: 30
        ), result.succeeded else {
            throw Failure.launchFailed(label)
        }
    }

    private var domain: String { "gui/\(userID)" }

    static func signalPlist(
        _ configuration: SignalServiceConfiguration,
        logs: URL,
        home: URL
    ) -> [String: Any] {
        [
            "Label": signalLabel,
            "ProgramArguments": [
                configuration.signalCLI.path,
                "-a", configuration.account,
                "daemon",
                "--socket=\(configuration.socketPath)",
                "--receive-mode=on-start",
                "--no-receive-stdout",
                "--ignore-stories",
                "--ignore-stickers"
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            "WorkingDirectory": home.path,
            "StandardOutPath": logs.appendingPathComponent("signal.log").path,
            "StandardErrorPath": logs.appendingPathComponent("signal.log").path,
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            ]
        ]
    }

    static func bridgePlist(
        _ configuration: SignalServiceConfiguration,
        logs: URL,
        home: URL
    ) -> [String: Any] {
        var arguments = [
            configuration.bridge.path,
            "daemon",
            "--allow", configuration.account,
            "--account", configuration.account,
            "--provider", configuration.provider,
            "--socket", configuration.socketPath,
            "--sage", configuration.sage.path
        ]
        if let model = configuration.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        return [
            "Label": bridgeLabel,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            "WorkingDirectory": home.path,
            "StandardOutPath": logs.appendingPathComponent("bridge.log").path,
            "StandardErrorPath": logs.appendingPathComponent("bridge.log").path,
            "ProcessType": "Interactive",
            "LowPriorityIO": false
        ]
    }

    static func plistData(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
    }

    enum Failure: LocalizedError {
        case missingExecutable(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingExecutable(let path):
                return "A required background helper is missing at \(path)."
            case .launchFailed(let label):
                return "macOS could not start \(label)."
            }
        }
    }
}
