import Foundation

/// Starts the SAGE node when nothing is serving one.
///
/// ## Why this exists
///
/// Mynah spawned `sage-gui mcp` from five places and never once started a node.
/// `sage-gui mcp` is a REST *client* — `runMCP` ends at `mcp.NewServer(baseURL,
/// agentKey)` and its own error text asks "is sage-gui serve running?". So on a
/// Mac that had no SAGE.app, every memory call went to a port nobody was
/// listening on, while `EnvironmentProbe` reported SAGE "already present"
/// because it checks that a *file exists*, never that a node answers.
///
/// The result was the shape that is hardest to notice: a brand-new install that
/// looks set up and silently remembers nothing.
///
/// ## Ported from QuietType
///
/// QuietType has shipped this for a while, and it is deliberately copied rather
/// than reinvented — `LocalTypeMacApp.startSageIfInstalled` and
/// `isSageNotRunning`. The mechanism is kept identical:
///
///  - **Lazy, not proactive.** Nothing starts at launch. A node is started only
///    after a call fails in a way that means "nothing is listening", so a Mac
///    that already runs SAGE never has a second node started beside it.
///  - **`serve` as a retained child process.** Not `launchd`, not a login item.
///    It lives and dies with the app that needed it.
///  - **Open the bundle as a fallback.** If the `.app` is there but no
///    executable matched inside it, hand it to the system and let SAGE start
///    itself.
///  - **A settle delay, then re-check.** `serve` binds its port a moment after
///    `run()` returns, so the caller waits before asking again.
///
/// ## The two deliberate differences, and why
///
/// 1. **`SageNodeChoice` decides which node, not a second detector.** Mynah
///    already has the installed-wins rule, with a long note on why picking the
///    vendored copy on somebody's own Mac starts a second, empty brain. Adding
///    QuietType's `SageDetector` beside it would be a third answer to a question
///    this codebase has already answered twice.
/// 2. **Opening the bundle is injected rather than `NSWorkspace` directly.**
///    `SageVoiceCore` is linked into `sage-voiced`, a launchd daemon, and
///    importing AppKit there to call one function is not worth it. The default
///    shells out to `/usr/bin/open`, which is what `NSWorkspace.shared.open`
///    wraps.
///
/// ## What it must never do
///
/// Start an `.installed` node with vendored-bootstrap environment. Those
/// variables are a genesis-time contract; against a chain that was not born
/// from that path `serve` refuses to boot at all (`cmd/sage-gui/node.go`,
/// "first-party app-v23 companion is not ready"). Pointing them at the owner's
/// node would take a working SAGE and stop it starting.
public final class SageNodeSupervisor: @unchecked Sendable {

    /// Shared because the thing being guarded is a single OS-level port. Two
    /// supervisors would each hold an empty slot and both spawn a `serve`.
    public static let shared = SageNodeSupervisor()

    /// What a start attempt did.
    public enum Outcome: Equatable, Sendable {
        /// This process already owns a running `serve`.
        case alreadyRunning
        /// Started `serve`. `bootstrapped` is true when the vendored companion
        /// contract was passed, which happens only on a node Mynah owns.
        case started(executablePath: String, bootstrapped: Bool)
        /// No executable matched, but a bundle was there and was handed to the
        /// system to launch itself.
        case openedApplication(bundlePath: String)
        /// Nothing to start: no installed node and no vendored copy.
        case noNodeAvailable
        /// The vendored SAGE predates the companion bootstrap, so starting it
        /// would create a chain that can never be given one. See
        /// `minimumBootstrapCapableVersion`.
        case vendoredNodeTooOld(version: String)
        /// A start was attempted too recently. See `retryCooldownSeconds`.
        case cooledDown
        case failed(String)
    }

    /// The oldest vendored SAGE that understands the companion contract.
    ///
    /// **This gate exists because the alternative is silent and permanent.**
    /// The vendored bootstrap is read at genesis and SAGE refuses to retrofit
    /// it ("automatic legacy repair is not supported"). A SAGE that predates it
    /// does not fail on those variables — it does not know them at all, ignores
    /// them, and creates an ordinary chain whose agent gets the fail-closed
    /// mask. That chain can never be bootstrapped afterwards. The owner's only
    /// remedy is deleting the brain they have been talking to.
    ///
    /// Verified rather than assumed: the 11.14.1 bundle vendored at the time
    /// this was written contains no `SAGE_VENDORED_AGENT_KEY_FILE` string and
    /// no direct-v23 genesis path.
    ///
    /// So a vendored node older than this is **not started at all**. No node is
    /// a visible, recoverable problem; an un-bootstrappable node is neither.
    /// Bump this only alongside a `scripts/vendor-sage.sh` run that actually
    /// ships the contract.
    ///
    /// ## Why the floor is 11.16 even though 11.15.1 bootstraps correctly
    ///
    /// 11.15.1 passes every part of this contract that can be checked at
    /// genesis. Measured on a fresh vendored node, not inferred: it seeds a
    /// root-bound app-v23 genesis, reports "first-party app-v23 companion
    /// enrollment is ready" for `voice-interface`, and commits a first memory
    /// at height 8 with no CEREBRUM step. By the acceptance gate alone it
    /// passes.
    ///
    /// **And it is still not shippable, because recall is broken on it.** On
    /// that same node every read failed with "Authorization unavailable: Memory
    /// classification state is unavailable" — at height 8 and again at height
    /// 13, so it is the defect rather than start-up settling. That is what
    /// 11.16's "restore local sage_turn recall under app-v23" repairs.
    ///
    /// An appliance that stores and cannot recall is the failure this whole
    /// supervisor exists to kill, wearing a different hat: the owner talks to
    /// it, it says it remembers, and nothing ever comes back. Shipping that
    /// deliberately would be worse than shipping no node, because it looks like
    /// it is working.
    ///
    /// The data is not lost either way — the SAGE team confirmed a chain
    /// created by 11.15.1 keeps its app-v23/bootstrap-v2 genesis forever and is
    /// carried forward on-chain by 11.16's local Root proposing and voting
    /// app-v24, so such a node is upgradeable rather than stranded. That makes
    /// the floor a question of what the owner *experiences* before they update,
    /// and a node that visibly cannot answer is the wrong answer.
    ///
    /// So: 11.16 or nothing. Lower it only if recall is verified working on the
    /// build in question.
    ///
    /// ## 11.16.1: recall verified, on the same terms 11.15.1 failed
    ///
    /// Measured on a fresh isolated vendored node, not inferred. Genesis seeded
    /// the root-bound app-v23 bootstrap for `voice-interface`; the local Root
    /// proposed app-v24, auto-voted ACCEPT and persisted the plan; at the
    /// activation height the node logged "first-party companion admitted after
    /// app-v24 activation". A `sage_remember` then committed, and **both**
    /// `sage_recall` and `sage_turn` returned that memory, signed by the
    /// genesis-bound companion agent. No "Memory classification state is
    /// unavailable" on any read — which is the whole difference from 11.15.1.
    ///
    /// So 11.16.1 is the build this floor has actually been tested against.
    /// 11.16.0 satisfies the floor arithmetically but was never run here.
    ///
    /// ## A fresh node is legitimately mute for about ten minutes
    ///
    /// Also measured, and worth knowing before treating it as a fault: app-v24
    /// activates at a **governed activation height** — 204 on that node — and
    /// the pending-plan pump heartbeats a quiescent chain at roughly one block
    /// every four seconds. That is ~13 minutes from first launch during which
    /// writes are refused with "first-party companion memory writes require
    /// governed app-v24 activation".
    ///
    /// That refusal is legible and self-correcting, unlike the failures above,
    /// but it is the owner's first impression on a brand-new Mac. Anything that
    /// reports readiness must not read it as broken.
    ///
    /// ## Testing a second node beside a live one
    ///
    /// Needs a separate `SAGE_HOME`, `REST_ADDR`, `SAGE_CMT_RPC_ADDR` and
    /// `SAGE_CMT_P2P_ADDR`, plus `quorum.tls_addr` in config.yaml. Note
    /// `mcp_port` is discovery/output metadata and does **not** configure that
    /// listener, and there is no environment override for it yet.
    ///
    /// `quorum.tls_addr` is the one that bites: everything else has an
    /// environment override, so a second node comes all the way up, prints
    /// "SAGE Personal ready", and only then exits on `MCP TLS listener bind:
    /// address already in use` against the live node's 8443.
    public static let minimumBootstrapCapableVersion = MynahReleaseVersion(
        major: 11,
        minor: 16,
        patch: 0
    )

    /// Whether a vendored bundle is new enough to be worth starting.
    ///
    /// An unreadable or unparseable version refuses, deliberately: the failure
    /// this guards is unrecoverable, so "cannot tell" has to mean no.
    public static func supportsCompanionBootstrap(version: String?) -> Bool {
        guard let version, let parsed = MynahReleaseVersion.parse(version) else { return false }
        return parsed >= minimumBootstrapCapableVersion
    }

    /// How long to wait before starting `serve` again after an attempt.
    ///
    /// This is not politeness, it is the difference between a slow start and a
    /// spawn loop. `serve` is fail-closed about the vendored companion contract:
    /// against a chain that was not born from that genesis it prints its reason
    /// and *exits immediately* (`cmd/sage-gui/node.go`, "first-party app-v23
    /// companion is not ready"). Without a cooldown, every probe would see a
    /// dead slot, spawn another `serve`, and watch it exit — forever, at
    /// whatever rate the caller polls.
    ///
    /// A fresh vendored node is also legitimately not-ready for a while: its
    /// signed genesis sets consensus app version 23 before block 1, and the
    /// Companion stays blocked until governed app-v24 activates. So "started
    /// but the roster still doesn't show us" is the expected first answer, not
    /// a reason to start anything else.
    public static let retryCooldownSeconds: TimeInterval = 30

    /// How long to wait after `run()` before a caller re-checks. QuietType's
    /// 1.2s, kept as-is: it is long enough for `serve` to bind in practice and
    /// short enough not to feel like a hang.
    public static let settleNanoseconds: UInt64 = 1_200_000_000

    private let stateLock = NSLock()
    private var serveProcess: Process?
    private var lastAttemptAt: Date?
    private let openApplication: @Sendable (URL) -> Void
    private let now: @Sendable () -> Date

    public init(
        openApplication: (@Sendable (URL) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.openApplication = openApplication ?? { url in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.path]
            try? process.run()
        }
        self.now = now
    }

    // MARK: - Is this the error that means "nothing is listening"?

    /// Ported verbatim in intent from QuietType's `isSageNotRunning`.
    ///
    /// Deliberately narrow. A node that answers with a real HTTP error is
    /// running and has something else wrong with it, and starting a second
    /// `serve` would not fix it.
    public static func isNodeNotRunning(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorNotConnectedToInternet
        ].contains(nsError.code)
    }

    /// The status-code half of the same question, for callers holding a
    /// response rather than a thrown `URLError`. `0` is "no response at all";
    /// 502/503 are a proxy or a node mid-start.
    public static func isNodeNotRunning(httpStatus: Int) -> Bool {
        httpStatus == 0 || httpStatus == 502 || httpStatus == 503
    }

    // MARK: - Starting

    /// Starts a node if this process is not already running one.
    ///
    /// Returns without waiting. Callers that need to issue a request should
    /// sleep `settleNanoseconds` first — `startAndSettle` does both.
    @discardableResult
    public func startIfNeeded(
        choice: SageNodeChoice? = SageNodeChoice.resolve(
            vendored: SageNodeLocator.vendoredExecutableURL()
        ),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Outcome {
        stateLock.lock()
        if let running = serveProcess, running.isRunning {
            stateLock.unlock()
            return .alreadyRunning
        }
        // A `serve` that exited leaves a non-nil, non-running Process behind.
        // Clearing it here is what allows a second attempt after a crash;
        // QuietType's `guard sageServeProcess == nil` never retries.
        serveProcess = nil
        if let last = lastAttemptAt,
           now().timeIntervalSince(last) < Self.retryCooldownSeconds {
            stateLock.unlock()
            return .cooledDown
        }
        lastAttemptAt = now()
        stateLock.unlock()

        guard let choice else { return .noNodeAvailable }

        guard fileManager.isExecutableFile(atPath: choice.executable.path) else {
            // Present but not runnable. If there is a bundle, let the system
            // launch it; SAGE.app serves its own node when opened.
            if let bundle = SageNodeLocator.appBundle(containing: choice.executable),
               fileManager.fileExists(atPath: bundle.path) {
                openApplication(bundle)
                return .openedApplication(bundlePath: bundle.path)
            }
            return .noNodeAvailable
        }

        let bootstrap = choice.mayBeManagedByMynah
        if bootstrap {
            // Only ever refuses our own vendored copy. An installed node is the
            // owner's and is started as-is — it is not ours to version-gate.
            let version = SageNodeLocator.appBundle(containing: choice.executable)
                .flatMap { SageNodeLocator.bundleVersion(at: $0) }
            guard Self.supportsCompanionBootstrap(version: version) else {
                return .vendoredNodeTooOld(version: version ?? "unknown")
            }
        }

        let process = Process()
        process.executableURL = choice.executable
        process.arguments = ["serve"]
        // Pipes rather than inheriting our stdio: a node writing to a closed
        // parent handle takes a SIGPIPE, and an unread inherited pipe fills and
        // blocks the node's logger.
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        if bootstrap {
            // **Key check first, then install.** `vendoredBootstrapEnvironment`
            // names `appliance-agent.key` as the companion identity to write
            // into genesis, and until this call that file did not exist yet on
            // a fresh machine — it was created lazily by the first `sage-gui
            // mcp` call, long after genesis had been sealed. So the appliance
            // ended up signing with a key its own chain had never seen,
            // self-registered, and sat in `pending_review` while every call was
            // refused.
            //
            // Genesis is the only chance: SAGE declines to retrofit companion
            // standing onto an existing chain, as the environment builder below
            // says at length. Preparing the key here — back up, adopt, mint —
            // is what makes the path in that environment point at a real public
            // key at the moment it is read.
            MynahIdentity.prepareApplianceKey(
                homeDirectory: homeDirectory,
                log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            )
            process.environment = ProcessInfo.processInfo.environment.merging(
                Self.vendoredBootstrapEnvironment(homeDirectory: homeDirectory)
            ) { _, managed in managed }
        }

        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.stateLock.lock()
            if self.serveProcess === finished { self.serveProcess = nil }
            self.stateLock.unlock()
        }

        do {
            try process.run()
        } catch {
            return .failed("Could not start the SAGE node automatically: \(error.localizedDescription)")
        }

        stateLock.lock()
        serveProcess = process
        stateLock.unlock()
        return .started(executablePath: choice.executable.path, bootstrapped: bootstrap)
    }

    /// `startIfNeeded` plus QuietType's settle delay, so the next request meets
    /// a bound port rather than the same connection refusal.
    @discardableResult
    public func startAndSettle(
        choice: SageNodeChoice? = SageNodeChoice.resolve(
            vendored: SageNodeLocator.vendoredExecutableURL()
        ),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) async -> Outcome {
        let outcome = startIfNeeded(
            choice: choice,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        switch outcome {
        case .started, .openedApplication:
            try? await Task.sleep(nanoseconds: Self.settleNanoseconds)
        case .alreadyRunning, .noNodeAvailable, .vendoredNodeTooOld, .cooledDown, .failed:
            break
        }
        return outcome
    }

    /// Stops a node this supervisor started. A node it did not start is left
    /// alone — the owner's SAGE is not ours to stop.
    public func stop() {
        stateLock.lock()
        let process = serveProcess
        serveProcess = nil
        stateLock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    // MARK: - The first-party companion contract

    /// The three variables that make a fresh node's first memory possible.
    ///
    /// Read by `sage-gui serve` at genesis only (`applyEnvOverrides` in
    /// `cmd/sage-gui/config.go`, consumed by `genesisAppStateForVendoredAgent`
    /// in `cmd/sage-gui/node.go`). They dual-sign a chain-bound bootstrap with
    /// the Root and appliance keys and enrol Mynah directly at app-v23 as
    /// Companion, owning its home domain from block 1.
    ///
    /// Without them a fresh node stamps any self-registering key with SAGE's
    /// fail-closed mask — writes to shared domains denied, claiming a domain
    /// denied, writing anyone else's domain denied — and the only remedy is an
    /// administrator in CEREBRUM, which a new owner does not have and cannot be
    /// asked to find. That is the orange card on a machine with nobody to ask.
    ///
    /// **Genesis-time and not repairable.** SAGE refuses to retrofit this onto
    /// an existing chain by design ("automatic legacy repair is not
    /// supported"), so this must be right on the run that creates the node.
    ///
    /// The values are the ones SAGE's own fixture uses for Mynah
    /// (`cmd/sage-gui/appv23_vendored_bootstrap_test.go`).
    public static func vendoredBootstrapEnvironment(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        [
            // The appliance's own stable key — deliberately NOT the node
            // operator key. Genesis refuses to let Root and companion be the
            // same file, which is `MynahIdentity`'s own rule enforced a layer
            // down.
            "SAGE_VENDORED_AGENT_KEY_FILE":
                MynahIdentity.applianceKeyURL(homeDirectory: homeDirectory).path,
            // Must match what the appliance actually writes to. A mismatch
            // fails the silent way: writes refused, nothing said.
            "SAGE_VENDORED_AGENT_HOME_DOMAIN": SageRitual.memoryDomain,
            // Maximum classification Mynah may read. Cannot promote it beyond
            // Member/Companion — SAGE fixes the profile and the capability mask
            // regardless of what is passed here.
            "SAGE_VENDORED_AGENT_CLEARANCE": "2"
        ]
    }
}
