import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import OSLog
import SageVoiceCore
import SwiftUI

// MARK: - Words the owner reads
//
// The helper this screen installs and drives is `signal-cli`. That name never
// appears in the UI, and neither does "daemon", "JSON-RPC", "socket", "Java" or
// an exit code. The owner is linking their phone; everything else is plumbing
// they did not buy.

private enum LinkCopy {

    /// What the helper is, in one sentence with no jargon in it.
    ///
    /// Deliberately does not say "command line", "CLI", "open source" or
    /// "Java" — none of those tell the owner anything they can act on.
    static let helperExplanation =
        "Mynah needs one small free add-on on this Mac before it can send and "
        + "receive Signal messages. It only handles messages; it can't see "
        + "anything else on your Mac."

    /// Said once, on the stage, before the clock starts.
    static let clockWarning =
        "The square below only works for about a minute, so have Signal open on "
        + "your phone before you ask for it."

    static let noHistoryNote =
        "Mynah won't see anything you sent before now — only what you send from here on."

    /// The other thing a linked phone can do, said on the one screen where
    /// somebody has just linked one.
    ///
    /// It was missing entirely. Every string about the phone said "voice
    /// notes", so an owner finished setup believing the product was a
    /// message-and-reply appliance — while the more impressive half, a live
    /// conversation they can interrupt mid-sentence, sat behind a command
    /// nothing told them about. `//help` in the thread lists it, which is no
    /// use to somebody who does not know there is anything to list.
    ///
    /// **What linking a phone actually buys, which is the owner's framing.**
    ///
    /// *"this just needs to be disclosed to the user of why link your signal —
    /// send voice notes, or call it directly and talk to it"*. So this is the
    /// two things, said plainly, on the screen where somebody is deciding
    /// whether to link at all.
    ///
    /// Both conditions that used to qualify this are gone. The model gate went
    /// when a brain on this Mac stopped being slow, and the credential gate went
    /// when `CallEnrolment` started minting one — which happens on this very
    /// screen, the moment the phone links.
    ///
    /// **The third sentence is the disclosure and it is not padding.** The call
    /// does not go through Signal, and an owner who linked a private messenger
    /// is owed that. What a relay is for, and what it does not get, in the two
    /// facts that decide whether somebody minds: it introduces the two ends
    /// because a Mac at home has no address the phone can dial, and the audio
    /// never passes through it — that is sealed between the phone and this Mac
    /// and is not available to the relay even in principle.
    static let callingNote =
        "You can also talk to it out loud: send \(CallInvitation.command) to yourself and tap the "
        + "link it sends back — you can interrupt it mid-sentence. A call is introduced by "
        + "call.sage.delivery, because this Mac has no address your phone can dial; what you "
        + "say goes straight between the two and never through it."
}

// MARK: - Finding and reading what is on this Mac

/// Where the pieces live, and what state they are in.
///
/// Nothing here launches anything or writes anything: it is all
/// `isExecutableFile` and one small JSON read, so it is safe to run on every
/// appearance of the stage.
enum SignalTooling {

    /// The one directory signal-cli keeps long-term Signal keys in. Derived from
    /// `SignalAttachmentLocator` rather than re-spelling `~/.local/share/…` so
    /// the two cannot drift apart when `XDG_DATA_HOME` is set.
    static var dataDirectory: URL {
        SignalAttachmentLocator.defaultAttachmentsDirectory().deletingLastPathComponent()
    }

    static var socketPath: String {
        switch SignalEndpoint.defaultUnixSocket() {
        case .unixSocket(let path): return path
        case .tcp(let host, let port): return "\(host):\(port)"
        }
    }

    /// Homebrew installs it to `/opt/homebrew/bin` on Apple silicon and
    /// `/usr/local/bin` on Intel. `PATH` is checked first, but a GUI-launched app
    /// inherits a minimal one, so the absolute locations are what usually hit.
    static func helper(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "signal-cli"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return ExecutableLookup.find(
            names: ["signal-cli"],
            extraCandidates: [
                URL(fileURLWithPath: "/opt/homebrew/bin/signal-cli"),
                URL(fileURLWithPath: "/usr/local/bin/signal-cli"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/signal-cli")
            ],
            environment: environment,
            fileManager: fileManager
        )
    }

    static func homebrew(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        ExecutableLookup.find(
            names: ["brew"],
            extraCandidates: [
                URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                URL(fileURLWithPath: "/usr/local/bin/brew")
            ],
            environment: environment,
            fileManager: fileManager
        )
    }

    /// True when a phone has already been linked on this Mac.
    ///
    /// Presence only — the file beside it holds the account's long-term keys and
    /// is never read.
    static func hasLinkedAccount(fileManager: FileManager = .default) -> Bool {
        accounts(fileManager: fileManager).isEmpty == false
    }

    /// The owner's own number, for the "you're linked" line. Their number on
    /// their Mac, so it is shown in full rather than redacted.
    static func linkedNumber(fileManager: FileManager = .default) -> String? {
        for entry in accounts(fileManager: fileManager) {
            if let number = entry["number"] as? String, !number.isEmpty {
                return number
            }
        }
        return nil
    }

    private static func accounts(fileManager: FileManager) -> [[String: Any]] {
        let url = dataDirectory.appendingPathComponent("data/accounts.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["accounts"] as? [[String: Any]] else {
            return []
        }
        return list
    }

    /// The line a Mac-literate owner can paste. Never shown as the first answer.
    static let manualInstallCommand = "brew install signal-cli"
}

// MARK: - Running the helper

/// One child process, with its output streamed a line at a time.
///
/// `ProbeCommandRunner` cannot be reused here: it waits for the process to
/// finish and hands back the whole buffer, and `signal-cli link` prints the code
/// and *then blocks for a minute* waiting for the phone. The code has to reach
/// the screen while the process is still alive, so this reads incrementally.
final class SignalLinkSession: @unchecked Sendable {

    enum Event: Sendable {
        /// The `sgnl://linkdevice?…` URI, the moment it appears.
        case code(String)
        case finished(exitCode: Int32, transcript: String)
    }

    /// Enough to classify a failure; not enough for a runaway child to hold
    /// megabytes of log spew in the app's address space.
    private static let transcriptLimit = 16 * 1024

    private let process = Process()
    private let lock = NSLock()
    private var transcript = ""
    private var pendingLine = ""
    private var didYieldCode = false

    /// - Returns: `nil` when the binary could not be launched at all. A process
    ///   that launched and then failed still produces a `.finished` event.
    static func start(
        executable: URL,
        arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) -> (SignalLinkSession, AsyncStream<Event>)? {
        let session = SignalLinkSession()
        var continuation: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { continuation = $0 }
        guard session.launch(
            executable: executable,
            arguments: arguments,
            extraEnvironment: extraEnvironment,
            continuation: continuation
        ) else {
            continuation.finish()
            return nil
        }
        return (session, stream)
    }

    /// Stops the child. Safe to call after it has already exited.
    func cancel() {
        guard process.isRunning else { return }
        process.terminate()
        // `terminate()` is SIGTERM and is ignorable. A helper that is wedged
        // holding a socket open would otherwise sit there for the rest of the
        // session, and the next code request would fight it for the account
        // directory.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.process.isRunning, pid > 0 else { return }
            kill(pid, SIGKILL)
        }
    }

    private func launch(
        executable: URL,
        arguments: [String],
        extraEnvironment: [String: String],
        continuation: AsyncStream<Event>.Continuation
    ) -> Bool {
        process.executableURL = executable
        process.arguments = arguments
        // EOF rather than a terminal: a helper that decides to ask a question
        // gets an answer it can act on instead of blocking until the owner gives
        // up on the whole product.
        process.standardInput = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        // A double-clicked app inherits `/usr/bin:/bin:/usr/sbin:/sbin`, which
        // contains neither Homebrew prefix, so a child that shells out to
        // anything of its own would not find it.
        environment["PATH"] = Self.enriched(path: environment["PATH"])
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData, continuation: continuation)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData, continuation: continuation)
        }
        process.standardOutput = output
        process.standardError = errors

        process.terminationHandler = { [weak self] finished in
            // The readability handlers fire on their own queue and can still have
            // the last chunk in flight when the process is reaped. Without this
            // pause the failure classifier sees an empty transcript and reports
            // "something went wrong" for a case it could have named.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                try? output.fileHandleForReading.close()
                try? errors.fileHandleForReading.close()
                continuation.yield(
                    .finished(exitCode: finished.terminationStatus, transcript: self?.snapshot() ?? "")
                )
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            return false
        }
        return true
    }

    private func ingest(_ data: Data, continuation: AsyncStream<Event>.Continuation) {
        guard !data.isEmpty else { return }
        let chunk = String(decoding: data, as: UTF8.self)

        var found: String?
        lock.lock()
        if transcript.count < Self.transcriptLimit { transcript += chunk }
        pendingLine += chunk
        while let newline = pendingLine.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(pendingLine[pendingLine.startIndex..<newline])
            pendingLine = String(pendingLine[pendingLine.index(after: newline)...])
            if !didYieldCode, let uri = Self.linkURI(in: line) {
                didYieldCode = true
                found = uri
            }
        }
        // The helper prints the URI and then blocks, so the last line can sit in
        // the buffer with no newline behind it for the whole minute. Waiting for
        // one would show the owner an empty square until the code had already
        // expired — which is exactly how a linking attempt gets lost.
        if !didYieldCode, let uri = Self.linkURI(in: pendingLine) {
            didYieldCode = true
            found = uri
        }
        lock.unlock()

        if let found { continuation.yield(.code(found)) }
    }

    private func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return transcript
    }

    /// Pulls the URI out of a line of output.
    ///
    /// Both parameters must be present before this returns anything: a chunk can
    /// land mid-URI, and rendering a half-written code produces a square that
    /// scans cleanly and then fails, which is indistinguishable from a Signal
    /// problem from the owner's side.
    static func linkURI(in text: String) -> String? {
        guard let start = text.range(of: "sgnl://linkdevice") else { return nil }
        let candidate = text[start.lowerBound...].prefix { !$0.isWhitespace }
        guard candidate.contains("uuid="), candidate.contains("pub_key=") else { return nil }
        return String(candidate)
    }

    private static func enriched(path: String?) -> String {
        var parts = (path ?? "").split(separator: ":").map(String.init)
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        where !parts.contains(prefix) {
            parts.append(prefix)
        }
        return parts.joined(separator: ":")
    }
}

// MARK: - Failures the owner can act on

/// Every failure this screen can end in, translated once.
///
/// The raw output goes to `Logger`; what reaches a `Text` is authored copy with
/// a verb in it. There is no case that renders an exit code, a stack trace or a
/// host name.
enum SignalLinkFailure: Equatable, Sendable {
    /// Signal caps how many devices an account can have linked at once.
    case tooManyDevices
    /// The Mac could not reach Signal at all.
    case offline
    /// A phone is already linked and the helper refused to link a second time.
    case alreadyLinked
    /// The copy on this Mac needs something it hasn't got — in practice an old
    /// build that wants a Java runtime this appliance deliberately does not ship.
    case helperUnusable
    /// `brew install` did not finish.
    case installFailed
    /// The helper could not be started at all.
    case helperWouldNotStart
    /// It ended without linking and without saying anything we recognise.
    case didNotFinish

    var tone: InlineBanner.Tone {
        switch self {
        case .alreadyLinked: return .info
        case .tooManyDevices, .helperUnusable, .installFailed: return .info
        case .offline, .helperWouldNotStart, .didNotFinish: return .critical
        }
    }

    var headline: String {
        switch self {
        case .tooManyDevices: return "Signal says you already have too many devices."
        case .offline: return "This Mac couldn't reach Signal."
        case .alreadyLinked: return "A phone is already linked."
        case .helperUnusable: return "The add-on on this Mac is the wrong version."
        case .installFailed: return "Mynah couldn't add the Signal add-on."
        case .helperWouldNotStart: return "The Signal add-on wouldn't start."
        case .didNotFinish: return "That didn't finish."
        }
    }

    var explanation: String {
        switch self {
        case .tooManyDevices:
            return "On your phone, open Signal, go to Linked Devices, and remove one "
                + "you don't use any more. Then ask for a new square here."
        case .offline:
            return "Check this Mac is on Wi-Fi, then ask for a new square."
        case .alreadyLinked:
            return "Mynah is already talking to a phone. Carry on — or unlink Mynah "
                + "from Linked Devices on that phone first if you want to use a different one."
        case .helperUnusable:
            return "Mynah can replace it with the version it needs. That takes a few minutes "
                + "and doesn't need anything from you."
        case .installFailed:
            return "You can carry on without your phone and set this up later from Settings."
        case .helperWouldNotStart:
            return "Try once more. If it still won't start, carry on without your phone — "
                + "everything works here on the Mac."
        case .didNotFinish:
            return "The square expires after about a minute, so it often just needs a second "
                + "go with Signal already open on your phone."
        }
    }

    /// The button under the note. Every failure has one, and every one leads
    /// somewhere the owner can see happen — there is no dead end in this enum.
    var recoveryTitle: String {
        switch self {
        case .tooManyDevices, .offline, .didNotFinish, .helperWouldNotStart:
            return "Show a new square"
        case .helperUnusable:
            return "Replace it"
        case .alreadyLinked:
            return "Continue"
        case .installFailed:
            return "Continue without my phone"
        }
    }

    /// Whether that button tries again, or moves the owner past it.
    var isRetryable: Bool {
        switch self {
        case .tooManyDevices, .offline, .didNotFinish, .helperWouldNotStart, .helperUnusable:
            return true
        case .alreadyLinked, .installFailed:
            return false
        }
    }

    /// Classified from what the helper printed. Kept here rather than in the view
    /// so no screen invents its own reading of the same string.
    static func classify(exitCode: Int32, transcript: String) -> SignalLinkFailure {
        let text = transcript.lowercased()
        if text.contains("already exists") || text.contains("already registered") {
            return .alreadyLinked
        }
        if text.contains("java runtime") || text.contains("java_home")
            || text.contains("unsupported class file") || text.contains("class file version") {
            return .helperUnusable
        }
        if text.contains("unknownhost") || text.contains("unknown host")
            || text.contains("network is unreachable") || text.contains("no route to host")
            || text.contains("connection refused") || text.contains("sockettimeout")
            || text.contains("connect timed out") {
            return .offline
        }
        if text.contains("too many") || text.contains("device limit")
            || text.contains("limit reached") || text.contains("maximum number of devices") {
            return .tooManyDevices
        }
        return .didNotFinish
    }
}

// MARK: - Timing

/// Facts about how long a linking code lives.
///
/// Outside the model because they are facts about Signal rather than state, and
/// a value type's computed property cannot read a `@MainActor` static.
enum SignalLinkTiming {

    /// Measured on this machine: the code the helper prints stops being accepted
    /// about 62 seconds after it is issued. Three real linking attempts were lost
    /// to a screen that showed a dead square with nothing saying so.
    static let codeLifetime: TimeInterval = 62

    /// How much of a code's life has to be left before it is worth pointing a
    /// camera at. Under this, "ask for a new one" is the honest advice.
    static let uselessRemainder: Int = 6
}

// MARK: - Model

/// Everything the linking screen knows, and the only thing that talks to the
/// helper.
///
/// The phase is state on this object and is advanced explicitly. Nothing here is
/// derived from what happens to be installed at render time, so a background
/// check finishing cannot throw the owner backwards while they are holding their
/// phone up to the screen.
@MainActor
@Observable
final class SignalLinkModel {

    enum HelperGap: Equatable, Sendable {
        /// Homebrew is on this Mac, so Mynah can add it with one button.
        case mynahCanInstall
        /// Nothing here can install it without the owner opening Terminal.
        case needsTheOwner
    }

    struct LinkCode: Equatable, Sendable {
        let uri: String
        let issued: Date

        var expiry: Date { issued.addingTimeInterval(SignalLinkTiming.codeLifetime) }
    }

    enum Phase: Equatable {
        /// Looking at what is on this Mac. Sub-second; never a screen the owner
        /// watches.
        case checking
        case missingHelper(HelperGap)
        case installing
        /// Helper present, no code asked for yet.
        case ready
        /// Helper launched, code not printed yet.
        case requesting
        case waiting(LinkCode)
        /// Carries the code it *was*, so the square stays on screen and visibly
        /// dies. A square that simply vanishes reads as a crash; a dead one
        /// beside "that has expired" reads as a fact the owner can act on.
        case expired(LinkCode)
        case linked(number: String?)
        case failed(SignalLinkFailure)

        var isLinked: Bool {
            if case .linked = self { return true }
            return false
        }

        /// True while a child process is alive on our behalf.
        var isBusy: Bool {
            switch self {
            case .installing, .requesting, .waiting: return true
            case .checking, .missingHelper, .ready, .expired, .linked, .failed: return false
            }
        }
    }

    /// **The one place still on `os_log`, and deliberately.**
    ///
    /// Everything else in the app moved to `MynahLog`, which mirrors to a file
    /// so a diagnostic can be read back tomorrow rather than only while
    /// somebody watches. This screen cannot: the two lines below carry
    /// `signal-cli`'s own output, and a link transcript contains the
    /// device-linking URI — the secret that pairs a phone. `os_log` redacts
    /// `privacy: .private`; a plaintext file in `~/Library/Logs` does not.
    ///
    /// So this loses after-the-fact readability on purpose, in the one place
    /// where the alternative is writing a pairing secret to disk.
    private static let log = Logger(subsystem: "com.sage.mynah", category: "phone-link")
    /// Enrolment happens once and silently. Whether it worked has to be legible
    /// afterwards, which on this Mac means a file — see the note in `phase`.
    private static let calls = MynahLog(category: "calls")
    /// The model download is minutes long and nobody is watching it, so it
    /// reports at deciles: enough to tell a stalled transfer from a slow one,
    /// without writing a line per packet into a file somebody has to read.
    private static let voice = DownloadMilestones(category: "voice")

    /// Homebrew's own downloads are the slow part; past this it is wedged, not
    /// working.
    private static let installDeadline: TimeInterval = 15 * 60

    private(set) var phase: Phase = .checking {
        didSet {
            // **Calling turns itself on when a phone is linked.**
            //
            // The owner's decision, and it follows from the measurement: a brain
            // running on this Mac now answers in single-digit seconds, so the
            // reason calling was ever held back is gone. What was left standing
            // in the way was a credential a person had to add by hand to the
            // relay host — invisible to the owner and impossible for them to
            // fix. `CallEnrolment` mints one.
            //
            // Here rather than at the scan, because both paths that produce a
            // linked phone run through this property: a fresh pairing and a
            // restored link found on a Mac that was already set up. Somebody who
            // linked before this shipped enrols the next time they open the
            // screen rather than being left behind by the version they upgraded
            // from.
            //
            // Detached and unawaited on purpose. Enrolment is an extra reached
            // by having linked a phone; linking must never wait on it, and must
            // never fail because a relay did not answer. `enrolIfNeeded` returns
            // an outcome rather than throwing for the same reason, and is
            // idempotent, so the repeat calls this invites cost one file check.
            //
            // `MynahLog` rather than `Logger`, and that distinction was earned
            // this morning: `os_log` on this Mac emits and forgets — `log
            // stream` sees a line and `log show` cannot retrieve it at any
            // level. A one-shot outcome nobody can read afterwards is the same
            // as no outcome, and this is precisely the kind of thing somebody
            // will need to check after the fact.
            guard phase.isLinked, !oldValue.isLinked else { return }
            // Awaited into a value first: `MynahLog`'s message is an autoclosure
            // that is evaluated synchronously at the log site, so an `await`
            // inside the argument does not compile.
            Task {
                let outcome = await CallEnrolment.enrolIfNeeded()
                Self.calls.info(outcome.logLine)
            }

            // **The voice arrives the same way the credential does.**
            //
            // 353 MB of model weights are not in the DMG, and the reason is
            // signing rather than size: code downloaded after installation is
            // unsigned and quarantined, where model weights are opaque data that
            // Gatekeeper has no opinion about. So the runtime ships inside the
            // signed bundle and the weights are fetched here.
            //
            // The owner chose this trigger: *"the signal part //call only comes
            // in once you link signal - download it then"*. Someone who links a
            // phone is someone who is about to be spoken to.
            //
            // A separate task from enrolment rather than a step after it. They
            // are independent, and enrolment is one round trip where this is
            // several minutes — chaining them would hold a credential the owner
            // could already be using behind a download they cannot hear yet.
            Task {
                // Read out of main-actor isolation once, here, rather than from
                // inside the progress callback — that closure is `@Sendable` and
                // escapes to a URLSession delegate on another thread, where a
                // main-actor property is not reachable. `DownloadMilestones`
                // carries its own lock precisely so it can be handed over.
                let voice = Self.voice
                let outcome = await KokoroAssets.installIfNeeded(
                    progress: { voice.milestone($0) }
                )
                voice.info(outcome.logLine)
            }
        }
    }
    /// Whole seconds left on the code on screen. Zero in every other phase.
    private(set) var secondsRemaining: Int = 0

    private var session: SignalLinkSession?
    private var pump: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    // MARK: Reading the machine

    /// Safe to call on every appearance: it launches nothing.
    func refresh() {
        // A code already on screen outranks a re-check. Otherwise coming back
        // from another app would silently reset the clock the owner is racing.
        guard !phase.isBusy else { return }

        if SignalTooling.hasLinkedAccount() {
            phase = .linked(number: SignalTooling.linkedNumber())
            return
        }
        guard SignalTooling.helper() != nil else {
            phase = .missingHelper(SignalTooling.homebrew() == nil ? .needsTheOwner : .mynahCanInstall)
            return
        }
        phase = .ready
    }

    /// Gets all plumbing out of the way before asking the owner for anything.
    ///
    /// With Homebrew already on the Mac, entering this screen either restores
    /// the existing link or proceeds directly to a live QR code. The scan is
    /// the one interaction Signal's cryptographic pairing genuinely requires.
    func prepareForScan() {
        refresh()
        switch phase {
        case .missingHelper(.mynahCanInstall):
            installHelper()
        case .ready:
            requestCode()
        default:
            break
        }
    }

    /// Drops any child process and stops the clock. Called when the stage goes
    /// away — a helper left blocking on a socket would fight the next attempt for
    /// the account directory.
    func stop() {
        pump?.cancel()
        pump = nil
        ticker?.cancel()
        ticker = nil
        session?.cancel()
        session = nil
        secondsRemaining = 0

        // Killing the helper kills whatever it was doing, so the phase has to
        // stop claiming otherwise. Leaving `.waiting` in place means coming back
        // to this screen shows a frozen clock over a square nothing is listening
        // for — the precise failure this whole screen exists to prevent. The
        // in-flight phases are the only ones that go stale; a finished one is
        // still true.
        switch phase {
        case .waiting(let code): phase = .expired(code)
        case .requesting: phase = .ready
        case .installing: phase = .checking
        default: break
        }
    }

    // MARK: Adding the helper

    func installHelper() {
        guard let brew = SignalTooling.homebrew() else {
            phase = .missingHelper(.needsTheOwner)
            return
        }
        stop()
        phase = .installing

        guard let (session, events) = SignalLinkSession.start(
            executable: brew,
            arguments: ["install", "signal-cli"],
            // Homebrew asks questions and prints hints when it thinks a human is
            // watching. Nobody is: this runs behind a screen that says
            // "installing" and has no way to answer.
            extraEnvironment: ["NONINTERACTIVE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
        ) else {
            phase = .failed(.installFailed)
            return
        }
        self.session = session

        pump = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                guard case .finished(let exitCode, let transcript) = event else { continue }
                Self.log.debug("brew install signal-cli exited \(exitCode)")
                Self.log.debug("brew output: \(transcript, privacy: .private)")
                // Trust the filesystem, not the exit code: a formula that was
                // already installed can exit non-zero with "already installed",
                // and that is a success from where the owner is sitting.
                self.session = nil
                if SignalTooling.helper() == nil {
                    self.phase = .failed(.installFailed)
                } else {
                    self.phase = .ready
                    self.requestCode()
                }
            }
        }

        // Nothing about Homebrew is bounded, and a screen that says "installing"
        // forever is worse than one that says it did not work.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.installDeadline * 1_000_000_000))
            guard let self, case .installing = self.phase else { return }
            self.stop()
            self.phase = .failed(.installFailed)
        }
    }

    // MARK: Asking for a code

    /// The one button behind both "show me the square" and "show me a new one".
    func requestCode() {
        guard let helper = SignalTooling.helper() else {
            phase = .missingHelper(SignalTooling.homebrew() == nil ? .needsTheOwner : .mynahCanInstall)
            return
        }
        stop()
        phase = .requesting

        // The directory about to receive the account's long-term Signal keys.
        // Same treatment as the owner's transcripts and API keys: 0700, before
        // anything is written into it rather than after.
        try? OwnerOnlyFileSecurity.prepareDirectory(SignalTooling.dataDirectory)

        guard let (session, events) = SignalLinkSession.start(
            executable: helper,
            // The name the owner will see in Signal's own Linked Devices list.
            arguments: ["link", "-n", "Mynah"]
        ) else {
            phase = .failed(.helperWouldNotStart)
            return
        }
        self.session = session

        pump = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .code(let uri):
                    let code = LinkCode(uri: uri, issued: Date())
                    self.phase = .waiting(code)
                    self.startCountdown(until: code.expiry)

                case .finished(let exitCode, let transcript):
                    self.ticker?.cancel()
                    self.ticker = nil
                    self.session = nil
                    self.secondsRemaining = 0

                    if exitCode == 0 {
                        // The helper writes the account and then exits, but the
                        // write and the exit are not one atomic act. Reading a
                        // beat too early and calling a successful link a failure
                        // would send the owner round the whole minute again for
                        // no reason.
                        if !SignalTooling.hasLinkedAccount() {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                        if SignalTooling.hasLinkedAccount() {
                            Self.log.debug("phone linked")
                            self.phase = .linked(number: SignalTooling.linkedNumber())
                            continue
                        }
                    }

                    let failure = SignalLinkFailure.classify(exitCode: exitCode, transcript: transcript)
                    Self.log.error("link ended \(exitCode) as \(String(describing: failure))")
                    // The output can still hold a live linking URI, which is a
                    // credential: whoever has it can link a device to the
                    // owner's Signal. It never leaves the private log store.
                    Self.log.debug("link output: \(transcript, privacy: .private)")
                    self.phase = .failed(failure)
                }
            }
        }
    }

    /// What the failure note's button does, so the view never has to decide.
    func recover(from failure: SignalLinkFailure) {
        switch failure {
        case .helperUnusable:
            installHelper()
        case .tooManyDevices, .offline, .didNotFinish, .helperWouldNotStart:
            requestCode()
        case .alreadyLinked, .installFailed:
            break
        }
    }

    // MARK: The clock

    private func startCountdown(until expiry: Date) {
        ticker?.cancel()
        secondsRemaining = Int(expiry.timeIntervalSinceNow.rounded(.up))
        ticker = Task { [weak self] in
            // Quarter-second polling so the number changes on the second
            // boundary rather than up to a second late. A countdown that lags is
            // read as a countdown that lies.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                let remaining = Int(expiry.timeIntervalSinceNow.rounded(.up))
                self.secondsRemaining = max(0, remaining)
                if remaining <= 0 {
                    self.expire()
                    return
                }
            }
        }
    }

    private func expire() {
        guard case .waiting(let code) = phase else { return }
        // Kill the helper as well as changing the screen. Leaving it blocking on
        // a dead code means the next request races it for the account directory,
        // and the second attempt fails for a reason the first one caused.
        pump?.cancel()
        pump = nil
        session?.cancel()
        session = nil
        ticker = nil
        secondsRemaining = 0
        phase = .expired(code)
    }
}

// MARK: - QR rendering

/// Turns the linking URI into a square, with CoreImage and nothing else.
///
/// Internal rather than private since 2.0.0: WhatsApp is linked by QR too, and
/// a second renderer would be a second set of decisions about correction level
/// and scaling for the same phone camera at the same arm's length.
enum LinkCodeRenderer {

    /// `CIContext` is expensive to build and safe to share; one per app rather
    /// than one per code.
    private static let context = CIContext()

    /// - Parameter targetPixels: the bitmap is generated at least this wide so
    ///   the modules stay hard-edged when SwiftUI scales it down.
    static func image(for uri: String, targetPixels: CGFloat = 720) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)
        // Medium recovery. Higher levels make the modules smaller for the same
        // square, which is worse on a phone camera at arm's length — and the
        // screen is not a surface that gets scratched.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (targetPixels / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// The square itself.
///
/// Black modules on a white tile in both appearances. This is the one place in
/// Mynah where a literal white is right and a surface token would be wrong: it
/// is a scan target, not a surface, and an inverted code is a code some phones
/// quietly refuse.
struct LinkCodeSquare: View {
    let uri: String
    var isSpent: Bool = false
    /// Which app the owner is meant to point at it. Only VoiceOver reads this,
    /// which is exactly why it must not keep saying Signal on the WhatsApp
    /// screen — the one owner who cannot see which sheet they are on is the one
    /// being told the wrong thing.
    var appName: String = "Signal"

    @State private var rendered: NSImage?

    private static let side: CGFloat = 216
    private static let quietZone: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle.mynah(r.card).fill(Color.white)
            if let rendered {
                Image(nsImage: rendered)
                    .resizable()
                    // Nearest-neighbour, and no antialiasing: a smoothed module
                    // edge is a module a camera has to guess at.
                    .interpolation(.none)
                    .antialiased(false)
                    .frame(width: Self.side, height: Self.side)
                    .padding(Self.quietZone)
            }
        }
        .frame(width: Self.side + Self.quietZone * 2, height: Self.side + Self.quietZone * 2)
        .mynahBorder(r.card)
        .opacity(isSpent ? 0.16 : 1)
        .mynahAnimation(Motion.fade, value: isSpent)
        .task(id: uri) { rendered = LinkCodeRenderer.image(for: uri) }
        .accessibilityLabel("The linking square. Point \(appName)'s camera at it.")
        .accessibilityHidden(rendered == nil)
    }
}

/// What sits where the square goes before the owner has asked for one, and while
/// the helper is starting.
struct LinkCodePlaceholder<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        RoundedRectangle.mynah(r.card)
            .fill(Palette.surface.sunken)
            .frame(width: 252, height: 252)
            .mynahBorder(r.card)
            .overlay { content }
    }
}

// MARK: - The stage

/// Linking the owner's phone.
///
/// Skippable on purpose and at every step: the desktop app answers perfectly
/// well without a phone, and a required link would stop everyone who only wants
/// to talk at their desk.
struct SignalLinkStage: View {
    let titles: [String]
    let currentIndex: Int
    /// Optional so the stage can be previewed and embedded outside the flow. When
    /// present, skipping registers a row in Settings rather than vanishing.
    var app: AppModel?
    var onBack: (() -> Void)?
    let onFinished: () -> Void

    @State private var model = SignalLinkModel()

    var body: some View {
        StageShell(
            stageTitles: titles,
            currentIndex: currentIndex,
            glyph: StageIllustration.mark(.phone),
            title: title,
            subtitle: subtitle
        ) {
            SignalLinkView(model: model)
        } actions: {
            ActionRow(
                quietTitle: onBack == nil ? nil : "Back",
                quietAction: onBack,
                helper: helper
            ) {
                HStack(spacing: s4) {
                    if showsSkip {
                        MynahButton("Not now", kind: .secondary) { skip() }
                    }
                    MynahButton(
                        primaryTitle,
                        isEnabled: isPrimaryEnabled,
                        isDefault: true,
                        action: primaryAction
                    )
                }
            }
        }
        .onDisappear { model.stop() }
    }

    // MARK: Copy

    private var title: String {
        model.phase.isLinked ? "Your phone is linked." : "Talk to Mynah from your phone."
    }

    private var subtitle: String? {
        switch model.phase {
        case .linked:
            // Both things a linked phone can now do, in the order somebody will
            // try them: a note first, because it needs nothing explained, then
            // the call.
            return "Send yourself a voice note in Signal and Mynah will answer it. "
                + LinkCopy.callingNote + " " + LinkCopy.noHistoryNote
        case .missingHelper:
            return LinkCopy.helperExplanation
        default:
            // Was "listens to the voice notes you send yourself", which is
            // narrower than the truth and sets the wrong expectation on the one
            // screen that teaches the owner how to use the thing: the thread
            // takes typing too, and most owners will type first and speak later.
            return "Mynah reads the Signal thread you send to yourself, and answers in it. "
                + "Speak or type, either works. Linking your phone is what lets it — and "
                + "you can skip this and do it later."
        }
    }

    /// The reason a disabled primary is disabled, or the reassurance that makes
    /// skipping feel like a decision rather than a failure.
    private var helper: String? {
        switch model.phase {
        case .missingHelper(.needsTheOwner), .failed(.installFailed):
            return "Your phone can wait. Mynah works here without it."
        case .waiting:
            // Told before the scan fails rather than after: under six seconds
            // there is not enough left to open Signal, let alone aim a camera.
            return model.secondsRemaining <= SignalLinkTiming.uselessRemainder
                ? "Not enough time left — ask for a new one."
                : nil
        default:
            return nil
        }
    }

    /// Nothing to defer once a phone is linked, and nothing to defer when the
    /// failure on screen is "a phone is already linked".
    private var showsSkip: Bool {
        switch model.phase {
        case .linked, .failed(.alreadyLinked): return false
        default: return true
        }
    }

    private var primaryTitle: String {
        switch model.phase {
        case .checking, .requesting, .ready: return "Show me the square"
        case .missingHelper(.mynahCanInstall): return "Add it for me"
        case .missingHelper(.needsTheOwner): return "Continue without my phone"
        case .installing: return "Adding it…"
        case .waiting, .expired: return "Show a new square"
        case .linked: return "Continue"
        case .failed(let failure): return failure.recoveryTitle
        }
    }

    private var isPrimaryEnabled: Bool {
        switch model.phase {
        case .checking, .requesting, .installing: return false
        default: return true
        }
    }

    private func primaryAction() {
        switch model.phase {
        case .missingHelper(.mynahCanInstall):
            model.installHelper()
        case .missingHelper(.needsTheOwner):
            skip()
        case .ready, .waiting, .expired:
            model.requestCode()
        case .linked:
            finish()
        case .failed(let failure):
            if failure.isRetryable {
                model.recover(from: failure)
            } else if failure == .alreadyLinked {
                // Already linked is not a thing to come back and finish, so it
                // moves on without leaving a row in Settings.
                finish()
            } else {
                skip()
            }
        case .checking, .requesting, .installing:
            break
        }
    }

    /// Only reached with a phone actually linked, which is what makes clearing
    /// the reminder honest. `skip()` deliberately does not route through here —
    /// deferring and then resolving in the same breath would erase the row it
    /// just created.
    private func finish() {
        app?.resolveDeferredStep(id: AppModel.DeferredStep.phoneLinkID)
        model.stop()
        onFinished()
    }

    /// "Not now" has to lead somewhere the owner can find again, or it is a
    /// button that lies.
    private func skip() {
        app?.deferSetupStep(
            AppModel.DeferredStep(
                id: AppModel.DeferredStep.phoneLinkID,
                title: "Link your phone",
                // The deferred-step card is a one-liner in a list, so this
                // names the second capability without explaining it. Somebody
                // who comes back to finish linking reads the full version on
                // the screen itself.
                detail: "Mynah answers voice notes you send yourself in Signal, and can take a "
                    + "voice call."
            )
        )
        model.stop()
        onFinished()
    }
}

// MARK: - The screen itself

/// The body of the linking screen, without the stage chrome, so Settings can
/// present the same thing in a sheet.
struct SignalLinkView: View {
    // Not `@Bindable`: nothing on this screen writes into the model, and every
    // change reaches the body through `@Observable`'s read tracking anyway.
    let model: SignalLinkModel

    @State private var showsTrouble = false
    @State private var showsManualPath = false

    init(model: SignalLinkModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s6) {
            switch model.phase {
            case .checking:
                LinkCodePlaceholder { EmptyView() }
                    .frame(maxWidth: .infinity)

            case .missingHelper(let gap):
                missingHelper(gap)

            case .installing:
                installing

            case .ready, .requesting:
                codeColumn(uri: nil, isSpent: false)
                steps

            case .waiting(let code):
                codeColumn(uri: code.uri, isSpent: false)
                steps
                trouble(uri: code.uri)

            case .expired(let code):
                // The dead square stays put. Replacing it with an empty box in
                // the same moment the clock hits zero looks like the screen
                // broke rather than like the code did.
                codeColumn(uri: code.uri, isSpent: true)
                steps
                // No copyable link here on purpose: the one this held is dead,
                // and handing over a link that cannot work is how a person ends
                // up certain the fault is theirs.
                trouble(uri: nil)

            case .linked(let number):
                linked(number: number)

            case .failed(let failure):
                failed(failure)
            }
        }
        .frame(maxWidth: MynahWidth.stageColumn, alignment: .leading)
        .mynahAnimation(Motion.snap, value: model.phase)
        .task { model.prepareForScan() }
    }

    // MARK: The square and its clock

    @ViewBuilder
    private func codeColumn(uri: String?, isSpent: Bool) -> some View {
        VStack(spacing: s5) {
            ZStack {
                if let uri {
                    LinkCodeSquare(uri: uri, isSpent: isSpent)
                } else {
                    LinkCodePlaceholder {
                        if case .requesting = model.phase {
                            ThinkingIndicator()
                        } else {
                            HeroGlyph("iphone.gen3", tone: .quiet)
                        }
                    }
                }
            }
            clockLine
        }
        .frame(maxWidth: .infinity)
    }

    /// One line under the square, and the only place the accent appears on this
    /// screen.
    ///
    /// The seconds are `.bodyEmphasis` with fixed-width figures rather than the
    /// big `.numeral`: this is a real deadline and hiding it would cost the owner
    /// an attempt, but a 28pt number ticking down reads as a test they are
    /// failing.
    @ViewBuilder
    private var clockLine: some View {
        switch model.phase {
        case .waiting:
            HStack(spacing: s3) {
                StatusDot(.accent)
                Text("Waiting for your phone")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
                Text("·")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.quaternary)
                Text(Self.clock(model.secondsRemaining))
                    .mynahFont(.bodyEmphasis)
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink.secondary)
                    // The one number in the app that genuinely counts down, so it
                    // rolls the way a countdown rolls rather than cross-fading.
                    .contentTransition(.numericText(countsDown: true))
                    .mynahAnimation(Motion.fade, value: model.secondsRemaining)
                Text("left")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Waiting for your phone. \(model.secondsRemaining) seconds left.")

        case .expired:
            Text("That square has expired. They only last about a minute.")
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

        case .requesting:
            Text("Getting a square from Signal…")
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.secondary)

        default:
            Text(LinkCopy.clockWarning)
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MynahWidth.prose)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func clock(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    // MARK: Where "Linked devices" actually is

    private var steps: some View {
        MynahCard {
            VStack(alignment: .leading, spacing: s4) {
                Text("On your phone")
                    .mynahFont(.title2)
                    .foregroundStyle(Palette.ink.primary)
                StepList(steps: [
                    "Open Signal.",
                    "Tap your own photo in the top-left corner, then Linked Devices.",
                    "Tap Link New Device, then point your phone at the square above."
                ])
            }
        }
    }

    // MARK: Everything that goes wrong

    /// Behind a quiet toggle, because a list of things that might be broken
    /// sitting under a working screen makes a working screen look broken.
    @ViewBuilder
    private func trouble(uri: String?) -> some View {
        VStack(alignment: .leading, spacing: s4) {
            MynahButton(showsTrouble ? "Hide the checks" : "Nothing happening?", kind: .quiet) {
                showsTrouble.toggle()
            }
            .padding(.leading, -s3)

            if showsTrouble {
                MynahCard(density: .compact) {
                    VStack(alignment: .leading, spacing: s4) {
                        StepList(
                            numbered: false,
                            steps: [
                                "Use the camera inside Signal, not your phone's own Camera app — "
                                    + "the Camera app won't do anything with this square.",
                                "Your phone and this Mac both need to be online.",
                                "If Signal says you have too many devices, remove one you don't "
                                    + "use from Linked Devices first."
                            ]
                        )
                        // A square is no use to somebody who cannot see it. The
                        // same link works tapped, so it is here — behind a
                        // warning, because whoever opens it gets to link a
                        // device to the owner's Signal.
                        if let uri {
                            MynahDivider()
                            VStack(alignment: .leading, spacing: s3) {
                                Text("Can't scan it?")
                                    .mynahFont(.title3)
                                    .foregroundStyle(Palette.ink.primary)
                                Text("Copy the link instead and open it on the phone you want to "
                                    + "link. Anyone who opens it can link a device to your Signal, "
                                    + "so only ever send it to yourself.")
                                    .mynahFont(.callout)
                                    .foregroundStyle(Palette.ink.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                CopyField(value: uri, isSecret: true)
                            }
                        }
                    }
                }
            }
        }
        // The layout genuinely reflows, so it springs rather than fades.
        .mynahAnimation(Motion.snap, value: showsTrouble)
    }

    /// One note, no icon, no shake, no flash. It appears and it stays.
    private func failed(_ failure: SignalLinkFailure) -> some View {
        InlineBanner(
            tone: failure.tone,
            headline: failure.headline,
            explanation: failure.explanation
        )
    }

    // MARK: The add-on

    @ViewBuilder
    private func missingHelper(_ gap: SignalLinkModel.HelperGap) -> some View {
        VStack(alignment: .leading, spacing: s5) {
            switch gap {
            case .mynahCanInstall:
                InlineBanner(
                    headline: "Mynah can add it for you.",
                    explanation: "It takes two or three minutes and needs nothing from you. "
                        + "You can also skip this and link your phone later."
                )
            case .needsTheOwner:
                InlineBanner(
                    headline: "Mynah can't add it on this Mac by itself.",
                    explanation: "Nothing is broken — Mynah still works here on the Mac, and "
                        + "you can link your phone later from Settings."
                )
                manualPath
            }
        }
    }

    /// The escape hatch for an owner who does know their way around a Mac. It is
    /// deliberately not the first answer and deliberately not the primary button:
    /// a consumer app should not open by handing someone a shell command.
    private var manualPath: some View {
        VStack(alignment: .leading, spacing: s4) {
            MynahButton(showsManualPath ? "Hide this" : "I know my way around a Mac", kind: .quiet) {
                showsManualPath.toggle()
            }
            .padding(.leading, -s3)

            if showsManualPath {
                MynahCard(density: .compact) {
                    VStack(alignment: .leading, spacing: s4) {
                        Text("Copy this line, open the app called Terminal, paste it and press "
                            + "Return. Come back here when it finishes.")
                            .mynahFont(.body)
                            .foregroundStyle(Palette.ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        CopyField(value: SignalTooling.manualInstallCommand)
                        MynahButton("Open Terminal", kind: .quiet) {
                            NSWorkspace.shared.open(
                                URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                            )
                        }
                        .padding(.leading, -s3)
                    }
                }
            }
        }
        .mynahAnimation(Motion.snap, value: showsManualPath)
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: s5) {
            HStack(spacing: s4) {
                ThinkingIndicator()
                Text("Adding the Signal add-on…")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
            }
            Text("This usually takes two or three minutes. You can leave this open — "
                + "Mynah will tell you when it's done.")
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.secondary)
                .mynahProse()
        }
    }

    // MARK: Linked

    private func linked(number: String?) -> some View {
        VStack(alignment: .leading, spacing: s5) {
            MynahCard(density: .hero) {
                VStack(spacing: 0) {
                    StatusLine("Your phone", value: number ?? "Linked", tone: .good)
                    MynahDivider()
                    StatusLine("What Mynah reads", value: "Notes you send yourself", tone: .good)
                }
            }
            Text(LinkCopy.noHistoryNote)
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.secondary)
                .mynahProse()
        }
    }
}

// MARK: - Steps

/// A short ordered or unordered list of sentences.
///
/// No glyph wells, no icons, no bulleted feature rows: three things that matter
/// are three sentences.
private struct StepList: View {
    var numbered: Bool = true
    let steps: [String]

    init(numbered: Bool = true, steps: [String]) {
        self.numbered = numbered
        self.steps = steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: s4) {
                    Text(numbered ? "\(index + 1)" : "·")
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                        .monospacedDigit()
                        .frame(width: 12, alignment: .trailing)
                    Text(step)
                        .mynahFont(.body)
                        .foregroundStyle(Palette.ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Phone link — states") {
    SignalLinkPreviewHost().frame(width: 1240, height: 900)
}

/// Drives the real view through the states that are hard to reach on a machine
/// that is already linked.
private struct SignalLinkPreviewHost: View {
    private static let sampleURI =
        "sgnl://linkdevice?uuid=DK5rBFGuHy0aQm2yTsc9hg&pub_key=BQ7xW2mLh1sample0000000000000000000000000000"

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
    }

    private var pane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: s8) {
                LinkCodeSquare(uri: Self.sampleURI)
                LinkCodeSquare(uri: Self.sampleURI, isSpent: true)
                InlineBanner(
                    tone: SignalLinkFailure.tooManyDevices.tone,
                    headline: SignalLinkFailure.tooManyDevices.headline,
                    explanation: SignalLinkFailure.tooManyDevices.explanation
                )
                StepList(steps: [
                    "Open Signal.",
                    "Tap your own photo in the top-left corner, then Linked Devices.",
                    "Tap Link New Device, then point your phone at the square above."
                ])
            }
            .padding(s8)
            .frame(maxWidth: MynahWidth.stageColumn, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.surface.canvas)
    }
}
