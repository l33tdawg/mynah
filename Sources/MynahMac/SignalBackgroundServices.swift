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

    /// Which channels the owner turned on. See `ChannelSelectionStore`.
    let channels: ChannelSelection

    /// `nil` when WhatsApp is off, **or** when it is on and the app cannot
    /// actually run it — a build that did not vendor Node, a bundle missing
    /// bridge.js.
    ///
    /// Nested rather than five more optional fields beside `account`, because
    /// the five are only ever meaningful together: a configuration carrying a
    /// port and no bridge path is a state that cannot be acted on, and making
    /// it representable is how a half-configured job gets installed.
    let whatsApp: WhatsAppServiceConfiguration?

    /// Written out rather than synthesised, so the two new fields can default.
    ///
    /// A default is right here and wrong in `PromiseLedger.promised` next door,
    /// and the difference is worth stating: this describes an appliance's shape,
    /// and "Signal, no WhatsApp" is both the shape every existing install has
    /// and the shape every caller that omits these means. `promised` decides
    /// where one message's apology is sent, where a default would silently pick
    /// a channel. `current()` below passes both explicitly, so nothing in
    /// production reaches these.
    init(
        account: String,
        signalCLI: URL,
        bridge: URL,
        sage: URL,
        provider: String,
        model: String?,
        socketPath: String,
        channels: ChannelSelection = .signalOnly,
        whatsApp: WhatsAppServiceConfiguration? = nil
    ) {
        self.account = account
        self.signalCLI = signalCLI
        self.bridge = bridge
        self.sage = sage
        self.provider = provider
        self.model = model
        self.socketPath = socketPath
        self.channels = channels
        self.whatsApp = whatsApp
    }

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

        let channels = ChannelSelectionStore.current(defaults)

        return SignalServiceConfiguration(
            account: account,
            signalCLI: signalCLI,
            bridge: contents.appendingPathComponent("MacOS/sage-voiced"),
            sage: node?.executable ?? vendored,
            provider: brain.backendIdentifier,
            model: brain.modelName,
            socketPath: SignalTooling.socketPath,
            channels: channels,
            whatsApp: channels.includes(.whatsapp)
                ? WhatsAppServiceConfiguration.inside(contents, signalAccount: account, defaults: defaults)
                : nil
        )
    }
}

/// What launchd needs to run the vendored WhatsApp bridge.
///
/// Built from the app bundle rather than remembered, for the reason
/// `MYNAH_BUILD_STAMP` exists next door: these paths move when the owner
/// replaces the app, and a remembered path outlives the bundle it named.
struct WhatsAppServiceConfiguration: Sendable, Equatable {
    /// The vendored interpreter. `Contents/Resources/node/bin/node`, re-signed
    /// by package-app.sh with allow-jit and nothing else.
    let node: URL
    /// `Contents/Resources/whatsapp/bridge.js`.
    let bridge: URL
    /// Who may talk to the appliance, in WhatsApp's own form: digits, country
    /// code first, no `+`.
    ///
    /// **Empty is not "everybody".** `bridge.js` refuses every incoming message
    /// when `WHATSAPP_ALLOWED_USERS` is unset, and `*` is what would open it —
    /// so an empty list here fails closed. That is the right direction, but it
    /// also means an empty list produces a bridge that answers nothing, which is
    /// why `enable` refuses to install one rather than starting a helper that
    /// can only disappoint.
    let numbers: [String]
    /// Loopback only. Where `WhatsAppChannel` POSTs sends.
    let port: Int
    /// The UNIX socket inbound messages are pushed over.
    let socketPath: String

    static let defaultPort = 39930

    /// - Parameter signalAccount: what the WhatsApp allowlist is derived from
    ///   when the owner has not given one of their own. Optional because a Mac
    ///   with no Signal account linked is a real state — and one where there is
    ///   nothing to derive, so this returns nil rather than installing a bridge
    ///   that answers nobody.
    static func inside(
        _ contents: URL,
        signalAccount: String?,
        defaults: UserDefaults = .standard
    ) -> WhatsAppServiceConfiguration? {
        switch availability(contents, signalAccount: signalAccount, defaults: defaults) {
        case .ready(let configuration): return configuration
        case .notInThisBuild, .noNumberToAllow: return nil
        }
    }

    /// Why WhatsApp cannot run, when it cannot.
    ///
    /// **`inside` returned `nil` for two unrelated reasons and the screen said
    /// the wrong one.** Settings picked its sentence off a single Bool and told
    /// owners "This build of Mynah can only do Signal" — false twice over for
    /// anyone whose build is fine and who simply has no Signal number linked,
    /// which is the ordinary state of a Mac someone bought Mynah for the
    /// WhatsApp on. They were told to go and do the thing they chose this build
    /// to avoid, and the picker was disabled so they could not argue.
    ///
    /// The two cases differ in the only way that matters: one is permanent
    /// without a new download, and one is a step away.
    enum Availability {
        case ready(WhatsAppServiceConfiguration)
        /// No vendored interpreter or bridge. Nothing the owner can do here.
        case notInThisBuild
        /// The build is fine; there is no number to put on the allowlist yet.
        case noNumberToAllow
    }

    static func availability(
        _ contents: URL,
        signalAccount: String?,
        defaults: UserDefaults = .standard
    ) -> Availability {
        let node = contents.appendingPathComponent("Resources/node/bin/node")
        let bridge = contents.appendingPathComponent("Resources/whatsapp/bridge.js")
        // **Absent rather than broken.** A build made without
        // provision-node.sh has no interpreter, and a plist naming a
        // non-existent program is a job launchd retries every 30 seconds
        // forever, writing a screenful into bridge.log each time.
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: bridge.path) else {
            return .notInThisBuild
        }
        let numbers = ChannelSelectionStore.whatsAppNumbers(defaults, signalAccount: signalAccount)
        guard !numbers.isEmpty else { return .noNumberToAllow }
        return .ready(WhatsAppServiceConfiguration(
            node: node,
            bridge: bridge,
            numbers: numbers,
            port: defaultPort,
            socketPath: WhatsAppClient.defaultSocketPath()
        ))
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
    /// - Parameter retryingAfterFailure: the owner asked for this directly, so
    ///   a build that already refused to start is tried once more rather than
    ///   left until the next launch. False for every reconcile the app decides
    ///   on by itself — see the latch in the implementation.
    func enable(_ configuration: SignalServiceConfiguration, retryingAfterFailure: Bool) async throws
    /// - Parameter reason: why the owner's phone is about to stop being
    ///   answered, in words that would mean something in a log six hours later.
    ///   Required rather than optional: this is the one call in the app that can
    ///   take the appliance away, and a caller that cannot say why should not be
    ///   making it.
    func disable(because reason: String) async
    /// Asked rather than remembered — see `BackgroundHelperState`.
    func state() async -> BackgroundHelperState
}

extension SignalBackgroundServicing {
    /// The ordinary reconcile: the app deciding by itself that the jobs and the
    /// owner's choices should agree. Never retries a build that already refused
    /// to start; only a direct request does that.
    func enable(_ configuration: SignalServiceConfiguration) async throws {
        try await enable(configuration, retryingAfterFailure: false)
    }
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
    static let whatsAppLabel = "local.sage.voicebridge.whatsapp"

    /// Everything this app is allowed to install or remove from launchd.
    ///
    /// A list rather than three constants spelled out at each site, because
    /// `disable` used to name two and there are now three — and a helper left
    /// loaded after the owner turns answering off is a WhatsApp client still
    /// connected to their account by an app that believes it stopped.
    static let managedLabels = [bridgeLabel, signalLabel, whatsAppLabel]

    /// Every log file a job this app installs writes to.
    ///
    /// launchd creates these from `StandardOutPath` under the job's umask, so
    /// they arrive `0644` and no write path this codebase owns ever touches
    /// them — `protectLogs` chmods them instead. whatsapp.log was missing for
    /// the whole of the third job's life, and it is the one with the most in it:
    /// who messaged the owner, the allowlist on every start, and until this
    /// release the device-linking QR.
    ///
    /// A named constant so a test can compare it against what the plists
    /// actually declare, rather than against a second hand-written list.
    static let protectedLogNames = ["bridge.log", "signal.log", "appliance.log", "whatsapp.log"]

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
        /// `nil` when Signal is off, like `whatsApp`.
        let signal: String?
        let bridge: String
        /// `nil` when WhatsApp is off. Part of the identity rather than beside
        /// it, so turning WhatsApp on is a different build to
        /// `failedToApply` — otherwise a Signal-only start that failed once
        /// would suppress the install of the WhatsApp helper the owner has since
        /// asked for, until the next launch.
        let whatsApp: String?

        init(signal: String?, bridge: String, whatsApp: String? = nil) {
            self.signal = signal
            self.bridge = bridge
            self.whatsApp = whatsApp
        }
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

    func enable(
        _ configuration: SignalServiceConfiguration,
        retryingAfterFailure: Bool = false
    ) async throws {
        guard !isTestReachingTheRealMachine else {
            Self.log.error("a test reached the real launchd; refusing to install anything")
            return
        }
        // Only what this configuration will actually run. `signalCLI` was in
        // this list unconditionally, so a WhatsApp-only appliance refused to
        // install at all on a Mac with no signal-cli — a state the Settings
        // picker can now produce.
        var required = [configuration.bridge, configuration.sage]
        if configuration.channels.includes(.signal) { required.append(configuration.signalCLI) }
        for executable in required {
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                throw Failure.missingExecutable(executable.path)
            }
        }

        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = homeDirectory.appendingPathComponent("Library/Logs/Mynah", isDirectory: true)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        protectLogs(in: logs)

        // **Created here, `0700`, rather than left to the bridge's own mkdir.**
        // What lands in it is the owner's paired WhatsApp session — the keys
        // that let this Mac send as them — and their message text in the spool.
        // `bridge.js` creates these directories under launchd's umask, which is
        // the same route by which `bridge.log` arrived `0644` with his phone
        // number in it twenty-six times. Owning the creation is the only way the
        // mode is a measurement rather than a hope.
        let whatsAppState = homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("WhatsApp", isDirectory: true)
        if configuration.whatsApp != nil {
            try? OwnerOnlyFileSecurity.prepareDirectory(whatsAppState, fileManager: fileManager)
            for name in ["session", "spool"] {
                try? OwnerOnlyFileSecurity.prepareDirectory(
                    whatsAppState.appendingPathComponent(name, isDirectory: true),
                    fileManager: fileManager
                )
            }
        }

        let signalURL = launchAgents.appendingPathComponent("\(Self.signalLabel).plist")
        let bridgeURL = launchAgents.appendingPathComponent("\(Self.bridgeLabel).plist")
        let whatsAppURL = launchAgents.appendingPathComponent("\(Self.whatsAppLabel).plist")
        // **Optional for the same reason the WhatsApp one is.** This was
        // unconditional, so choosing WhatsApp-only still installed and started
        // signal-cli — a daemon told `--channels whatsapp` reads nothing from
        // it, while signal-cli sits on the owner's Signal account draining
        // messages into a socket nobody is listening to. Signal's own delivery
        // receipts go out, so the sender sees delivered and the owner never
        // sees a reply.
        //
        // Symmetric with `whatsAppData`: nil means there must be no such job,
        // not "leave whatever is there".
        let signalData = configuration.channels.includes(.signal)
            ? try Self.plistData(Self.signalPlist(configuration, logs: logs, home: homeDirectory))
            : nil
        let bridgeData = try Self.plistData(
            Self.bridgePlist(configuration, logs: logs, home: homeDirectory)
        )
        // **`nil` is a state this has to install, not skip.** WhatsApp being off
        // is not "leave whatever is there alone" — it is "there must be no
        // WhatsApp helper", and a bridge left loaded after the owner switched
        // the channel off is this app keeping a live connection to their
        // WhatsApp account after telling them it had stopped.
        let whatsAppData = try configuration.whatsApp.map {
            try Self.plistData(Self.whatsAppPlist(
                $0,
                logs: logs,
                home: homeDirectory,
                state: whatsAppState
            ))
        }

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
            signal: configuration.channels.includes(.signal)
                ? Self.executableStamp(configuration.signalCLI)
                : nil,
            bridge: Self.executableStamp(configuration.bridge),
            whatsApp: configuration.whatsApp.map { Self.executableStamp($0.bridge) }
        )

        if await isAlreadyReconciled(
            signal: signalData, at: signalURL,
            bridge: bridgeData, at: bridgeURL,
            whatsApp: whatsAppData, at: whatsAppURL,
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
        if failedToApply.contains(installed) {
            // **The owner asking is not the same event as the app reconciling,
            // and treating them alike turned one transient failure into a dead
            // end.** The churn this latch prevents is real, and every case it
            // was written for is the app deciding on its own to reconcile.
            //
            // None of them is the owner switching to Both and pressing Link
            // WhatsApp. That returned here, wrote nothing, started nothing, and
            // reported it only to `mynah.log` — the setting looked saved and the
            // helper never appeared. The throw below does name the next action
            // ("Quit Mynah and open it again"), which is exactly the sentence
            // this owner needed, and the guard returned before it could be said.
            //
            // So an explicit request gets one honest attempt. If it fails again
            // it re-latches on the way out and the owner is told, which is the
            // whole difference: a failure they can see beats a silence they
            // cannot.
            guard retryingAfterFailure else {
                Self.log.error(
                    "not running the installed build, and this build already failed to start; leaving it until the next launch"
                )
                return
            }
            failedToApply.remove(installed)
            Self.log.info("the owner asked for this again after it failed; trying once more")
        }

        if let signalData {
            try signalData.write(to: signalURL, options: .atomic)
        } else {
            _ = await bootout(Self.signalLabel)
            try? fileManager.removeItem(at: signalURL)
            try? fileManager.removeItem(atPath: configuration.socketPath)
        }
        try bridgeData.write(to: bridgeURL, options: .atomic)
        if let whatsAppData {
            try whatsAppData.write(to: whatsAppURL, options: .atomic)
        } else {
            // Booted out and removed, not merely left unwritten. See the note
            // where `whatsAppData` is built.
            _ = await bootout(Self.whatsAppLabel)
            try? fileManager.removeItem(at: whatsAppURL)
        }

        // bootout returns non-zero on a first install; that only means there
        // was nothing stale to stop. The bridge goes first and the socket is
        // removed only if the helper really stopped: the socket belongs to a
        // running signal-cli, and deleting it under a live one is how the
        // bridge loses its connection.
        _ = await bootout(Self.bridgeLabel)
        if signalData != nil, await bootout(Self.signalLabel) {
            try? fileManager.removeItem(atPath: configuration.socketPath)
        }
        if whatsAppData != nil {
            _ = await bootout(Self.whatsAppLabel)
            // The events socket belongs to the process just stopped. A stale one
            // left in place is a path `WhatsAppClient` connects to and then waits
            // on for ever — connected, silent, and indistinguishable from a
            // WhatsApp that nobody is messaging.
            try? fileManager.removeItem(atPath: configuration.whatsApp?.socketPath ?? "")
        }

        // **Both are attempted, and neither can now prevent the other.** This
        // was `try await bootstrap(signal…)` then `try await bootstrap(bridge…)`,
        // so a signal helper that refused to start meant the bridge — the job
        // that actually answers the phone — was never even asked. On 5 August
        // that is what happened: 1.7.3 installed at 19:49, both bootouts failed
        // at 19:52, the first bootstrap threw, and the daemon went on serving
        // Signal from the 1.7.2 bundle until it crashed at 20:07.
        var signalStarted = true
        if signalData != nil {
            signalStarted = await bootstrap(signalURL, label: Self.signalLabel)
        }
        let bridgeStarted = await bootstrap(bridgeURL, label: Self.bridgeLabel)
        // Attempted like the other two, and like them it cannot prevent either.
        // A WhatsApp helper that will not start must not take Signal down with
        // it — the owner asked for both, and one of two is not none.
        var whatsAppStarted = true
        if whatsAppData != nil {
            whatsAppStarted = await bootstrap(whatsAppURL, label: Self.whatsAppLabel)
        }

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
                (signal \(signalData == nil ? "off" : (signalStarted ? "started" : "did not start")), \
                bridge \(bridgeStarted ? "started" : "did not start"), \
                whatsapp \(whatsAppData == nil ? "off" : (whatsAppStarted ? "started" : "did not start"))). \
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
        // **whatsapp.log was missing, and it is the one with the most in it.**
        //
        // launchd creates it from StandardOutPath under the job's umask, so it
        // arrives 0644 like the other two did — and it carries what the bridge
        // prints: refusal lines naming who messaged the owner, the allowlist on
        // every start, and until this release the device-linking QR. This list
        // is hardcoded, which is why adding a fourth job did not add a fourth
        // entry; the plists are the source of truth for what exists and this is
        // a copy of that knowledge kept by hand.
        for name in Self.protectedLogNames {
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
        signal: Data?, at signalURL: URL,
        bridge: Data, at bridgeURL: URL,
        whatsApp: Data?, at whatsAppURL: URL,
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
        guard (try? Data(contentsOf: bridgeURL)) == bridge else { return false }
        if let signal {
            guard (try? Data(contentsOf: signalURL)) == signal else { return false }
        } else if fileManager.fileExists(atPath: signalURL.path) {
            return false
        }
        // **Deliberately redundant today, and worth keeping — but say so
        // plainly rather than let it read as proof.**
        //
        // Every state this can currently reject is also rejected downstream:
        // `isRunningTheInstalledBuild` compares the WhatsApp job's loaded stamp
        // and requires no job at all when WhatsApp is off. Putting this whole
        // block back to `_ = whatsApp` leaves every test in
        // `TheThirdLaunchAgentTests` green, which is the honest measurement.
        //
        // It stays because the redundancy is an accident of what the *other*
        // plist happens to carry. The daemon's job currently repeats
        // `--whatsapp-allow`, so a changed allowlist is caught by the comparison
        // above; the day somebody has the daemon read the numbers from the same
        // store instead — a reasonable change — the stamp becomes the only
        // remaining check, and a stamp cannot see an allowlist. This is the one
        // check that compares the WhatsApp job to the WhatsApp job.
        if let whatsApp {
            guard (try? Data(contentsOf: whatsAppURL)) == whatsApp else { return false }
        } else if fileManager.fileExists(atPath: whatsAppURL.path) {
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
        Self.log.error("removing every LaunchAgent Mynah manages, so the phone will stop being answered: \(reason)")
        for label in Self.managedLabels {
            _ = await bootout(label)
        }

        // A booted-out LaunchAgent whose plist is left behind can be loaded
        // again at the next login. Removing only Mynah's own managed plists
        // makes Pause and the Settings switch survive a restart; enable()
        // recreates them from the persisted choices when the owner turns
        // answering back on.
        let launchAgents = homeDirectory.appendingPathComponent(
            "Library/LaunchAgents",
            isDirectory: true
        )
        for label in Self.managedLabels {
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
        // **Every job Mynah installed, not just the daemon.**
        //
        // This asked about the bridge alone, on the reasoning that it is the job
        // that answers the phone. True, and it stopped being sufficient when a
        // third job arrived: with WhatsApp switched on and its helper dead, the
        // daemon is still loaded, so this returned `.running` and every screen
        // said the appliance was fine while WhatsApp answered nothing.
        //
        // A job whose plist is on disk is one Mynah asked for, so it is one this
        // has to account for. Nothing is hardcoded about which — the plists are
        // the source of truth, which is what stops a fourth job being forgotten
        // the way the third was.
        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let installedLabels = Self.managedLabels.filter {
            fileManager.fileExists(atPath: launchAgents.appendingPathComponent("\($0).plist").path)
        }
        guard !installedLabels.isEmpty else { return .absent }

        var anyUnknown = false
        for label in installedLabels {
            guard let loaded = await isLoaded(label) else {
                // launchctl did not answer. Reporting "off" would be a guess,
                // and the guess that costs the owner most.
                anyUnknown = true
                continue
            }
            // One helper down is the whole appliance degraded: the owner cannot
            // be reached on that channel, and saying "Running" would send him
            // looking anywhere but here.
            if !loaded { return .installedButNotRunning }
        }
        return anyUnknown ? .unknown : .running
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
        // `nil` on either side means the job must not exist at all, which
        // `loadedStamp` reports as nil too — so one comparison covers both
        // directions for both optional jobs.
        guard await loadedStamp(Self.signalLabel) == installed.signal else { return false }
        guard await loadedStamp(Self.bridgeLabel) == installed.bridge else { return false }
        // **The third job, asked the same way and only when it should exist.**
        //
        // Leaving it out would have been the defect this method was written to
        // end, one channel over: a WhatsApp helper that refused to start would
        // have left both other stamps matching, so `enable` would declare
        // itself finished, record nothing in `failedToApply`, and
        // `isAlreadyReconciled` would then decline to try again — for ever. The
        // owner would have WhatsApp switched on in Settings, no error anywhere,
        // and an app that never attempts to start it.
        //
        // `nil` when WhatsApp is off is not "do not check". There must be no
        // WhatsApp job at all in that case, and `loadedStamp` returning
        // something means launchd still holds one.
        guard let whatsApp = installed.whatsApp else {
            return await loadedStamp(Self.whatsAppLabel) == nil
        }
        return await loadedStamp(Self.whatsAppLabel) == whatsApp
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
        // **Passed even when it is just "signal".** The daemon defaults to
        // Signal without this flag, so omitting it would produce the same
        // behaviour today — and a plist that says nothing about channels is one
        // nobody can read to find out which the appliance is answering. It is
        // also what makes turning WhatsApp on a plist change, which is what
        // `isAlreadyReconciled` compares to decide whether to restart anything.
        arguments += ["--channels", ChannelKind.allCases
            .filter(configuration.channels.includes)
            .map(\.rawValue)
            .joined(separator: ",")]
        if let whatsApp = configuration.whatsApp {
            arguments += [
                "--whatsapp-allow", whatsApp.numbers.joined(separator: ","),
                "--whatsapp-port", String(whatsApp.port),
                "--whatsapp-socket", whatsApp.socketPath
            ]
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

    /// The vendored Node process that owns the WhatsApp connection.
    ///
    /// **`RunAtLoad` and `KeepAlive` like the other two, but the failure mode is
    /// different and worth naming.** signal-cli and the daemon can be killed and
    /// restarted freely. This one holds a paired WhatsApp session: a restart
    /// loop that outruns `ThrottleInterval` looks to WhatsApp like a client
    /// reconnecting dozens of times a minute, which is how a linked device gets
    /// dropped and the owner has to scan a QR again. Hence the same 30-second
    /// throttle, and hence `enable` refusing to install a job whose program is
    /// missing rather than letting launchd discover it every 30 seconds forever.
    static func whatsAppPlist(
        _ whatsApp: WhatsAppServiceConfiguration,
        logs: URL,
        home: URL,
        state: URL
    ) -> [String: Any] {
        [
            "Label": whatsAppLabel,
            "ProgramArguments": [
                whatsApp.node.path,
                whatsApp.bridge.path,
                "--port", String(whatsApp.port),
                // Without this the bridge behaves exactly as upstream does: an
                // in-memory queue and no spool. It is the flag that turns on the
                // durable inbound path Mynah reads. See whatsapp/bridge.js.
                "--events-socket", whatsApp.socketPath,
                "--spool", state.appendingPathComponent("spool", isDirectory: true).path,
                "--session", state.appendingPathComponent("session", isDirectory: true).path
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            // Not the home directory: `WorkingDirectory` is what SAGE derives an
            // agent identity from elsewhere in this product, and a bridge that
            // never speaks to SAGE has no business influencing it. Its own
            // directory is the honest answer and the one that keeps a relative
            // path in a stack trace meaningful.
            "WorkingDirectory": whatsApp.bridge.deletingLastPathComponent().path,
            "StandardOutPath": logs.appendingPathComponent("whatsapp.log").path,
            "StandardErrorPath": logs.appendingPathComponent("whatsapp.log").path,
            "ProcessType": "Interactive",
            "LowPriorityIO": false,
            "EnvironmentVariables": [
                "HOME": home.path,
                // Homebrew ahead of the system paths, matching the Signal
                // job. Not for Node — that is passed by absolute path — but for
                // ffmpeg, which `/send-media` shells out to so a spoken reply
                // arrives as a voice bubble rather than a file. It ships with
                // neither macOS nor this app, so `/usr/bin:/bin` guaranteed the
                // conversion failed on every Mac; with this, an owner who has it
                // gets the bubble and one who does not gets a playable file and
                // a log line saying why.
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                // **The bridge's own allowlist, and it is not the only one.**
                // `WhatsAppSenderAllowlist` on the Swift side refuses the same
                // senders again. That is deliberate: this list lives in a plist
                // the owner can edit and on a process this app launches, and a
                // second check inside the app is what makes an edited plist a
                // bridge that spools messages nobody answers rather than an
                // appliance serving strangers.
                //
                // Empty would mean "reject everything" here, not "allow
                // everything" — but `WhatsAppServiceConfiguration.inside`
                // refuses to build at all in that case, so this is never empty.
                "WHATSAPP_ALLOWED_USERS": whatsApp.numbers.joined(separator: ","),
                "WHATSAPP_MODE": "self-chat",
                // **Empty on purpose, and this is not cosmetic.** Unset, the
                // bridge prefixes every outgoing message with its upstream
                // vendor's banner. Mynah already puts its own marker on a reply
                // before the text ever reaches the bridge, so a prefix here
                // would arrive on the owner's phone underneath somebody else's
                // branding, twice-marked.
                //
                // The cost is that the bridge's own echo detection falls back to
                // the ids it remembers sending, which are in memory and gone
                // after a restart. The daemon covers that window: a message
                // whose text begins with Mynah's reply prefix is refused as
                // another bridge answering the same thread, which is exactly
                // what an unrecognised echo of our own reply is.
                "WHATSAPP_REPLY_PREFIX": "",
                "MYNAH_BUILD_STAMP": executableStamp(whatsApp.bridge)
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
