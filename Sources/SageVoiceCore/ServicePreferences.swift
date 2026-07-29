import Foundation

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

    private let fileURL: URL

    public init(fileURL: URL = ServicePreferences.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("service-preferences.json", isDirectory: false)
    }

    /// The saved configuration, or `nil` when there is none.
    ///
    /// **Never throws, and `nil` is not an error.** A missing file is the
    /// ordinary state of a Mac where setup has not finished, and an appliance
    /// that refused to start over an absent preferences file would be a worse
    /// failure than the one it was guarding against. The caller decides what to
    /// do about `nil`; this only reports it.
    ///
    /// A file that will not parse reads the same as one that is not there. That
    /// is deliberate and it is the `ReplyPreferences` rule: a corrupt
    /// preference should cost the owner their preference, not their appliance.
    public func current() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
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
