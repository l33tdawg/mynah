import Foundation
import Observation
import OSLog
import SageVoiceCore
import SwiftUI

// MARK: - One message in this window's conversation

/// A single thing that was said here, ready to draw.
struct TranscriptMessage: Identifiable, Equatable, Sendable {

    enum Speaker: Equatable, Sendable {
        case owner
        case mynah
    }

    /// Where the message sits in the thread.
    ///
    /// Position rather than content, because the same words are said twice —
    /// "thanks", "ok" — and two rows with one identity is a `ForEach` that draws
    /// one of them. The record only appends, so a position holds still while
    /// anyone is looking at it; the one exception is the cap, where the oldest
    /// messages fall off and the list renumbers once.
    let id: Int
    let speaker: Speaker
    let text: String
    /// When it was said. Drawn beneath the message.
    var at: Date?

    /// Documents this message produced, drawn under it as something to open.
    ///
    /// The window has no attachment channel, so a PDF Mynah writes here is a
    /// file it can only *mention* — and a mentioned file in a folder nobody
    /// names is a file the owner does not have. One click is the difference.
    var files: [URL] = []
}

/// One turn as this window keeps it.
struct RecordedTurn: Codable, Equatable, Sendable {
    var role: String
    var content: String
    /// When this turn was said.
    ///
    /// Optional the whole way through, and it stays nil rather than becoming
    /// `Date()` at any point on the journey. Every message written before stamps
    /// shipped has no honest time, and a transcript that guesses is worse than
    /// one that says nothing — the owner asked for these so he could see how
    /// fast the appliance answers, which a guess would misreport convincingly.
    var at: Date?

    /// Paths of documents this turn wrote.
    ///
    /// Paths rather than bookmarks, and optional so every record written before
    /// this existed still decodes. A file the owner has since moved or deleted
    /// is simply not offered — see `TranscriptMessage.files`, which drops the
    /// ones that are no longer there rather than drawing a chip that does
    /// nothing.
    var files: [String]?

    init(role: String, content: String, at: Date? = nil, files: [String]? = nil) {
        self.role = role
        self.content = content
        self.at = at
        self.files = files
    }

    var speaker: TranscriptMessage.Speaker { role == "user" ? .owner : .mynah }
}

// MARK: - What this window has said

/// This window's own conversation, on disk.
///
/// ## Why this is not the phone's conversation any more
///
/// It used to be. The window read the daemon's `conversations.json`, appended
/// whatever was new into a record of its own, and drew the Signal thread — so
/// walking from the phone to the Mac showed one continuous conversation.
///
/// That only ever worked in one direction, and the owner named it: *"the
/// conversation sync seems to be one way — signal -> mynah but not mynah ->
/// signal"*. The asymmetry was not an oversight, it was the only safe option:
/// the other direction means this app writing into somebody's Signal history,
/// and clearing a window must never delete a person's messages. So the choice
/// was a half-merged conversation or two whole ones, and the owner chose two:
/// *"you talk to mynah in signal it has its own thread and you talk to it in
/// app it has its own thread"*.
///
/// What that gives up, stated plainly because it is the bug the merge was built
/// to fix: ask something on the phone, walk to the Mac, and this window will not
/// know about it. The reason that is now acceptable rather than a regression is
/// **SAGE**. Continuity across surfaces belongs in memory, which both surfaces
/// share, rather than in a transcript one of them happens to have read. Memory
/// survives six hours, sixteen turns and a cleared thread; the merge survived
/// none of those.
///
/// What it removes: the digest fingerprints, the longest-run overlap matcher,
/// the per-thread selection and the three-second poll. All of it existed to
/// reconcile two records. One record cannot disagree with itself.
///
/// ## Its own file
///
/// `window-conversation.json`, beside the daemon's rather than inside it: that
/// file is the appliance's working memory and the appliance prunes it, while
/// this is the owner's record and only the owner empties it.
///
/// A *new* name rather than reusing `window-transcript.json`, which holds the
/// mirrored Signal messages this window no longer shows. Repurposing it would
/// silently reinterpret the owner's existing record, and deleting it would throw
/// away their words to make an upgrade tidy. It is left exactly where it is.
///
/// The cost, stated because it is a real one: this holds the owner's plaintext
/// with no expiry, where the daemon's copy deliberately has one. It is written
/// 0600 like their keys, it is capped, and the button in the window genuinely
/// erases it.
struct WindowRecord: Codable, Equatable, Sendable {

    /// How many messages this window keeps.
    ///
    /// Append-only cannot mean unbounded. This is the owner's plaintext with no
    /// expiry on it, so a record that grows for a year is a bigger thing to lose
    /// than one that holds a season of talking. Four hundred messages is roughly
    /// two hundred exchanges, and about a megabyte at worst.
    ///
    /// The oldest go first, which is both the honest direction — a transcript
    /// missing its beginning still reads — and the end nobody scrolls back to.
    static let maximumTurns = 400

    var turns: [RecordedTurn] = []

    /// Adds a finished turn, oldest falling off the front once the cap is hit.
    mutating func append(
        question: String,
        answer: String,
        askedAt: Date?,
        answeredAt: Date?,
        files: [URL] = []
    ) {
        turns.append(RecordedTurn(role: "user", content: question, at: askedAt))
        turns.append(RecordedTurn(
            role: "assistant",
            content: answer,
            at: answeredAt,
            files: files.isEmpty ? nil : files.map(\.path)
        ))
        if turns.count > Self.maximumTurns {
            turns = Array(turns.suffix(Self.maximumTurns))
        }
    }

    /// The owner emptying the window.
    ///
    /// The words go, and nothing survives them. The old mirrored record had to
    /// keep fingerprints of what it had cleared, or the next poll would put the
    /// same conversation straight back three seconds later — a clear button that
    /// undid itself. Nothing polls any more, so a clear is simply a clear.
    mutating func clear() {
        turns = []
    }

    // MARK: Where it lives

    static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("window-conversation.json", isDirectory: false)
    }

    /// Never throws. A record that will not parse should cost the owner their
    /// history, not their ability to open the window.
    static func load(from url: URL = WindowRecord.defaultFileURL()) -> WindowRecord {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(WindowRecord.self, from: data) else {
            return WindowRecord()
        }
        return stored
    }

    /// Owner-only from the first byte, like the daemon's copy and for the same
    /// reason: these are the owner's own words, not a preference.
    func save(to url: URL = WindowRecord.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }
}

// MARK: - The conversation this window is having

private let conversationRecordLog = MynahLog(category: "window-conversation")

/// What the owner and Mynah have said to each other *here*.
///
/// Read once at launch and written when a turn finishes. There is no poll: the
/// only writer is this app, so there is nothing to watch for.
@MainActor
@Observable
final class WindowConversation {

    /// Outlives the pane, like `ConversationModel.shared` and for the same
    /// reason: `MainShell` destroys the branch it is not showing, so a record
    /// owned by the view would re-read from disk and blink every time the owner
    /// glanced at Settings and came back.
    static let shared = WindowConversation()

    /// Everything said here before the turns now on screen, oldest first.
    private(set) var messages: [TranscriptMessage] = []

    private let recordURL: URL
    private var record = WindowRecord()
    private var hasRestored = false
    /// A fixture never reads and never writes, by any route. A preview that
    /// persisted would save its carefully arranged screen over the owner's real
    /// record.
    private let isFixture: Bool

    init(recordURL: URL = WindowRecord.defaultFileURL()) {
        self.recordURL = recordURL
        self.isFixture = false
    }

    /// Preloaded, for previews.
    init(messages: [TranscriptMessage]) {
        self.recordURL = WindowRecord.defaultFileURL()
        self.isFixture = true
        self.messages = messages
    }

    /// Reads the record off disk, once per launch.
    func restore() async {
        guard !isFixture, !hasRestored else { return }
        let recordURL = self.recordURL
        let stored = await Task.detached(priority: .utility) {
            WindowRecord.load(from: recordURL)
        }.value
        hasRestored = true
        record = stored
        publish()
    }

    /// Writes down a finished turn.
    ///
    /// Only answered turns reach here. A question that failed or was stopped is
    /// half a turn, and half a turn in a record is a conversation that reads as
    /// though Mynah ignored somebody.
    /// **Deliberately does not `publish()`, and that is the whole fix for the
    /// echo.**
    ///
    /// `messages` is what the transcript draws as turns from *before* this
    /// window opened — its own doc comment says so. Publishing here appended
    /// the turn that had just finished, while `ConversationModel.exchanges`
    /// still held the same turn as a live one, so `TalkView.timeline` drew both
    /// and every question the owner asked appeared twice: once bare, once with
    /// its timing and tool line. Exactly what he screenshotted.
    ///
    /// The record on disk is still complete — `persist()` runs — so the turn is
    /// there at the next launch, and `priorMessages` reads the record rather
    /// than this list precisely so the engine is never told a shorter history
    /// than actually happened.
    func record(
        question: String,
        answer: String,
        askedAt: Date?,
        answeredAt: Date?,
        files: [URL] = []
    ) {
        guard !isFixture else { return }
        record.append(
            question: question,
            answer: answer,
            askedAt: askedAt,
            answeredAt: answeredAt,
            files: files
        )
        persist()
    }

    /// The owner emptying the window.
    ///
    /// Local by construction: this touches nothing but the window's own record,
    /// so their phone keeps every message. Saying so is the caller's job — see
    /// the line beside the button in `TalkView`.
    func clear() {
        guard !isFixture else { return }
        record.clear()
        persist()
        publish()
    }

    /// What the engine should be told about what came before.
    ///
    /// This window's own past and nothing else. It used to be the phone's
    /// conversation, which is what made the two surfaces one — and what made
    /// "why does the Mac know what I said on my phone but not the other way
    /// round" the owner's question.
    /// Read from the record rather than from `messages`, which stops at what was
    /// on disk when the window opened. The engine has to hear this session's
    /// turns too, or Mynah forgets the last thing it said the moment it says it.
    var priorMessages: [BrainMessage] {
        (isFixture ? messages : recordedMessages).map {
            BrainMessage(role: $0.speaker == .owner ? .user : .assistant, content: $0.text)
        }
    }

    /// The record as drawable messages, oldest first. One mapping, used by both
    /// what is shown and what the engine is told, so the two cannot drift.
    private var recordedMessages: [TranscriptMessage] {
        record.turns.enumerated().map { index, turn in
            TranscriptMessage(
                id: index,
                speaker: turn.speaker,
                text: turn.content,
                at: turn.at,
                // Only the ones still there. The owner may have moved the file
                // into a project folder or thrown it away, and a button that
                // opens nothing is worse than no button.
                files: (turn.files ?? [])
                    .map { URL(fileURLWithPath: $0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            )
        }
    }

    /// On the main actor, and on purpose: a write handed to a background task
    /// can land after an older one that was already in flight, and the version
    /// that loses is the owner's Clear — pressed, seen to work, and back the
    /// next time the app opens.
    private func persist() {
        do {
            try record.save(to: recordURL)
        } catch {
            conversationRecordLog.error(
                "could not write the window's conversation: \(String(describing: error))"
            )
        }
    }

    /// `@Observable` does not compare, it announces, so an identical assignment
    /// still invalidates every view reading this.
    private func publish() {
        let drawn = recordedMessages
        if drawn != messages { messages = drawn }
    }
}
