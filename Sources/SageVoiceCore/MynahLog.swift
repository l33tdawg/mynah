import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// A diagnostic line that can still be read tomorrow.
///
/// **`os_log` on this owner's Mac emits and forgets.** `log stream` shows our
/// output live; `log show` cannot retrieve it afterwards — proven with a
/// standalone binary rather than inferred. So every diagnostic this app has ever
/// written was readable only by somebody who happened to be watching at the
/// moment it fired, which is the one moment nobody is.
///
/// That cost a day. "The appliance has never stored a memory" was sitting in a
/// log line the whole time: `SageRitual` was reporting each failed write, and
/// `ConversationModel` passed no log sink, so the line went to a facility that
/// could not be read back. An absence was read as an answer — the same shape as
/// every other defect this week, aimed at our own instrumentation.
///
/// So this writes to a **file**, beside the ones people already open:
/// `~/Library/Logs/Mynah/`, where `bridge.log`, `signal.log` and
/// `appliance.log` live and where every appliance fault today was actually
/// diagnosed.
///
/// ## It still emits to `os_log` as well
///
/// Not belt and braces — they answer different questions. `log stream` is the
/// better tool while you are watching something happen, it interleaves with the
/// rest of the system, and it costs nothing to keep. The file exists for the
/// other case, which is somebody arriving afterwards with a question. Dropping
/// either would remove a capability somebody is already using.
///
/// ## What must never reach here
///
/// A file has no `privacy:` annotation. Everything written is plaintext on the
/// owner's disk, so **nothing that passes through this may be something the
/// owner said, remembered, or was told** — no transcripts, no memory content, no
/// keys, no linking URIs. Those stay on `os_log`, where redaction is real, and
/// the two call sites that log such material say so where they stand.
///
/// Diagnostics about the *machinery* — which tool failed, which status came
/// back, which path was missing — are what this is for, and they are what the
/// day's questions actually needed.
///
/// ## Owner-only, because of what will be written here later
///
/// The file is `0600` in a `0700` directory, the same treatment
/// `ConversationStore`, `ProviderKeyStore` and `MynahIdentity` already get.
/// Nothing written here today is sensitive, and that is not the argument. This
/// is now the seam a dozen files log through, and the next line — a recipient,
/// a subject name, a fragment of what somebody asked — will be added by
/// somebody with no reason to suspect that this one file, alone among the ones
/// this package writes, was readable by every account on the Mac.
///
/// The rule above says such material must not reach here. The mode is what
/// happens when the rule is broken by accident.
///
/// ## Converting a call site to this is never mechanical
///
/// **Every level here forces `privacy: .public`, `debug` included.** That is
/// deliberate — a diagnostic rendered as `<private>` answers nothing, and the
/// sites this replaced all said `.public` themselves. But it means moving a
/// line onto this type does two things at once: it starts writing to a file,
/// *and* it removes whatever redaction that line had in `os_log`.
///
/// `chrome` found the sharp edge while checking the one site left behind.
/// `SignalLinkView` logs `signal-cli`'s output at `debug` with
/// `privacy: .private`, and that output can contain a live device-linking URI —
/// the credential that pairs a phone. Converting it would have kept the URI out
/// of the file, because `debug` is file-excluded, and **published it to anything
/// streaming `os_log`**, because this type would have made it public. The
/// file-exclusion looks like the safeguard and is not.
///
/// So the rule for anyone sweeping the remaining `Logger` sites: read what the
/// line actually carries first. `MynahLogTests` pins the half that can be
/// pinned — `debug` staying out of the file — and nothing can pin the other
/// half, because no test can see an `os_log` privacy annotation.
public struct MynahLog: Sendable {

    /// Where the lines go, beside the logs somebody already knows to open.
    ///
    /// **Off Darwin the folder changes and the reason for it does not.** The
    /// whole argument above is "put it where the other logs already are", and on
    /// a Linux box `~/Library/Logs` is not where anything is — it is a folder
    /// this program would invent, with a name that means nothing to the person
    /// looking for it. `~/.local/state` is the XDG place for exactly this: state
    /// a program keeps across runs that is not configuration and not a cache.
    ///
    /// The injected `homeDirectory` is still honoured rather than reading
    /// `XDG_STATE_HOME`, because `mayWriteToFile` compares against this function
    /// and every test that fakes a home would stop being fake if an environment
    /// variable could overrule it.
    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        #if canImport(Darwin)
        return homeDirectory
            .appendingPathComponent("Library/Logs/Mynah", isDirectory: true)
            .appendingPathComponent("mynah.log", isDirectory: false)
        #else
        return homeDirectory
            .appendingPathComponent(".local/state/mynah", isDirectory: true)
            .appendingPathComponent("mynah.log", isDirectory: false)
        #endif
    }

    /// Whether a line may be written to `url`, which is `false` for exactly one
    /// case: a test writing to the owner's real log.
    ///
    /// **Found by nearly reporting a bug that did not exist.** `mynah.log`
    /// showed forty "restarting the phone bridge to apply a changed
    /// configuration" lines inside one hour — chronic reconciling, the thing the
    /// team had been hunting all day, apparently caught red-handed. It was the
    /// test suite. `SignalBackgroundServiceManager` takes an injected
    /// `homeDirectory` and `fileManager` so tests touch nothing real, and its
    /// logger sat outside that seam: a `static let` on the default path, writing
    /// to the actual file no matter which fake world the test had built.
    ///
    /// Two costs, and the second is the serious one. It appends test noise to
    /// the file Settings tells the owner to send for diagnostics. And it
    /// *fabricates evidence in the exact file people diagnose from* — the real
    /// bridge process had been up for seventy-four minutes and had never
    /// restarted, which is what actually settled it (`bridge.log` untouched
    /// since `14:46`, the process older still).
    ///
    /// So the rule is narrow on purpose: under XCTest, a log aimed at the
    /// default path writes to `os_log` only. A test that passes its own URL —
    /// which is every test that asserts on file contents — is unaffected.
    static func mayWriteToFile(
        _ url: URL,
        isTesting: Bool = MynahLog.isRunningUnderXCTest
    ) -> Bool {
        guard isTesting else { return true }
        return url.standardizedFileURL != defaultFileURL().standardizedFileURL
    }

    /// The same detection `SignalBackgroundServiceManager` already uses to
    /// refuse to touch real launchd from a test. Borrowed rather than invented,
    /// because two different answers to "am I a test" is how one of them ends up
    /// wrong.
    ///
    /// **The Objective-C runtime is how it is asked on a Mac and there is no
    /// runtime to ask off one.** `NSClassFromString` exists in
    /// swift-corelibs-foundation but answers about Swift types by mangled name,
    /// so `"XCTestCase"` comes back `nil` inside a test run — which is the
    /// dangerous direction: it would report "not a test" while a test suite is
    /// running, and the whole point of this property is to stop a test writing
    /// into the owner's real log.
    ///
    /// So off Darwin it reads the thing the test runner actually is. `swift
    /// test` runs `.build/<config>/<Package>PackageTests.xctest`, an ordinary
    /// executable, and its own path is the one fact about that which does not
    /// depend on a runtime.
    static var isRunningUnderXCTest: Bool {
        #if canImport(ObjectiveC)
        return NSClassFromString("XCTestCase") != nil
        #else
        guard let executable = CommandLine.arguments.first else { return false }
        return executable.hasSuffix(".xctest")
            || executable.hasSuffix("PackageTests")
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        #endif
    }

    /// Past this, the file is rolled once to `mynah.log.1`.
    ///
    /// A diagnostic log that grows without limit becomes a thing people delete,
    /// and a deleted log answers nothing. Two megabytes is tens of thousands of
    /// lines — far more history than any question here has needed — and one
    /// generation is kept because the question is always "what happened just
    /// now", never "what happened last month".
    static let maximumBytes = 2 * 1024 * 1024

    private let category: String
    private let fileURL: URL
    #if canImport(OSLog)
    private let logger: Logger
    #endif

    public init(
        category: String,
        fileURL: URL = MynahLog.defaultFileURL(),
        subsystem: String = "com.sage.mynah"
    ) {
        self.category = category
        self.fileURL = fileURL
        #if canImport(OSLog)
        self.logger = Logger(subsystem: subsystem, category: category)
        #endif
    }

    // MARK: The streaming half, off Darwin

    /// The other destination on a platform with no `os_log`.
    ///
    /// **Not a stub that swallows the line.** The type above is deliberately two
    /// destinations answering two questions — a stream for somebody watching,
    /// a file for somebody arriving afterwards — and dropping the streaming half
    /// on Linux would silently delete `debug` entirely, since `debug` is the one
    /// level that never reaches the file.
    ///
    /// Standard error is the honest counterpart: under systemd it is the journal,
    /// which is `log stream` and `log show` at once, and in a terminal it is
    /// where a person watching already looks. Nothing is redacted here, which is
    /// the same bargain the file makes and the same rule applies — see "What
    /// must never reach here" above.
    #if !canImport(OSLog)
    private func stream(_ level: String, _ text: String) {
        guard let data = "\(level) [\(category)] \(text)\n".data(using: .utf8) else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        FileHandle.standardError.write(data)
    }
    #endif

    // MARK: Writing

    /// Something went wrong that somebody may have to explain later.
    public func error(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(OSLog)
        logger.error("\(text, privacy: .public)")
        #else
        stream("ERROR", text)
        #endif
        append("ERROR", text)
    }

    /// Something happened that a later diagnosis would want to know about.
    public func info(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(OSLog)
        logger.info("\(text, privacy: .public)")
        #else
        stream("INFO ", text)
        #endif
        append("INFO ", text)
    }

    /// A thing worth noticing that is not a fault. Same destination as `info`;
    /// the level is the caller's word for how much it matters, and both are
    /// worth having when somebody reads the file back.
    public func notice(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(OSLog)
        logger.notice("\(text, privacy: .public)")
        #else
        stream("NOTE ", text)
        #endif
        append("NOTE ", text)
    }

    /// Detail that is only interesting while watching. Goes to `os_log` alone —
    /// a file that fills with routine chatter is one nobody reads at the moment
    /// it matters.
    public func debug(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(OSLog)
        logger.debug("\(text, privacy: .public)")
        #else
        stream("DEBUG", text)
        #endif
    }

    // MARK: The file

    /// Append-only, best-effort, and it never throws.
    ///
    /// A failure to record why something broke must not become a second thing
    /// that broke. Every failure here is silent on purpose: there is nowhere
    /// left to report it to.
    private func append(_ level: String, _ message: String) {
        guard Self.mayWriteToFile(fileURL) else { return }
        let line = "\(Self.timestamp.string(from: Date())) \(level) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        Self.lock.lock()
        defer { Self.lock.unlock() }

        let manager = FileManager.default
        // `prepareDirectory` rather than `createDirectory`: it also sets 0700,
        // and it is idempotent on a directory that already exists.
        try? OwnerOnlyFileSecurity.prepareDirectory(fileURL.deletingLastPathComponent())
        rollIfTooLarge(manager)

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }

        // After the write rather than before, because the file may not have
        // existed until the line above. Once per process, and again after a
        // roll — checked rather than assumed, because a rotate that recreates
        // the file at the default mode is exactly how this kind of fix fails
        // silently.
        //
        // It also repairs a file left at 0644 by an older build, which no
        // amount of care at creation time would have done.
        if !Self.protectedPaths.contains(fileURL.path) {
            try? OwnerOnlyFileSecurity.protectFile(fileURL)
            Self.protectedPaths.insert(fileURL.path)
        }
    }

    /// Which files have been chmod'ed already, guarded by `lock`.
    ///
    /// **Per path, not per process, and the first version got that wrong.** It
    /// was a single `hasProtected` flag, which is correct only while exactly one
    /// log file exists — the first file protected made every other file skip the
    /// step. The tests caught it because they each write to their own temporary
    /// file, which is precisely the shape production takes the moment anything
    /// logs anywhere but the default path.
    private nonisolated(unsafe) static var protectedPaths: Set<String> = []

    private func rollIfTooLarge(_ manager: FileManager) {
        guard let size = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > Self.maximumBytes else { return }
        let rolled = fileURL.appendingPathExtension("1")
        try? manager.removeItem(at: rolled)
        // `moveItem` carries the mode across, so the kept generation stays
        // owner-only without further work. The *new* file does not exist yet —
        // hence the reset, so the next write protects it rather than trusting
        // that it was done once at start-up.
        try? manager.moveItem(at: fileURL, to: rolled)
        // The kept generation is protected explicitly rather than trusted to
        // carry its mode across. `moveItem` does preserve it — but only if it
        // had one, and a file written by an older build arrives here at 0644.
        // Without this, the one copy of the history that survives a roll is the
        // world-readable one, which is the opposite of the intent.
        try? OwnerOnlyFileSecurity.protectFile(rolled)
        Self.protectedPaths.remove(fileURL.path)
    }

    /// One lock for the process. Two threads appending at once produce
    /// interleaved bytes rather than two lines, and a corrupted line is worse
    /// than a slow one — this is off the hot path by construction, since a
    /// diagnostic that fires often enough to contend is a diagnostic nobody
    /// should be writing.
    private static let lock = NSLock()

    /// Local time and seconds, matching `appliance.log` exactly, because every
    /// diagnosis so far has started by lining a log up against a file's
    /// modification date.
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
