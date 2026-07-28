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
/// One exception had to be closed by hand. `SourceLinks` appends a
/// `(sources: ...)` line to an assistant turn carrying the URLs a tool returned,
/// which is why "give me the links for those" works. Those URLs came out of tool
/// results, and a URL can be a secret — a signed download, a booking
/// confirmation, a share link recalled from SAGE. Carrying them for the rest of
/// a live conversation is the feature; writing them to disk to be reloaded
/// tomorrow is not, so `strippingSourceLinks` removes them on the way in.
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
    private struct StoredTurn: Codable, Equatable {
        var role: String
        var content: String
    }

    private struct StoredThread: Codable, Equatable {
        /// When *this* conversation was last spoken in.
        ///
        /// Per thread, not per file. A single `savedAt` looked equivalent and was
        /// not: the daemon persists every history on every turn, so one active
        /// thread stamped a fresh time onto all of them and kept a conversation
        /// nobody had touched for days permanently resumable. Verified: a
        /// three-day-old thread survived the six-hour expiry because a different
        /// thread said hello.
        var savedAt: Date
        var turns: [StoredTurn]
    }

    private struct StoredFile: Codable {
        /// Kept for files written by the previous version, which had no
        /// per-thread stamp. Used as the fallback age for those threads so an
        /// upgrade expires them correctly instead of treating them as new.
        var savedAt: Date
        var threads: [String: [StoredTurn]]?
        var conversations: [String: StoredThread]?
    }

    /// Removes the `(sources: ...)` line `SourceLinks.annotated` appends.
    ///
    /// Those URLs originate in tool results — the one thing this file is
    /// documented never to hold. They are worth carrying inside a live
    /// conversation and are not worth persisting: a URL is frequently the secret
    /// itself, and a booking link recalled from SAGE would otherwise sit in
    /// plaintext on disk long after the conversation that produced it.
    ///
    /// Matched on the exact prefix `SourceLinks` writes, and only at the start of
    /// a line, so an answer that happens to discuss sources keeps its words.
    static func strippingSourceLinks(_ content: String) -> String {
        guard content.contains("\n(sources: ") else { return content }
        let kept = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("(sources: ") }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Merge both shapes, so a file written by the previous version still
        // loads. Legacy threads inherit the file-level stamp, which is the best
        // age available for them and expires them rather than resurrecting them.
        var aged: [String: StoredThread] = [:]
        for (key, turns) in file.threads ?? [:] {
            aged[key] = StoredThread(savedAt: file.savedAt, turns: turns)
        }
        for (key, thread) in file.conversations ?? [:] {
            aged[key] = thread
        }

        var expired = false
        var restored: [String: [BrainMessage]] = [:]
        for (key, thread) in aged {
            guard now.timeIntervalSince(thread.savedAt) <= Self.maximumAge else {
                expired = true
                continue
            }
            let messages: [BrainMessage] = thread.turns.compactMap { turn in
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
        // Expiry has to remove the words, not just decline to read them. Before
        // this, "expires after six hours" was a read-time filter and the owner's
        // plaintext stayed on disk indefinitely — verified with a 48-hour-old
        // file that loaded as empty while still containing what they had said.
        if expired { purge(keeping: restored, now: now) }
        return restored
    }

    /// Best-effort rewrite dropping whatever has aged out. Never throws: this
    /// runs during boot and a tidy-up that cannot complete must not stop the
    /// appliance from starting.
    private func purge(keeping survivors: [String: [BrainMessage]], now: Date) {
        if survivors.isEmpty {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        try? save(survivors, now: now)
    }

    /// Writes atomically with owner-only permissions.
    ///
    /// Atomic because the daemon is killed by `pkill` on every deploy, and a
    /// half-written history file is worse than none — it would decode as a
    /// truncated conversation and be resumed as if complete.
    public func save(_ histories: [String: [BrainMessage]], now: Date = Date()) throws {
        // What is already on disk, so an untouched thread keeps its own age.
        // The daemon hands over *every* history on every turn, so stamping `now`
        // across the board is what let one active conversation keep every other
        // one alive forever.
        var previous: [String: StoredThread] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(StoredFile.self, from: data) {
            for (key, turns) in file.threads ?? [:] {
                previous[key] = StoredThread(savedAt: file.savedAt, turns: turns)
            }
            for (key, thread) in file.conversations ?? [:] {
                previous[key] = thread
            }
        }

        var conversations: [String: StoredThread] = [:]
        for (key, messages) in histories {
            let turns = Array(
                messages
                    .filter { $0.role == .user || $0.role == .assistant }
                    .suffix(Self.maximumTurnsPerThread)
                    .map {
                        StoredTurn(
                            role: $0.role.rawValue,
                            content: Self.strippingSourceLinks($0.content)
                        )
                    }
            )
            guard !turns.isEmpty else { continue }

            // Unchanged content means nothing was said in this thread, so its
            // clock does not restart.
            let stamp: Date
            if let old = previous[key], old.turns == turns {
                stamp = old.savedAt
            } else {
                stamp = now
            }
            guard now.timeIntervalSince(stamp) <= Self.maximumAge else { continue }
            conversations[key] = StoredThread(savedAt: stamp, turns: turns)
        }

        guard !conversations.isEmpty else {
            try? fileManager.removeItem(at: fileURL)
            return
        }

        let encoder = JSONEncoder()
        // Stable on disk so a diff between two saves shows what the owner said,
        // not a reshuffled dictionary.
        encoder.outputFormatting = [.sortedKeys]
        // `threads` is left nil: the legacy shape is read for upgrades and never
        // written again, so an old file converts to the per-thread shape the
        // first time anything is saved.
        let data = try encoder.encode(
            StoredFile(savedAt: now, threads: nil, conversations: conversations)
        )
        // Not `Data.write(.atomic)`: that creates the file at 0644 and can only
        // chmod afterwards, so every first write publishes the owner's
        // conversations world-readable for the moment in between.
        try OwnerOnlyFileSecurity.write(data, to: fileURL, fileManager: fileManager)
    }
}
