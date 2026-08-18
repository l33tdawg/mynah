import Foundation

/// The one directory this appliance keeps its per-owner files in, on whichever
/// platform it is running.
///
/// **Two processes disagreeing about this path is the bug this type exists to
/// prevent.** The app writes `paused`, the daemon reads it, and they share no
/// channel other than the file — so a path spelled twice is a pause that stops
/// nothing, which is a failure this product has already shipped once. Every
/// settings file that a headless caller may now write goes through here, so the
/// daemon and whatever wrote it cannot end up looking at two different files.
///
/// On a Mac it is `~/Library/Application Support/SAGE Voice Bridge`, unchanged
/// and unchangeable: that is where every existing install already keeps its
/// conversations, its keys and its ledgers, and an update must not go looking
/// somewhere new.
///
/// Off Darwin `~/Library` is a folder nothing on the system understands, and
/// creating one would leave a stray `Library` in the owner's home. The XDG data
/// directory — `$XDG_DATA_HOME`, or `~/.local/share` when it is unset — is the
/// per-user equivalent, and it is already where `SingleInstance` puts the
/// appliance lock and where corelibs-Foundation's `.applicationSupportDirectory`
/// puts the memory store and the vendored node. *Data* rather than *config*,
/// deliberately: the choice was between agreeing with the state the appliance
/// already keeps there and being pedantically right about `~/.config` while
/// scattering one appliance across two roots.
///
/// **Both halves are reachable on both platforms**, because a branch that only
/// compiles on Linux is a branch no Mac test can redden — and the Mac is where
/// this suite is run before a release.
public enum ApplianceSupportDirectory {

    /// Spelled once. It is the same name on both platforms, spaces and all:
    /// an appliance whose folder is called one thing on a Mac and another on
    /// Linux is a second thing for an owner to learn and a second thing for a
    /// support answer to get wrong.
    public static let folderName = "SAGE Voice Bridge"

    public enum Layout: Sendable, Equatable {
        /// `~/Library/Application Support/SAGE Voice Bridge`.
        case darwin
        /// `$XDG_DATA_HOME/SAGE Voice Bridge`, `~/.local/share/…` when unset.
        case xdg
    }

    /// What this build actually uses. The only `#if` in the whole story.
    public static var current: Layout {
        #if os(macOS)
        return .darwin
        #else
        return .xdg
        #endif
    }

    /// - Parameter environment: injectable so a test that fakes a home is not
    ///   quietly overruled by the real `$XDG_DATA_HOME` of the machine running
    ///   it — the trap `MynahLog.defaultFileURL` sidesteps by reading no
    ///   environment at all. This one has to read it, because the daemon and a
    ///   CLI both inherit it and must agree; so it is a parameter rather than a
    ///   hidden global.
    public static func directory(
        layout: Layout = ApplianceSupportDirectory.current,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch layout {
        case .darwin:
            return homeDirectory
                .appendingPathComponent("Library/Application Support/\(folderName)", isDirectory: true)
        case .xdg:
            let dataHome = environment["XDG_DATA_HOME"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
            return dataHome.appendingPathComponent(folderName, isDirectory: true)
        }
    }

    public static func url(
        for fileName: String,
        layout: Layout = ApplianceSupportDirectory.current,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        directory(layout: layout, homeDirectory: homeDirectory, environment: environment)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

/// What the background services need to know, in a file rather than in argv.
///
/// **Why this exists.** Writing a LaunchAgent by hand puts an entry in System
/// Settings → General → Login Items under the *owner's own name* — "Dhillon
/// Kannabhiran" — rather than under Mynah. `SMAppService` fixes that, and it
/// requires the plist to be **statically bundled** at
/// `Contents/Library/LaunchAgents/`. A bundled plist ships identically to every
/// Mac, so it cannot carry a phone number, a provider, a model or a socket
/// path. Those had to come out of `ProgramArguments` and go somewhere both
/// processes can read.
///
/// **It is a transport, not a second source of truth.** The values still come
/// from where they always came from — the linked Signal account, the brain the
/// owner chose, the resolved node — and are written here on the way to the
/// daemon. Nothing decides anything by reading this file that was not already
/// decided before writing it. That distinction is the whole reason the pause
/// marker had to lose its `UserDefaults` mirror: two stores that can disagree
/// will, and the window said Online for an hour while the daemon dropped
/// messages. This is one store, serialised.
///
/// Deliberately the same shape as `ReplyPreferences` and `CallPreferences`:
/// same directory, same JSON, same owner-only write, same never-throwing read.
/// A fourth file in a directory of three is a pattern; a fourth mechanism would
/// be a thing to learn.
public struct ServicePreferences: Sendable {

    /// Everything the two jobs need that differs per owner.
    ///
    /// `model` is optional because it genuinely is: an API provider serves
    /// whatever it serves unless the owner pins one, and writing a guess here
    /// would put a model name in a launch flag that nobody chose.
    public struct Stored: Codable, Equatable, Sendable {
        public var account: String
        public var provider: String
        public var model: String?
        public var socketPath: String
        public var sagePath: String

        public init(
            account: String,
            provider: String,
            model: String?,
            socketPath: String,
            sagePath: String
        ) {
            self.account = account
            self.provider = provider
            self.model = model
            self.socketPath = socketPath
            self.sagePath = sagePath
        }
    }

    /// What a caller with no window has to be able to print.
    ///
    /// A headless tool that says "wrote your settings" without saying where is
    /// unfalsifiable — and the one failure this whole area is guarding against
    /// is two processes reading two different paths. Naming the file turns that
    /// from a silent disagreement into one somebody can see.
    public let fileURL: URL

    public init(fileURL: URL = ServicePreferences.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        layout: ApplianceSupportDirectory.Layout = ApplianceSupportDirectory.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ApplianceSupportDirectory.url(
            for: "service-preferences.json",
            layout: layout,
            homeDirectory: homeDirectory,
            environment: environment
        )
    }

    /// Why a read can fail out loud, when `current()` never does.
    public enum Refusal: Error, LocalizedError, Equatable {
        case unreadable(path: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                return """
                \(path) exists but is not readable service configuration.
                Move it aside and run setup again; the appliance will write a fresh one.
                """
            }
        }
    }

    /// The saved configuration, or `nil` when there is none.
    ///
    /// **Never throws, and `nil` is not an error.** A missing file is the
    /// ordinary state of a machine where setup has not finished, and an
    /// appliance that refused to start over an absent preferences file would be
    /// a worse failure than the one it was guarding against. The caller decides
    /// what to do about `nil`; this only reports it.
    ///
    /// A file that will not parse reads the same as one that is not there. That
    /// is deliberate and it is the `ReplyPreferences` rule: a corrupt
    /// preference should cost the owner their preference, not their appliance.
    /// It is also why `currentOrRefuse()` exists — see there.
    public func current() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        return stored
    }

    /// The same read, for a caller that has to *say* what it found.
    ///
    /// `current()` answers "not configured" to both "there is no file" and
    /// "there is a file I cannot read", which is right for the daemon — it
    /// starts either way — and wrong for anything that prints. A status line
    /// saying *not configured* over a corrupt file sends the owner to run setup
    /// they have already run, and a dead end is what they find. This one
    /// separates the two and names the file.
    ///
    /// - Returns: `nil` only when the file genuinely is not there.
    public func currentOrRefuse() throws -> Stored? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            throw Refusal.unreadable(path: fileURL.path)
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            throw Refusal.unreadable(path: fileURL.path)
        }
        return stored
    }

    /// Writes only when something actually changed.
    ///
    /// The same discipline as the pause marker, for the same reason: rewriting
    /// an identical file moves its modification date, and a modification date
    /// is a fact somebody may later read as "this changed at 11:40". It also
    /// keeps this off the path that restarts the appliance — see
    /// `SignalBackgroundServiceManager.enable`, where a no-op reconcile must
    /// stay a no-op all the way down.
    ///
    /// - Returns: whether the file was written.
    @discardableResult
    public func save(_ stored: Stored) throws -> Bool {
        guard current() != stored else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyFileSecurity.write(encoder.encode(stored), to: fileURL)
        return true
    }

    /// Removed when the appliance is removed, so a stale account cannot be
    /// picked up by a service the owner re-enables months later.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
