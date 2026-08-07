import Foundation
import SageVoiceCore

/// Linking this Mac to the owner's WhatsApp, without leaving the app.
///
/// **Why this is not `scripts/pair-whatsapp.sh`.** That script exists, it works,
/// and it is the wrong shape for a shipped appliance: it asks the owner to open
/// Terminal, know where the app is, and read a QR drawn in block characters at
/// whatever size their font happens to be. Signal has been paired from inside
/// the app since 1.0 — see `SignalLinkView` — and the owner's requirement for
/// WhatsApp was that it *follow the same flow as Signal*. A second channel that
/// can only be set up from a shell is not the same flow.
///
/// The bridge already speaks the protocol this needs: `--pair-json` makes it
/// emit one JSON object per line instead of drawing to a terminal. So this runs
/// the same vendored bridge, in the same pairing mode the script uses, and
/// renders the code with CoreImage.
enum WhatsAppPairing {

    /// One line of `--pair-json` output.
    ///
    /// A closed set with an `unrecognised` case rather than a decode failure,
    /// for the reason `WhatsAppIncomingMessage.mediaType` is a string: the
    /// bridge gains events as upstream does, and an unfamiliar one arriving as
    /// an *error* would abandon a pairing that is going perfectly.
    enum Event: Equatable {
        /// The bridge is up and waiting for WhatsApp.
        case started(session: String)
        /// A code to show. Superseded roughly every twenty seconds — WhatsApp
        /// rotates them, and the bridge emits each new one.
        case qr(String)
        /// Paired. `user` is what WhatsApp says the account is called.
        case connected(user: String?)
        /// The session on disk is no longer valid — most often because the owner
        /// removed this device from their phone. Distinct from `failed` because
        /// the fix is different: this one needs the session deleted before a
        /// retry can work.
        case loggedOut
        case disconnected(reason: Int?)
        case failed(String)
        /// Something this build has no opinion about. Kept rather than dropped
        /// so a log can show what actually arrived.
        case unrecognised(String)
    }

    /// Decoding, separated from the process that produces it.
    ///
    /// **A function over a `String`, because a test cannot spawn the bridge.**
    /// Pairing needs a real WhatsApp account and a phone with a camera, so the
    /// only part of this that can be tested is the part that reads what the
    /// bridge said — which is also the part with a rule in it. The same argument
    /// `WhatsAppAcknowledgementLedger` makes about being a value: a rule that
    /// only exists inside something needing a socket is a rule nothing checks.
    static func event(from line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // The bridge writes ordinary log lines to stdout too when something
        // upstream has not been taught about `--pair-json`. Not an error, and
        // not an event: skipped, so a stray banner cannot fail a pairing.
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["event"] as? String
        else { return nil }

        switch name {
        case "started":
            return .started(session: object["session"] as? String ?? "")
        case "qr":
            guard let qr = object["qr"] as? String, !qr.isEmpty else {
                return .failed("the bridge sent a QR event with no code in it")
            }
            return .qr(qr)
        case "connected":
            let user = object["user"] as? [String: Any]
            // `name` first: it is what the owner calls the account. The id is a
            // JID carrying their phone number, which is a fine fallback and a
            // poor label.
            return .connected(user: (user?["name"] as? String) ?? (user?["id"] as? String))
        case "error":
            let detail = object["error"] as? String ?? "the bridge failed without saying why"
            return detail == "logged_out" ? .loggedOut : .failed(detail)
        case "disconnected":
            return .disconnected(reason: object["reason"] as? Int)
        default:
            return .unrecognised(name)
        }
    }

    /// Whether this Mac already holds a WhatsApp session.
    ///
    /// `creds.json` specifically, not "the directory exists". Baileys creates
    /// the directory before it has anything to put in it, so an abandoned
    /// pairing leaves a directory that looks exactly like a linked account —
    /// and the owner would be shown "Linked" over a bridge that will draw a QR
    /// on its next start.
    static func isPaired(sessionDirectory: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(
            atPath: sessionDirectory.appendingPathComponent("creds.json").path
        )
    }

    static func defaultSessionDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("WhatsApp", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
    }
}

/// Runs the bridge in pairing mode and reports what it says.
///
/// **Nothing else may be holding the session while this runs.** Baileys does not
/// arbitrate two writers of one auth state: the second invalidates the first's
/// keys and both ends silently stop decrypting, which looks like WhatsApp being
/// flaky rather than like a collision. So the caller stops the LaunchAgent
/// first — see `stopBackgroundBridge` — and starts it again afterwards by
/// reconciling.
@MainActor
@Observable
final class WhatsAppPairingSession {

    enum Phase: Equatable {
        case idle
        /// Started, no code yet. WhatsApp takes a second or two to issue one.
        case waiting
        case showing(String)
        case linked(user: String?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private let node: URL
    private let bridge: URL
    private let sessionDirectory: URL
    private let log = MynahLog(category: "whatsapp-pairing")
    private var process: Process?

    /// Set the moment the sheet goes away, whether or not a process exists yet.
    ///
    /// **`cancel()` was a no-op for the whole of `stopBackgroundBridge()`.**
    /// That call boots out three LaunchAgents and can take seconds; if the owner
    /// closed the sheet inside that window, `cancel()` found `process == nil`,
    /// returned, and `start()` then went on to spawn a bridge that nothing owned
    /// and nothing would ever terminate. It holds the session directory, and the
    /// reconcile that follows starts the real bridge on top of it — two Baileys
    /// writers on one auth state, which is the collision that silently stops
    /// both ends decrypting.
    private var cancelled = false

    init(node: URL, bridge: URL, sessionDirectory: URL = WhatsAppPairing.defaultSessionDirectory()) {
        self.node = node
        self.bridge = bridge
        self.sessionDirectory = sessionDirectory
    }

    /// - Parameter stopBackgroundBridge: booted out before the pairing process
    ///   starts. Injected rather than reached for, so a test of this type does
    ///   not rearrange the launchd of the machine it runs on — the same hazard
    ///   `SignalBackgroundServiceManager.isTestReachingTheRealMachine` exists
    ///   for.
    func start(stopBackgroundBridge: @escaping @Sendable () async -> Void) async {
        guard process == nil, !cancelled else { return }
        await stopBackgroundBridge()
        // Checked again: the sheet may have gone away while that was running.
        guard !cancelled else { return }

        // `0700` before the bridge writes into it. What lands here is the
        // credential that lets this Mac send as the owner; anybody who can read
        // it is logged in as them.
        try? OwnerOnlyFileSecurity.prepareDirectory(sessionDirectory)

        let task = Process()
        task.executableURL = node
        task.arguments = [
            bridge.path,
            "--pair-only",
            "--pair-json",
            "--session", sessionDirectory.path
        ]
        // The bridge reads HOME for its default state directory. Everything it
        // needs is passed explicitly above, but an inherited environment from a
        // GUI app is not the one the LaunchAgent will have, and a pairing that
        // wrote its session somewhere the daemon does not look would succeed
        // here and fail for ever after.
        task.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin"
        ]
        task.currentDirectoryURL = bridge.deletingLastPathComponent()

        let output = Pipe()
        task.standardOutput = output
        // Into the same pipe. The bridge's own warnings go to stderr, and a
        // failure the owner is staring at should not be visible only to whoever
        // reads a log later.
        task.standardError = output

        do {
            try task.run()
        } catch {
            phase = .failed("Mynah could not start the WhatsApp helper: \(error.localizedDescription)")
            return
        }
        // **Terminated if the app goes away, and reaped when it exits on its
        // own.** Without a handler the pairing bridge outlived the sheet, the
        // window and the app: nothing called `waitUntilExit`, nothing observed
        // termination, and a quit mid-pairing left it running against the
        // owner's session directory until the Mac restarted.
        task.terminationHandler = { _ in
            Task { @MainActor [weak self] in self?.reap() }
        }
        process = task
        phase = .waiting

        let handle = output.fileHandleForReading
        Task.detached { [weak self] in
            var buffered = ""
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffered += String(decoding: chunk, as: UTF8.self)
                // Split on newlines and keep the remainder: a JSON object can
                // arrive split across two reads, and parsing half of one is how
                // a perfectly good QR becomes a decode failure.
                while let newline = buffered.firstIndex(of: "\n") {
                    let line = String(buffered[buffered.startIndex..<newline])
                    buffered.removeSubrange(buffered.startIndex...newline)
                    guard let event = WhatsAppPairing.event(from: line) else { continue }
                    await self?.handle(event)
                }
            }
            await self?.finished()
        }
    }

    private func handle(_ event: WhatsAppPairing.Event) {
        switch event {
        case .started:
            phase = .waiting
        case .qr(let code):
            phase = .showing(code)
        case .connected(let user):
            phase = .linked(user: user)
            // The bridge exits two seconds after this, having flushed the
            // credentials. Left to exit on its own rather than killed: killing
            // it in that window is how a pairing the owner watched succeed
            // leaves nothing on disk.
        case .loggedOut:
            phase = .failed(
                "WhatsApp says this Mac is no longer linked. Remove Mynah under Linked Devices "
                    + "on your phone, then try again."
            )
        case .disconnected(let reason):
            // Reconnects are routine during pairing — code 515 is WhatsApp
            // asking for a restart immediately after a successful scan. Saying
            // anything here would report a failure in the middle of a success.
            log.notice("whatsapp pairing reconnecting (reason \(reason.map(String.init) ?? "unknown"))")
        case .failed(let detail):
            phase = .failed(detail)
        case .unrecognised(let name):
            log.notice("whatsapp pairing sent an event this build does not know: \(name)")
        }
    }

    private func finished() {
        process = nil
        // Only when nothing better has been said. A process that exits after
        // reporting `connected` exited because it was finished, and overwriting
        // a success with "it stopped" would take a linked account away from the
        // owner in the second after they linked it.
        if case .waiting = phase {
            phase = .failed("The WhatsApp helper stopped before it showed a code.")
        }
        if case .showing = phase {
            phase = .failed("The WhatsApp helper stopped before the code was scanned.")
        }
    }

    /// The process exited on its own — normally two seconds after `connected`,
    /// having flushed the credentials.
    private func reap() {
        process = nil
    }

    /// Called when the owner closes the sheet, and when the sheet's task is
    /// cancelled. Safe before `start()` has spawned anything.
    func cancel() {
        cancelled = true
        guard let process else { return }
        self.process = nil
        // **Not while it is writing the credentials.** Baileys flushes
        // `creds.json` from a `creds.update` that arrives just after
        // `connected`, and bridge.js waits two seconds before exiting for
        // exactly that reason. A SIGTERM inside that window is how a pairing the
        // owner watched succeed leaves a session that cannot log in — and
        // `isPaired` would still say Linked, because the file exists.
        //
        // So a linked session is given its two seconds; anything else stops now.
        if case .linked = phase {
            Task.detached {
                try? await Task.sleep(for: .seconds(3))
                if process.isRunning { process.terminate() }
            }
            return
        }
        process.terminate()
        phase = .idle
    }
}
