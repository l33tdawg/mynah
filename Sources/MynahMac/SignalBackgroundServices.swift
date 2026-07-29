import Foundation
import OSLog
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

/// Whether macOS is actually running the background helper.
///
/// Three states rather than a `Bool`, and the third is the point: **the owner
/// can turn this off outside the app.** Writing a LaunchAgent produces a system
/// notification — "Mynah added items that can run in the background" — and an
/// entry in System Settings → General → Login Items, which they can switch off.
/// When they do, the appliance stops answering their phone and nothing in Mynah
/// says why. A screen that reported only what Mynah last *asked for* would keep
/// showing "On" over a helper macOS had stopped.
enum BackgroundHelperState: Equatable, Sendable {
    /// launchd has it and is running it.
    case running
    /// Mynah installed it and launchd is not running it — which on this OS most
    /// often means the owner switched it off in Login Items.
    case installedButNotRunning
    /// Nothing installed. The ordinary state when answering is turned off.
    case absent
    /// launchd could not be asked. Not the same as "off" — an appliance that
    /// cannot see its own helper must not claim the helper is gone.
    case unknown
}

protocol SignalBackgroundServicing: Sendable {
    func enable(_ configuration: SignalServiceConfiguration) async throws
    /// - Parameter reason: why the owner's phone is about to stop being
    ///   answered, in words that would mean something in a log six hours later.
    ///   Required rather than optional: this is the one call in the app that can
    ///   take the appliance away, and a caller that cannot say why should not be
    ///   making it.
    func disable(because reason: String) async
    /// Asked rather than remembered. See `BackgroundHelperState`.
    func state() async -> BackgroundHelperState
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

    /// Whether this manager is about to rearrange the launchd of the machine it
    /// is being tested on.
    ///
    /// **This is what took the owner's Signal down twice on 29 July**, and it is
    /// worth writing out because nothing about it is visible from either side.
    ///
    /// `AppModel.init` defaults `backgroundServices` to `shared`, so every test
    /// that builds an `AppModel` without injecting one gets the real manager
    /// pointed at the real home directory. Several do — they are testing pause,
    /// or the home split, and have no reason to think about launchd at all. But
    /// setting `isPaused` fires a `didSet` that reconciles, and a reconcile that
    /// decides the appliance should be off calls `disable()`, which deletes both
    /// LaunchAgent plists out of `~/Library/LaunchAgents`.
    ///
    /// So `swift test` uninstalled the developer's own phone bridge. The
    /// directory mtime pinned it exactly: 11:40 and again at 11:56, both the
    /// minute a test run finished. From the owner's side Signal simply stopped
    /// answering while the window kept working, because the window does not go
    /// through the bridge — which is why this looked like a product regression
    /// for an hour and was never anywhere near the product.
    ///
    /// The condition is deliberately narrow: a test that injects a scratch home
    /// is exercising this type on purpose and must keep working. A test that
    /// reaches the *real* home has not decided to do anything to this machine,
    /// and this is the only place that can tell the difference.
    private var isTestReachingTheRealMachine: Bool {
        guard NSClassFromString("XCTestCase") != nil else { return false }
        return homeDirectory == FileManager.default.homeDirectoryForCurrentUser
    }

    func enable(_ configuration: SignalServiceConfiguration) async throws {
        guard !isTestReachingTheRealMachine else {
            Self.log.error("a test reached the real launchd; refusing to install anything")
            return
        }
        for executable in [configuration.signalCLI, configuration.bridge, configuration.sage] {
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                throw Failure.missingExecutable(executable.path)
            }
        }

        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = homeDirectory.appendingPathComponent("Library/Logs/Mynah", isDirectory: true)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        protectLogs(in: logs)

        let signalURL = launchAgents.appendingPathComponent("\(Self.signalLabel).plist")
        let bridgeURL = launchAgents.appendingPathComponent("\(Self.bridgeLabel).plist")
        let signalData = try Self.plistData(
            Self.signalPlist(configuration, logs: logs, home: homeDirectory)
        )
        let bridgeData = try Self.plistData(
            Self.bridgePlist(configuration, logs: logs, home: homeDirectory)
        )

        // Nothing to do is a real answer, and it used to be the one answer this
        // could not give.
        //
        // Every caller — launch, the phone-link sheet, the model picker, the
        // reply-style switch — went straight to bootout, which SIGTERMs
        // signal-cli and drops the socket the daemon is holding. `signal.log`
        // on 29 July has twelve shutdown/restart pairs in an afternoon, and any
        // message the owner sent inside one of those gaps was never seen. The
        // gap is seconds long, and a man testing his appliance spends a lot of
        // his afternoon inside seconds-long gaps.
        //
        // If the plists on disk are byte-identical to the ones we would write
        // and launchd is already running both jobs, then the world is already
        // what this method exists to produce. A wrong answer here is not
        // dangerous in either direction: a false "no" is exactly today's
        // behaviour, and a false "yes" needs launchd to have reported a job
        // loaded that is not.
        if await isAlreadyReconciled(
            signal: signalData, at: signalURL,
            bridge: bridgeData, at: bridgeURL
        ) {
            return
        }

        try signalData.write(to: signalURL, options: .atomic)
        try bridgeData.write(to: bridgeURL, options: .atomic)

        Self.log.notice("restarting the phone bridge to apply a changed configuration")

        // bootout returns non-zero on a first install; that only means there
        // was nothing stale to stop.
        _ = await bootout(Self.bridgeLabel)
        let stoppedManagedSignal = await bootout(Self.signalLabel)
        if stoppedManagedSignal {
            try? fileManager.removeItem(atPath: configuration.socketPath)
        }
        try await bootstrap(signalURL, label: Self.signalLabel)
        try await bootstrap(bridgeURL, label: Self.bridgeLabel)
    }

    /// Makes the daemon's logs owner-only, every time this runs.
    ///
    /// **These are the files with his life in them.** `bridge.log` carried his
    /// phone number twenty-six times and the text of what he sent — "replied in
    /// 30.4s to what agents can you see ?" — and `signal.log` carries the number
    /// sixteen times. Both were `0644`, in a product whose argument is a page
    /// called "What leaves this Mac".
    ///
    /// **`MynahLog`'s fix could not reach them, and it is worth knowing why.**
    /// Nothing in this codebase writes these files. launchd does, from
    /// `StandardOutPath` and `StandardErrorPath`, creating them under the job's
    /// umask — so every write path we own could be perfect and these two would
    /// still arrive world-readable. A plist key is a claim; `stat` is a
    /// measurement, and a test asserting we asked for the right thing would have
    /// passed throughout.
    ///
    /// ## The reason, which is not local accounts
    ///
    /// The mode protects a file sitting still. What actually matters is that
    /// **Settings tells him to send these logs for diagnostics** — `chrome`'s
    /// point, and a better argument than the one this started with. A file we
    /// ask him to attach to a message is not protected by any bit on his disk;
    /// what protects him there is the redaction at the daemon's log seam, and
    /// this mode is what keeps the copy at rest closed while it waits.
    ///
    /// ## Why a chmod here, and why `Umask` in the plist is not the better fix
    ///
    /// The first version of this comment called `Umask: 0o077` "the better fix,
    /// deferred because it costs a reload", and told the next person to add it.
    /// That was wrong on the substance, not just the timing: **`Umask` governs
    /// the files launchd itself creates.** `bridge.log` and `signal.log` already
    /// exist on this Mac, so the key would apply to nothing here — it would have
    /// carried the full cost of a reconcile (both jobs booted, the socket
    /// dropped, the path that took his phone away twice today) to change no byte
    /// of any file he has. It is worth having for a *fresh install*, where
    /// launchd does create them, and only there.
    ///
    /// So: a chmod, before the byte comparison, on every `enable`, repairing
    /// whatever is on disk — the only thing that helps an existing install. If
    /// somebody later edits these plists for a reason of their own, adding
    /// `"Umask": 0o077` in the same edit is free. It is not worth an edit of its
    /// own, and nobody should trigger a reload to land it.
    ///
    /// ## The honest limit
    ///
    /// This runs on `enable`, not on every write, because we never do the
    /// writing. launchd *appends* to an existing file, so a mode set once
    /// survives — but a file deleted between installs comes back at the umask
    /// and stays that way until the next reconcile. On his machine that is fine.
    /// It is not a guarantee, and it should not be described as one.
    ///
    /// ## The directory was the part that was actually open
    ///
    /// Worth recording, because it was nearly written off. The directory was
    /// found at `drwx------` and the `0644` files read as never reachable —
    /// "worth checking, not worth changing". That was a state this method had
    /// already created: `prepareDirectory` had run hours earlier.
    ///
    /// Before that it came from `createDirectory` above, with no attributes.
    /// Verified rather than assumed, by predicting first: if that call yields
    /// `0755` on this Mac, then `~/Library/LaunchAgents`, made by the sibling
    /// line and never touched by us, is `0755` too. It is — `drwxr-xr-x`, umask
    /// `022`, and a control directory created the same way right now comes out
    /// `0755`. So the files were world-readable for as long as they existed, and
    /// this method closed it rather than doubling something already closed. It
    /// has to keep running: a fresh install starts at `0755` again.
    ///
    /// `appliance.log` is in the list because it is the same class of file, not
    /// because anybody reported it — it was written this afternoon and would
    /// have been missed by a fix aimed only at the two files that were named.
    ///
    /// Best-effort throughout: a log we cannot chmod is not a reason to refuse
    /// to install his appliance.
    private func protectLogs(in logs: URL) {
        try? OwnerOnlyFileSecurity.prepareDirectory(logs, fileManager: fileManager)
        for name in ["bridge.log", "signal.log", "appliance.log"] {
            try? OwnerOnlyFileSecurity.protectFile(
                logs.appendingPathComponent(name),
                fileManager: fileManager
            )
        }
    }

    /// Whether launchd is already running exactly what `enable` would install.
    ///
    /// Both halves are needed. The plists alone say what Mynah last *wrote*,
    /// which is the same mistake `state()` exists to avoid; launchd alone would
    /// keep a job running under a stale configuration after the owner changed
    /// their model.
    private func isAlreadyReconciled(
        signal: Data, at signalURL: URL,
        bridge: Data, at bridgeURL: URL
    ) async -> Bool {
        guard (try? Data(contentsOf: signalURL)) == signal,
              (try? Data(contentsOf: bridgeURL)) == bridge else {
            return false
        }
        // `true` specifically, not "not false". `isLoaded` returns nil when
        // launchctl could not be asked at all, and an unanswered question is
        // not a yes — here the safe reading is to go on and install, because
        // the owner has asked for this to be running and bootstrapping
        // something already bootstrapped is recoverable. That is the opposite
        // reading to `disable`, and deliberately: uncertainty may rebuild, but
        // uncertainty must never destroy.
        // Sequential rather than `&&`: the short-circuit operators take an
        // autoclosure, which cannot be `await`ed.
        guard await isLoaded(Self.signalLabel) == true else { return false }
        return await isLoaded(Self.bridgeLabel) == true
    }

    func disable(because reason: String) async {
        guard !isTestReachingTheRealMachine else {
            Self.log.error("a test reached the real launchd; refusing to remove anything")
            return
        }
        // The one action in this file that takes the owner's phone away, and
        // until 29 July it happened without a word anywhere.
        //
        // `MynahLog` does both halves — `os_log` for anyone streaming, the file
        // for anyone arriving afterwards with a question. This file used to
        // carry its own `record(_:)`, written this afternoon when `os_log`
        // turned out to be unreadable here; `thread`'s type superseded it and
        // it is gone rather than left beside its replacement.
        //
        // The claim that used to sit here — that `.error` survives in the
        // unified log where `.info` and `.debug` do not — is true of Apple's
        // defaults and false on his Mac, where nothing is retrievable after the
        // fact at any level. The level is still right; the reasoning was not.
        Self.log.error("removing both LaunchAgents, so the phone will stop being answered: \(reason)")
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

    /// Asks launchd about the bridge, which is the job that answers the phone.
    ///
    /// `launchctl print` rather than reading the plist back: a plist on disk
    /// records what Mynah wrote, not what macOS is doing with it, and the whole
    /// reason this exists is that those two can differ without the app being
    /// involved. The bridge is the one asked about because the signal helper
    /// exists to serve it — a running signal-cli with no bridge answers nothing.
    func state() async -> BackgroundHelperState {
        let plist = homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.bridgeLabel).plist")
        let installed = fileManager.fileExists(atPath: plist.path)

        guard let loaded = await isLoaded(Self.bridgeLabel) else {
            // launchctl did not answer at all. Reporting "off" here would be a
            // guess, and the guess that costs the owner most.
            return installed ? .unknown : .absent
        }
        if loaded { return .running }
        return installed ? .installedButNotRunning : .absent
    }
    /// Whether launchd has this job, or `nil` when launchctl could not be asked.
    ///
    /// The optional is the point, and it is the same distinction
    /// `BackgroundHelperState.unknown` draws: a question that went unanswered
    /// is not a no, and every caller here has to decide for itself which way to
    /// read that.
    private func isLoaded(_ label: String) async -> Bool? {
        let result = await runner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "\(domain)/\(label)"],
            timeout: 10
        )
        guard let result else { return nil }
        return result.succeeded
    }

    /// **These four lines are the record of the two worst things that can
    /// happen to his appliance, and they were write-only.**
    ///
    /// Two of them are the guard that stops `swift test` uninstalling his phone
    /// bridge — the thing that actually happened on 29 July. One narrates the
    /// reconcile that deletes the signal socket, which is the cause of all 24
    /// reconnects in `bridge.log`. The fourth says the LaunchAgents are being
    /// removed and why.
    ///
    /// Every one is an error or a notice, deliberately, because they exist to
    /// be read after something went wrong. On this Mac `os_log` cannot be read
    /// after the fact at any level — measured — so they were the appliance's
    /// black box with the recorder disconnected.
    private static let log = MynahLog(category: "appliance")


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
