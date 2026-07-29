import CryptoKit
import Foundation
import Observation
import OSLog
import SageVoiceCore
import SwiftUI

// MARK: - One message in the real conversation

/// A single thing that was said, ready to draw.
///
/// No time on it, and there cannot be one: the daemon keeps a single stamp per
/// conversation, not per turn, so anything shown beside an individual message
/// would be a number this app made up.
struct MirroredMessage: Identifiable, Equatable, Sendable {

    enum Speaker: Equatable, Sendable {
        case owner
        case mynah
    }

    /// Where the message sits in the thread.
    ///
    /// Position rather than content, because the same words are said twice —
    /// "thanks", "ok" — and two rows with one identity is a `ForEach` that draws
    /// one of them. The window's record only appends, so a position holds still
    /// while anyone is looking at it; the one exception is the cap, where the
    /// oldest messages fall off and the list renumbers once. That is a rebuild
    /// every four hundred messages, against hashing every sentence on every
    /// poll for the rest of the conversation.
    let id: Int
    let speaker: Speaker
    let text: String
}

// MARK: - The window's own copy

/// One turn as the window keeps it, in the daemon's own spelling of the roles so
/// nothing is translated twice on the way to disk.
struct RecordedTurn: Codable, Equatable, Sendable {
    var role: String
    var content: String

    init(_ turn: ConversationStore.DisplayTurn) {
        self.role = turn.speaker == .owner ? "user" : "assistant"
        self.content = turn.content
    }

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    var speaker: MirroredMessage.Speaker { role == "user" ? .owner : .mynah }
}

/// Everything this window has been shown, which is not the same thing as what
/// the daemon is still holding.
///
/// The owner drew the line themselves: "if user clears it, it doesn't clear here
/// but you can clear here without clearing in Signal". So the mirror is one-way
/// and destroys nothing in either direction. Rendering `conversations.json`
/// directly would have broken half of that by accident — it is the daemon's
/// *resumable* history, it expires after six hours, it keeps only the last
/// sixteen turns and it is rewritten on every turn, so a window drawn straight
/// from it would empty itself the moment the appliance tidied up, and the owner
/// would have lost their record because a background process trimmed its
/// working memory.
///
/// So that file is read as an **inbox**: whatever is new in it is appended here,
/// and nothing already appended is ever removed by anything except the owner.
///
/// The cost, stated plainly because it is a real one: this holds the owner's
/// words with no expiry, where the daemon's copy deliberately has one. It is
/// written 0600 like their keys and their notes, it is capped, and the button in
/// the window genuinely erases it.
struct WindowTranscript: Codable, Equatable, Sendable {

    /// How many messages a conversation keeps here.
    ///
    /// Append-only cannot mean unbounded. This is the owner's plaintext with no
    /// expiry on it — the one place in the product that keeps their words
    /// indefinitely — so a record that grows for a year is a bigger thing to
    /// lose than one that holds a season of talking. Four hundred messages is
    /// roughly two hundred exchanges: months at the handful-of-voice-notes-a-day
    /// this appliance actually sees, and about a megabyte at worst.
    ///
    /// The oldest go first, which is both the honest direction — a transcript
    /// missing its beginning still reads — and the end nobody scrolls back to.
    static let maximumTurnsPerThread = 400

    /// How many digests are kept for matching. The daemon holds sixteen turns,
    /// so anything past a handful is already slack; sixty-four means a poll that
    /// arrives after several missed turns still finds its overlap.
    static let maximumDigestsPerThread = 64

    /// Named for what it holds rather than `Thread`, which is a Foundation
    /// type a reader would have to check twice.
    struct Conversation: Codable, Equatable, Sendable {
        /// What the window shows. Emptied by the owner, never by the daemon.
        var turns: [RecordedTurn] = []
        /// Fingerprints of everything ever taken in, in the order it arrived.
        ///
        /// Digests rather than the words, for two reasons. The owner clearing
        /// the window has to actually remove their sentences from disk — but
        /// something must survive that, or the next poll would find the same
        /// conversation still sitting in the daemon's file and put every message
        /// straight back three seconds later. A digest is enough to recognise a
        /// turn the window has already seen and is not the turn.
        var seen: [String] = []
        /// The daemon's own stamp for this conversation, as it read at the last
        /// append. Used to decide which conversation is the current one and
        /// where it sits against something typed in the window — never drawn
        /// beside a message, because it belongs to the thread and not to any
        /// turn in it.
        var lastActivity: Date?
    }

    var threads: [String: Conversation] = [:]

    // MARK: Taking in what is new

    /// Appends whatever the daemon has that this window has not seen, and says
    /// whether anything changed.
    ///
    /// Nothing is removed here, ever: a conversation missing from `snapshot`
    /// has been trimmed, expired, or cleared on the phone, and none of those is
    /// the owner asking this window to forget it.
    ///
    /// One thing this cannot recover: a window shut while more than sixteen
    /// turns went by comes back to a file whose oldest turns are already gone,
    /// so the record gains a gap. A gap is the honest outcome — the alternative
    /// is guessing at sentences nobody kept.
    mutating func ingest(_ snapshot: [ConversationStore.DisplayThread]) -> Bool {
        var changed = false
        for thread in snapshot {
            let arriving = thread.turns.map(RecordedTurn.init)
            let digests = arriving.map(Self.digest)
            var recorded = threads[thread.id] ?? Conversation()

            let known = Self.overlap(between: recorded.seen, and: digests)
            if known < arriving.count {
                recorded.turns.append(contentsOf: arriving.dropFirst(known))
                recorded.seen.append(contentsOf: digests.dropFirst(known))
                recorded.turns = Array(recorded.turns.suffix(Self.maximumTurnsPerThread))
                recorded.seen = Array(recorded.seen.suffix(Self.maximumDigestsPerThread))
                changed = true
            }
            // The stamp moves even when no words did: a conversation the owner
            // spoke in a minute ago is the current one whether or not this poll
            // was the one that caught the new turn.
            if recorded.lastActivity != thread.lastActivity {
                recorded.lastActivity = thread.lastActivity
                changed = true
            }
            threads[thread.id] = recorded
        }
        return changed
    }

    /// How many messages at the front of `arriving` this window has already
    /// recorded.
    ///
    /// The daemon's file is a sliding window over one conversation: every poll
    /// returns most of what the last poll returned, with anything new on the
    /// end, and the oldest turns fall off the front as it fills. Turns carry no
    /// id and no time — only a role and a sentence — so the only honest way to
    /// tell "already seen" from "said again" is to match *runs* rather than
    /// individual messages: the longest tail of what is recorded that is also
    /// the head of what has arrived.
    ///
    /// Matching messages one at a time would be wrong in a way the owner would
    /// notice, because people repeat themselves. "ok" said twice is two
    /// messages, and a set of seen sentences would swallow the second one.
    ///
    /// The longest overlap rather than the first found, because a short repeated
    /// phrase can match in more than one place and only the longest run can be
    /// the one the file is actually sliding along.
    static func overlap(between seen: [String], and arriving: [String]) -> Int {
        var length = min(seen.count, arriving.count)
        while length > 0 {
            if Array(seen.suffix(length)) == Array(arriving.prefix(length)) { return length }
            length -= 1
        }
        return 0
    }

    /// A turn's fingerprint. Role included, so an answer that quotes the
    /// question back is not mistaken for the question.
    static func digest(_ turn: RecordedTurn) -> String {
        let material = Data("\(turn.role)\u{0}\(turn.content)".utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: What the owner cleared

    /// Removes the words from every conversation and keeps the fingerprints.
    ///
    /// Both halves are the point. The words go because "clear" has to mean the
    /// sentences are gone from this Mac, not hidden. The fingerprints stay
    /// because the daemon's file still holds that conversation, and without them
    /// the very next poll would decide all of it was new and put it back — a
    /// clear button that undoes itself after three seconds.
    mutating func clearWhatIsShown() {
        for key in threads.keys {
            threads[key]?.turns = []
            // The conversation is no longer on screen, so it is no longer the
            // one the window is showing. Left in place, a cleared thread would
            // still win "most recently spoken in" and keep an empty pane
            // pointed at itself.
            threads[key]?.lastActivity = nil
        }
    }

    /// The conversation to show: the one most recently spoken in that still has
    /// anything in it.
    ///
    /// One at a time, deliberately. Interleaving two people into a single column
    /// with nothing but a phone number to tell them apart is not a transcript;
    /// the appliance answers one owner, and this is that owner's thread.
    var current: (id: String, conversation: Conversation)? {
        let candidates = threads.filter { !$0.value.turns.isEmpty }
        guard !candidates.isEmpty else { return nil }
        let best = candidates.sorted { first, second in
            let firstStamp = first.value.lastActivity ?? .distantPast
            let secondStamp = second.value.lastActivity ?? .distantPast
            // The key breaks a tie so the choice never wobbles between two reads
            // of an unchanged file.
            if firstStamp == secondStamp { return first.key < second.key }
            return firstStamp > secondStamp
        }
        guard let winner = best.first else { return nil }
        return (id: winner.key, conversation: winner.value)
    }

    // MARK: Where it lives

    /// Its own file beside the daemon's rather than inside it, because the two
    /// answer to different people: `conversations.json` is the appliance's
    /// working memory and the appliance prunes it, while this is the owner's
    /// record and only the owner empties it. Two writers on one file would put
    /// those two rules in permanent disagreement.
    ///
    /// Same shape as `CallPreferences` — a `Codable` value that knows its own
    /// path, loads without throwing and writes owner-only — so this is one more
    /// file in a pattern the project already has rather than a new mechanism.
    static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("window-transcript.json", isDirectory: false)
    }

    /// Never throws. A record that will not parse should cost the owner their
    /// history, not their ability to open the window — and the conversation
    /// starts filling back up from the daemon's copy on the very next poll.
    static func load(from url: URL = WindowTranscript.defaultFileURL()) -> WindowTranscript {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(WindowTranscript.self, from: data) else {
            return WindowTranscript()
        }
        return stored
    }

    /// Owner-only from the first byte, like the daemon's copy and for the same
    /// reason: these are the owner's own words, not a preference.
    ///
    /// Not `.prettyPrinted`, which `CallPreferences` uses and earns — that file
    /// is a dozen lines someone may open and edit. This one is hundreds of
    /// messages nobody reads by hand, and the indentation would be most of it.
    func save(to url: URL = WindowTranscript.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }
}

// MARK: - The conversation, mirrored from where it actually happens

private let mirrorLog = MynahLog(category: "mirror")

/// What the owner and Mynah said to each other on the phone.
///
/// The appliance's real conversation is on Signal: a voice note goes out from
/// the phone and the answer comes back there. This window used to hold its own
/// separate chat, which meant two conversations that never met — the owner could
/// ask something on their phone, get an answer, walk over to the Mac and find a
/// screen that knew nothing about it.
///
/// So the window shows that conversation instead. It reads the daemon's file and
/// writes nothing to it: Mynah has no business reaching into the owner's
/// messages, and clearing a window must never delete a person's chat history.
/// The other direction holds too — see `WindowTranscript`, which is why what is
/// on screen survives the daemon trimming, expiring, or the owner clearing the
/// thread on their phone.
@MainActor
@Observable
final class ConversationMirror {

    /// The conversation outlives the pane, like `ConversationModel.shared` and
    /// for the same reason: `MainShell` destroys the branch it is not showing,
    /// so a mirror owned by the view would re-read from an empty state and blink
    /// every time the owner glanced at Settings and came back.
    static let shared = ConversationMirror()

    /// How often the daemon's file is re-read while the window is on screen.
    ///
    /// There is no channel between the daemon and this app — the same reason
    /// `PauseState` is a file — so polling is the whole mechanism. Three seconds
    /// is far inside the time it takes someone to put their phone down and look
    /// at the Mac, and the file is a few kilobytes of JSON the OS has cached.
    static let refreshInterval: Duration = .seconds(3)

    /// The current conversation, oldest message first.
    private(set) var messages: [MirroredMessage] = []

    /// When that conversation was last spoken in. `nil` when there is nothing to
    /// show — a fresh install has no file at all, which is not a failure.
    private(set) var lastActivity: Date?

    private let store: ConversationStore
    /// Where the window's own record lives. Injected so a test can point it at
    /// a temporary directory rather than at the owner's real conversation.
    private let recordURL: URL
    private var transcript = WindowTranscript()
    /// Whether the window's record has been read off disk yet. Read once per
    /// launch rather than on every poll: the daemon writes the inbox, nothing
    /// but this app writes the record.
    private var hasRestored = false
    /// Whether this mirror was handed its conversation instead of reading one.
    ///
    /// A fixture never reads and never writes, by any route. A preview that
    /// polled would replace its own carefully arranged screen, within three
    /// seconds, with whatever happens to be saved on the machine the preview is
    /// open on — and would save that back over the owner's real record.
    private let isFixture: Bool

    init(
        store: ConversationStore = ConversationStore(),
        recordURL: URL = WindowTranscript.defaultFileURL()
    ) {
        self.store = store
        self.recordURL = recordURL
        self.isFixture = false
    }

    /// Preloaded, for previews. Nothing in the app builds one of these: the
    /// whole point of the type is that the conversation is not invented here.
    init(messages: [MirroredMessage], lastActivity: Date? = nil) {
        self.store = ConversationStore()
        self.recordURL = WindowTranscript.defaultFileURL()
        self.isFixture = true
        self.messages = messages
        self.lastActivity = lastActivity
    }

    /// Reads once and then keeps reading until the caller's task is cancelled,
    /// which SwiftUI does when the pane goes away — so nothing polls while the
    /// owner is in Settings.
    func follow() async {
        guard !isFixture else { return }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// One pass: whatever the window already had, plus whatever the daemon has
    /// heard since.
    func refresh() async {
        guard !isFixture else { return }
        let store = self.store
        let recordURL = self.recordURL
        let mustRestore = !hasRestored

        // Only the reading is off the main actor. It happens every few seconds
        // for as long as the window is open, and the main thread is drawing a
        // transcript someone is reading.
        let read = await Task.detached(priority: .utility) {
            (record: mustRestore ? WindowTranscript.load(from: recordURL) : nil, snapshot: store.threadsForDisplay())
        }.value

        if let restored = read.record, !hasRestored { transcript = restored }
        hasRestored = true
        if read.snapshot.count > 1 {
            mirrorLog.debug("showing 1 of \(read.snapshot.count) saved conversations")
        }

        // Merged here rather than inside the read, and this is load-bearing: the
        // owner can press Clear while a poll is in flight, and a copy taken
        // before that press landing on top of it afterwards is a clear that
        // quietly undoes itself.
        if transcript.ingest(read.snapshot) { persist() }
        publish()
    }

    /// The owner emptying the window, and nothing more than that.
    ///
    /// Local by construction: this touches the window's own record and never the
    /// daemon's file, so their phone keeps every message. Saying so is the
    /// caller's job — see the line beside the button in `TalkView`.
    func clear() {
        guard !isFixture else { return }
        transcript.clearWhatIsShown()
        persist()
        publish()
    }

    /// Written where it is decided.
    ///
    /// On the main actor, and on purpose: a write handed to a background task
    /// can land after an older one that was already in flight, and the version
    /// that loses is the owner's Clear — pressed, seen to work, and back the
    /// next time the app opens. This is a few kilobytes of JSON, written only
    /// when something was actually said.
    ///
    /// A failure is worth one line and nothing else. The window is already
    /// showing the conversation; a record that could not be written costs the
    /// owner their history across a restart, not the screen in front of them.
    private func persist() {
        do {
            try transcript.save(to: recordURL)
        } catch {
            mirrorLog.error(
                "could not write the window's transcript: \(String(describing: error))"
            )
        }
    }

    /// Assigning an identical value is not free: `@Observable` does not compare,
    /// it announces — so writing the same conversation back over itself every
    /// three seconds would invalidate the transcript around the clock, for a
    /// conversation nobody has added to.
    private func publish() {
        guard let current = transcript.current else {
            if !messages.isEmpty { messages = [] }
            if lastActivity != nil { lastActivity = nil }
            return
        }
        let drawn = current.conversation.turns.enumerated().map { index, turn in
            MirroredMessage(id: index, speaker: turn.speaker, text: turn.content)
        }
        if drawn != messages { messages = drawn }
        if current.conversation.lastActivity != lastActivity {
            lastActivity = current.conversation.lastActivity
        }
    }
}
