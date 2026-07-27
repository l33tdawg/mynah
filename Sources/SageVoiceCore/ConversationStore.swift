import Foundation

/// Conversation history that survives a restart.
///
/// It did not, and the owner hit it directly: mid-conversation about shops near
/// the KL Convention Centre, the daemon was restarted for a deploy, and the next
/// message — "can you give me the names of the shops and their google maps link
/// please" — was answered with "Could you clarify which shops?". Every fact was
/// still in the process that had just exited.
///
/// The appliance is a long-lived daemon that gets redeployed, crashes, and comes
/// back after a reboot. Holding the only copy of the conversation in memory
/// makes each of those a silent amnesia the owner discovers by being asked to
/// repeat themselves.
///
/// ## What is and is not written down
///
/// Only what `VoiceBridgeDaemon.conversationOnly` already keeps: the owner's
/// turns and the appliance's answers. Tool results are dropped before they get
/// here — deliberately and for a measured reason, since a model that can see
/// last turn's memory dump stops calling tools and recycles it — so this file
/// never holds a SAGE memory dump or a page of search results.
///
/// It does hold the owner's own words, which is why it is written with the same
/// owner-only permissions as their provider keys and their notes.
/// `@unchecked` for the injected `FileManager`, which is not `Sendable`. The
/// value is only ever read, and `.default` — the only thing production passes —
/// is documented as thread-safe. `NotesToolSource` makes the same trade for the
/// same reason.
public struct ConversationStore: @unchecked Sendable {

    /// How long a saved conversation stays resumable.
    ///
    /// Not indefinite. SAGE is the long-term memory; this is short-term working
    /// context, and silently resuming yesterday's subject is how the appliance
    /// produced its worst bug — an answer that mixed Chiang Mai shops into a
    /// question about Tokyo. Six hours covers a deploy, a crash, a reboot and a
    /// lunch break, and expires overnight so "morning mate" starts clean.
    public static let maximumAge: TimeInterval = 6 * 60 * 60

    /// Turns kept per thread on disk.
    ///
    /// Matches the in-memory limit rather than exceeding it: loading more than
    /// the daemon would have carried forward anyway just moves the trimming.
    public static let maximumTurnsPerThread = 16

    private let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = ConversationStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("conversations.json", isDirectory: false)
    }

    // MARK: Wire shape

    /// Deliberately not `BrainMessage`. That type carries tool calls, tool ids
    /// and provider-specific reasoning text, none of which is persisted here —
    /// and making it `Codable` would invite a future change to start persisting
    /// them, which is the thing this must not do.
    private struct StoredTurn: Codable {
        var role: String
        var content: String
    }

    private struct StoredFile: Codable {
        var savedAt: Date
        var threads: [String: [StoredTurn]]
    }

    // MARK: Load and save

    /// Saved histories, or empty when there is nothing usable.
    ///
    /// Never throws. A conversation that cannot be read is worth exactly one log
    /// line and a fresh start — refusing to boot the appliance because a cache
    /// file is corrupt would turn a cosmetic problem into an outage.
    public func load(now: Date = Date()) -> [String: [BrainMessage]] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(StoredFile.self, from: data) else {
            return [:]
        }
        guard now.timeIntervalSince(file.savedAt) <= Self.maximumAge else { return [:] }

        var restored: [String: [BrainMessage]] = [:]
        for (key, turns) in file.threads {
            let messages: [BrainMessage] = turns.compactMap { turn in
                switch turn.role {
                case "user": return .user(turn.content)
                case "assistant": return .assistant(turn.content)
                // Anything else was never written by this type. Dropping beats
                // reconstructing a system or tool message from a file on disk.
                default: return nil
                }
            }
            if !messages.isEmpty { restored[key] = messages }
        }
        return restored
    }

    /// Writes atomically with owner-only permissions.
    ///
    /// Atomic because the daemon is killed by `pkill` on every deploy, and a
    /// half-written history file is worse than none — it would decode as a
    /// truncated conversation and be resumed as if complete.
    public func save(_ histories: [String: [BrainMessage]], now: Date = Date()) throws {
        var threads: [String: [StoredTurn]] = [:]
        for (key, messages) in histories {
            let turns = messages
                .filter { $0.role == .user || $0.role == .assistant }
                .suffix(Self.maximumTurnsPerThread)
                .map { StoredTurn(role: $0.role.rawValue, content: $0.content) }
            if !turns.isEmpty { threads[key] = Array(turns) }
        }
        guard !threads.isEmpty else {
            try? fileManager.removeItem(at: fileURL)
            return
        }

        let directory = fileURL.deletingLastPathComponent()
        try OwnerOnlyFileSecurity.prepareDirectory(directory, fileManager: fileManager)

        let encoder = JSONEncoder()
        // Stable on disk so a diff between two saves shows what the owner said,
        // not a reshuffled dictionary.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(StoredFile(savedAt: now, threads: threads))
        try data.write(to: fileURL, options: .atomic)
        try OwnerOnlyFileSecurity.protectFile(fileURL, fileManager: fileManager)
    }
}
