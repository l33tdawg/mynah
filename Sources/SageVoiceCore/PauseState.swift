import Foundation

/// Whether the appliance is answering.
///
/// Pause was a lie. `TalkView` said "It won't answer your phone, or this window",
/// Settings said the same, and every reader of `isPaused` was view code — nothing
/// in `SageVoiceCore` or `sage-voiced` had ever heard of it. The owner flipped it
/// before a meeting and their phone kept being answered.
///
/// It got worse the moment the daemon went under launchd with `KeepAlive`: the
/// appliance is now *harder* to stop by hand, so a switch that claims to stop it
/// is the only thing standing between the owner and an assistant that talks
/// during their meeting.
///
/// A file, because the app and the daemon are separate processes with no channel
/// between them — the same reason `ReplyPreferences` is a file. Read per message
/// rather than cached at boot: a pause that needs a restart is not a pause.
///
/// **Off Darwin this is the only way to pause at all**, because the switch that
/// writes it lives on a Mac settings screen that a Linux owner never sees. That
/// makes `setPaused(_:)` a supported entry point for a headless caller rather
/// than an implementation detail of the app, and it is why the failure to
/// *un*pause is now reported instead of swallowed.
public struct PauseState: Sendable {

    /// What a caller with no window has to be able to print.
    ///
    /// A tool that says "paused" without saying where it wrote the flag cannot
    /// be checked against the daemon that is supposed to read it, and that
    /// disagreement is precisely how pause managed to be a lie the first time.
    public let fileURL: URL

    public init(fileURL: URL = PauseState.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        layout: ApplianceSupportDirectory.Layout = ApplianceSupportDirectory.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ApplianceSupportDirectory.url(
            for: "paused",
            layout: layout,
            homeDirectory: homeDirectory,
            environment: environment
        )
    }

    /// Presence is the signal, not the contents.
    ///
    /// A flag whose meaning depends on parsing can fail open — a truncated write
    /// or an empty file would read as "not paused" and answer the phone anyway.
    /// A file either exists or it does not, and the failure mode of a corrupt one
    /// is "still paused", which is the safe direction.
    public func isPaused() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// When the owner paused, for a UI that wants to say "paused since 14:32".
    public func pausedAt() -> Date? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    /// - Throws: when the appliance is not in the state the caller asked for by
    ///   the time this returns.
    ///
    ///   **The unpause used to be a `try?`.** Removing the flag could fail —
    ///   permissions on the directory, a stray directory sitting where the flag
    ///   goes — and the caller was told nothing, so a `resume` would print
    ///   *answering again* while the daemon carried on reading a flag that was
    ///   still there and staying silent. That is the failure this whole type was
    ///   written to end, arrived at from the other direction: the appliance
    ///   doing the opposite of what the owner was told it was doing.
    ///
    ///   Unpausing something that was never paused is still not an error — the
    ///   app reconciles its saved preference on every launch — and neither is
    ///   losing the race to another process that removed the flag first. The
    ///   postcondition is what is checked, not who won.
    public func setPaused(_ paused: Bool) throws {
        if paused {
            try OwnerOnlyFileSecurity.write(Data(), to: fileURL)
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            // Only a failure if the flag is still there. Checking the state
            // rather than the error keeps this honest on both platforms:
            // corelibs-Foundation and Darwin do not agree on what a lost
            // unlink race is called, and they do agree on whether the file
            // exists.
            if FileManager.default.fileExists(atPath: fileURL.path) { throw error }
        }
    }
}
