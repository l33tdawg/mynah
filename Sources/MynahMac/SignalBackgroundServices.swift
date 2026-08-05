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

    /// The two executables a reconcile is trying to get launchd to run.
    ///
    /// A pair rather than one value because they fail independently: on 5 August
    /// the bridge was replaced by a crash and picked up the new binary, while
    /// signal-cli kept running the old bundle for hours. Either one being stale
    /// means the update has not finished.
    struct InstalledBuild: Hashable, Sendable {
        let signal: String
        let bridge: String
    }

    /// Builds this process has already failed to start. See `enable`.
    private var failedToApply: Set<InstalledBuild> = []

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
        let installed = InstalledBuild(
            signal: Self.executableStamp(configuration.signalCLI),
            bridge: Self.executableStamp(configuration.bridge)
        )

        if await isAlreadyReconciled(
            signal: signalData, at: signalURL,
            bridge: bridgeData, at: bridgeURL,
            running: installed
        ) {
            return
        }

        // **A build that has already refused to start is not retried by every
        // caller.** Without this the repair below would reintroduce the churn
        // the reconcile check exists to prevent: a launchctl that says no once
        // would be asked again by the model picker, the reply-style switch and
        // the phone-link sheet, dropping the signal socket each time.
        //
        // Deliberately per-process rather than persisted. The next launch does
        // try again, which is the whole point — the failure this file is being
        // repaired for was transient in principle and permanent only because
        // nothing ever asked a second time.
        guard !failedToApply.contains(installed) else {
            Self.log.error(
                "not running the installed build, and this build already failed to start; leaving it until the next launch"
            )
            return
        }

        try signalData.write(to: signalURL, options: .atomic)
        try bridgeData.write(to: bridgeURL, options: .atomic)

        // bootout returns non-zero on a first install; that only means there
        // was nothing stale to stop. The bridge goes first and the socket is
        // removed only if the helper really stopped: the socket belongs to a
        // running signal-cli, and deleting it under a live one is how the
        // bridge loses its connection.
        _ = await bootout(Self.bridgeLabel)
        if await bootout(Self.signalLabel) {
            try? fileManager.removeItem(atPath: configuration.socketPath)
        }

        // **Both are attempted, and neither can now prevent the other.** This
        // was `try await bootstrap(signal…)` then `try await bootstrap(bridge…)`,
        // so a signal helper that refused to start meant the bridge — the job
        // that actually answers the phone — was never even asked. On 5 August
        // that is what happened: 1.7.3 installed at 19:49, both bootouts failed
        // at 19:52, the first bootstrap threw, and the daemon went on serving
        // Signal from the 1.7.2 bundle until it crashed at 20:07.
        let signalStarted = await bootstrap(signalURL, label: Self.signalLabel)
        let bridgeStarted = await bootstrap(bridgeURL, label: Self.bridgeLabel)

        // **Said afterwards, and only when it is true.** The notice this
        // replaces was printed before any of the work above, so `mynah.log`
        // recorded "restarting the phone bridge to apply a changed
        // configuration" for a reconcile that restarted nothing whatsoever. A
        // log line that cannot fail is not evidence, and this one was the only
        // account anybody had of an update finishing.
        guard await isRunningTheInstalledBuild(installed) else {
            failedToApply.insert(installed)
            Self.log.error("""
                the phone bridge is still not running the installed build \
                (signal \(signalStarted ? "started" : "did not start"), \
                bridge \(bridgeStarted ? "started" : "did not start")). \
                Quit Mynah and open it again to apply it.
                """)
            throw Failure.launchFailed(Self.bridgeLabel)
        }
        Self.log.notice("the phone bridge is now running the installed build")
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
        bridge: Data, at bridgeURL: URL,
        running installed: InstalledBuild
    ) async -> Bool {
        // **The disk check alone is what made a failed restart permanent.**
        //
        // These two questions — does the file on disk match what I would write,
        // and does launchd hold both jobs — are both satisfied by a reconcile
        // that wrote the plists and then failed to restart anything. The old
        // processes are still loaded, and the file matches by construction
        // because we are the ones who just wrote it. So the write that exists
        // to *trigger* the restart is what convinces the next attempt there is
        // nothing left to do, and the appliance runs the previous build until
        // something kills it.
        //
        // Measured on the owner's Mac at 20:30 on 5 August, three ways:
        //
        //     loaded in launchd        plist on disk           installed binary
        //     6321952-…-608061383    6415200-…-608598496    6415200-…-608598496
        //   120556208-…-608061383  120556208-…-608598502  120556208-…-608598502
        //
        // signal-cli was still executing out of
        // Backups/Mynah-20260805-194946.app four and a half hours after 1.7.3
        // installed, and nothing was ever going to restart it.
        //
        // So the authoritative question is the third one, and it is the only
        // one a failed restart cannot answer falsely.
        guard (try? Data(contentsOf: signalURL)) == signal,
              (try? Data(contentsOf: bridgeURL)) == bridge else {
            return false
        }
        // **This replaces a pair of `isLoaded` calls, and subsumes them.** A
        // stamp can only be read out of a `launchctl print` that succeeded, so
        // "running the installed build" already answers "does launchd hold this
        // job" — keeping both would have meant four launchctl calls to learn
        // what two can say, and a redundant probe is a place for the two answers
        // to disagree.
        //
        // The unanswered-question reading is unchanged and still deliberate:
        // `loadedStamp` returns nil when launchctl could not be asked, and nil
        // is read here as "not reconciled", so uncertainty makes this go on and
        // install. That is the opposite of `disable`'s reading, and for the same
        // reason it always was — uncertainty may rebuild, but uncertainty must
        // never destroy.
        return await isRunningTheInstalledBuild(installed)
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

    /// - Returns: whether launchd took the job. Failure is reported rather than
    ///   thrown so the caller can attempt the other job regardless — see
    ///   `enable`, where throwing here once left the phone bridge unasked.
    @discardableResult
    private func bootstrap(_ plist: URL, label: String) async -> Bool {
        let result = await runner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootstrap", domain, plist.path],
            timeout: 30
        )
        guard let result, result.succeeded else {
            // launchctl's own words. "Bootstrap failed: 37: Operation already
            // in progress" and "5: Input/output error" mean quite different
            // things to whoever reads this afterwards, and the diagnosis of the
            // 5 August failure was slowed by having neither.
            let reason = Self.firstLine(
                of: result?.standardError, or: result?.standardOutput
            ) ?? (result == nil ? "launchctl could not be run" : "no output")
            Self.log.error("launchctl bootstrap \(label) failed: \(reason)")
            return false
        }
        return true
    }

    /// Whether launchd is running the executables that are installed right now.
    ///
    /// Asks launchd what it *loaded*, which is the question `isAlreadyReconciled`
    /// needed and did not have. `launchctl print` reports the in-memory service
    /// definition, so a plist rewritten on disk without a successful
    /// bootout/bootstrap still shows the previous `MYNAH_BUILD_STAMP` — exactly
    /// the discrepancy that proves the restart did not take.
    ///
    /// `nil` from `loadedStamp` — launchctl unavailable, or the job absent — is
    /// read as "not running the installed build". That is the safe direction
    /// here and the opposite of `isLoaded`'s: an unanswered question must not
    /// let a reconcile declare itself finished, and the cost of being wrong is
    /// one restart rather than an appliance stuck on an old build.
    private func isRunningTheInstalledBuild(_ installed: InstalledBuild) async -> Bool {
        guard await loadedStamp(Self.signalLabel) == installed.signal else { return false }
        return await loadedStamp(Self.bridgeLabel) == installed.bridge
    }

    private func loadedStamp(_ label: String) async -> String? {
        guard let result = await runner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "\(domain)/\(label)"],
            timeout: 10
        ), result.succeeded else { return nil }
        return Self.stamp(inLaunchctlPrint: result.standardOutput)
    }

    /// Pulls `MYNAH_BUILD_STAMP => <value>` out of `launchctl print`.
    ///
    /// Parsed rather than asked for structurally because launchctl has no
    /// machine-readable output, and a job's environment is the only place the
    /// build it was started from survives. The variable exists for this: it is
    /// otherwise unread by anything, and its only job is to make two builds of
    /// the same path at the same location distinguishable.
    /// **Scoped to the job's own `environment` block, not the first match.**
    /// `launchctl print` emits three of them in order — `inherited environment`,
    /// `default environment`, then `environment` — and only the last is what
    /// launchd loaded from our plist. A parser taking the first
    /// `MYNAH_BUILD_STAMP` it saw would read a value inherited from whatever
    /// launched Mynah, and reading a stale restart as a finished one is the
    /// precise failure this whole change exists to end. So it fails closed:
    /// anything it cannot place inside `environment = {` is `nil`, and `nil`
    /// means "restart it".
    static func stamp(inLaunchctlPrint output: String) -> String? {
        var insideJobEnvironment = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "environment = {" {
                insideJobEnvironment = true
                continue
            }
            guard insideJobEnvironment else { continue }
            if trimmed == "}" { return nil }
            guard trimmed.hasPrefix("MYNAH_BUILD_STAMP") ,
                  let value = trimmed.components(separatedBy: "=>").last else { continue }
            let stamp = value.trimmingCharacters(in: .whitespaces)
            return stamp.isEmpty ? nil : stamp
        }
        return nil
    }

    private static func firstLine(of primary: String?, or fallback: String?) -> String? {
        for candidate in [primary, fallback] {
            guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            return text.split(separator: "\n").first.map(String.init)
        }
        return nil
    }

    private var domain: String { "gui/\(userID)" }

    /// Identity of an executable, as a string that changes whenever the file
    /// behind a path does.
    ///
    /// This is what makes "Replace" mean replace. Both plists name a *path*
    /// inside Mynah.app, and dragging a new build over the old one changes the
    /// file at that path without changing one byte of the plist. `enable()`
    /// then compared plists, found them identical, correctly concluded launchd
    /// was already running what it would install, and returned — leaving the
    /// daemon executing the old, now-unlinked inode.
    ///
    /// Measured on 31 July: the owner replaced 1.1.0 with 1.1.1, the GUI came
    /// up as 1.1.1, and the daemon serving his phone stayed on 1.1.0 for two
    /// hours. Its running inode was 586638994 against 592565057 on disk. The
    /// fixes in that build were in the app he was looking at and absent from
    /// the one answering his messages, which is worse than not shipping them.
    ///
    /// Size, mtime and inode rather than a hash: these binaries run to 120 MB
    /// and this is computed on every launch, so hashing would cost more than
    /// the problem is worth. A rebuild moves mtime, a replace moves the inode,
    /// and a different build almost always moves size. A false positive costs
    /// one restart nobody notices; a false negative is the bug above.
    static func executableStamp(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.int64Value ?? -1
        return "\(size)-\(Int(modified))-\(inode)"
    }

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
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                // Not read by anything. It is here so that replacing the app
                // changes these bytes, which is what makes `enable()` notice.
                "MYNAH_BUILD_STAMP": executableStamp(configuration.signalCLI)
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
            "LowPriorityIO": false,
            "EnvironmentVariables": [
                // Not read by anything. It is here so that replacing the app
                // changes these bytes, which is what makes `enable()` notice.
                "MYNAH_BUILD_STAMP": executableStamp(configuration.bridge)
            ]
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
