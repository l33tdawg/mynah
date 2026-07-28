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
public struct PauseState: Sendable {

    private let fileURL: URL

    public init(fileURL: URL = PauseState.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("paused", isDirectory: false)
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

    public func setPaused(_ paused: Bool) throws {
        if paused {
            try OwnerOnlyFileSecurity.write(Data(), to: fileURL)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
