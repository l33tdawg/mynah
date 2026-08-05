import Foundation

/// The idempotency key for a send, written down before the send happens.
///
/// ## What `idempotency_key` is for
///
/// `sage_message_send` requires one, and SAGE's own description says why: it
/// "makes a retry return the original message_id instead of creating a
/// duplicate", and is "reused only when retrying this exact send". So the key is
/// per *attempt group*, not per message text — two deliberate sends of the same
/// sentence are two messages and must get two keys, or the second silently
/// becomes the first.
///
/// ## What writing it down buys, and what it does not
///
/// Stated precisely, because the honest scope is narrower than "persistence"
/// sounds. The key is written before the request and removed once the node has
/// confirmed a `message_id`. So an entry left behind means exactly one thing:
/// **a send whose outcome this appliance never learned** — the process died, or
/// the node never answered.
///
/// That is a diagnostic, not a recovery. Nothing here resends on startup, and
/// deliberately: an appliance that replays a queue after a crash can deliver a
/// message the owner has since changed their mind about, and the owner has no
/// way to see the queue or stop it. What it enables is the *deliberate* version
/// — `sage_message_status` takes a `message_id` and answers "was this
/// delivered", which is the right question to ask a stranded entry, and is why
/// that tool stays reachable programmatically while staying out of the model's
/// catalogue.
///
/// Retries within one `send` reuse the key from memory; the file is not read
/// back for that. The file is the record, not the mechanism.
public struct AgentSendJournal: Sendable {

    public struct Entry: Codable, Equatable, Sendable {
        public let key: String
        /// The resolved wire address, never the display name.
        public let to: String
        /// First 120 characters, so a stranded entry can be recognised without
        /// keeping the owner's whole message in a second place on disk.
        public let excerpt: String
        public let started: Date
    }

    private let fileURL: URL

    public init(fileURL: URL = AgentSendJournal.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("agent-sends.json", isDirectory: false)
    }

    /// A fresh key for one logical send.
    ///
    /// Random rather than derived from the content. A content hash would make
    /// two deliberate sends of the same sentence collide, and the node would
    /// answer the second with the first's `message_id` — the owner would see
    /// "sent" and nothing would arrive.
    public static func newKey() -> String { UUID().uuidString }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return stored
    }

    /// Records a send about to be attempted. Never throws: a journal that
    /// cannot be written must not stop the owner sending a message.
    public func starting(key: String, to wire: String, message: String) {
        var kept = entries()
        kept.removeAll { $0.key == key }
        kept.append(Entry(
            key: key,
            to: wire,
            excerpt: String(message.prefix(120)),
            started: Date()
        ))
        write(kept)
    }

    /// The node answered, so this send's fate is known and the record is spent.
    public func finished(key: String) {
        var kept = entries()
        kept.removeAll { $0.key == key }
        write(kept)
    }

    private func write(_ entries: [Entry]) {
        // Bounded. This file is written for the life of the appliance, and a
        // stranded entry that nobody ever looks at should not grow without end.
        let bounded = entries.suffix(50)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(bounded)) else { return }
        try? OwnerOnlyFileSecurity.write(data, to: fileURL)
    }
}
