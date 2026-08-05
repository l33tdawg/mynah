import Foundation

/// A promise to come back, written down where a crash cannot take it.
///
/// ## What this exists to stop
///
/// 5 August 2026, 10:17:45 — the owner asks Signal a question. 10:17:51, the
/// appliance says *"I'm on it. It'll take a few minutes — I'll let you know the
/// moment it's done."* 10:17:54, the process traps inside WebKit and launchd
/// restarts it. Nothing ever reached his phone.
///
/// The appliance already had a safety net for this: `turnCeilingSeconds`
/// withdraws a promise out loud when a turn never comes back. It could not fire,
/// and the reason is the whole design here — **the process was gone**. A timer
/// held in memory cannot outlive the memory. Every existing guard against
/// silence assumed the daemon would still be alive to feel guilty, and the one
/// failure that produced actual silence was the one where it was not.
///
/// So the promise has to be on disk between the moment it is spoken and the
/// moment it is kept.
///
/// ## Why it is not in `conversations.json`
///
/// That file is persisted on three paths, none of which is the moment a working
/// line goes out; `ConversationStore.save` rewrites every thread on each call,
/// so a 200-byte promise would cost a full history rewrite on a hot path; and
/// both `save` and `purge` delete the file when nothing survives their six-hour
/// expiry, which would silently take a live promise with it.
public struct PromisedAnswer: Codable, Equatable, Sendable {

    /// Who is waiting. An account, never a group — group messages are refused at
    /// the security boundary in front of the daemon, so a promise can only ever
    /// be owed to a one-to-one thread.
    public var account: String

    /// The first part of what he asked, so the apology can name it.
    ///
    /// An excerpt rather than the whole message, for the same reason
    /// `AgentSendJournal.Entry.excerpt` is: this is a small recovery record, not
    /// a second copy of the conversation.
    public var question: String

    /// When the working line actually left the Mac — after the wire call
    /// returned, not when it was composed.
    ///
    /// **Whole seconds, and that is not cosmetic.** This value is part of the
    /// promise's identity, and identity is what `clear(ifStill:)` compares — so
    /// the in-memory promise and the one read back off disk have to be equal, or
    /// nothing ever clears. ISO-8601 carries no fractional seconds, so a `Date`
    /// stored with them comes back *different from itself*: every comparison
    /// fails, the record is never removed, and the appliance apologises for the
    /// same question on every single boot from then on.
    ///
    /// Caught by `testAPromiseSurvivesBeingWrittenAndReadBack`, which failed
    /// with the two values printing identically — the only visible difference
    /// being that one had been through the encoder.
    public var promisedAt: Date

    public static let longestQuestion = 120

    public init(account: String, question: String, promisedAt: Date) {
        self.account = account
        self.question = String(question.prefix(Self.longestQuestion))
        self.promisedAt = Date(timeIntervalSince1970: promisedAt.timeIntervalSince1970.rounded())
    }
}

/// Where the outstanding promise lives between two runs of the daemon.
///
/// One promise, not a queue. Turns are serialised, so the appliance can owe at
/// most one answer at a time; a file that can hold two would be modelling a
/// state that cannot occur.
public struct PromisedAnswerStore: Sendable {

    private let fileURL: URL

    /// Non-optional with a defaulted path, deliberately — the opposite of the
    /// `conversations:` parameter beside it.
    ///
    /// An optional defaulting to `nil` means any future construction that
    /// forgets to pass one silently gets the old behaviour, which here is
    /// "promise and then go quiet forever". The guard for tests belongs inside
    /// this type, not in a rule each call site has to remember.
    public init(fileURL: URL = PromisedAnswerStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("outstanding-promise.json")
    }

    /// Whether this process may touch the real file.
    ///
    /// Borrowed from `AgentSendJournal.mayWrite(to:isTesting:)`, and it guards
    /// **both** writing and clearing here. Guarding only the write — which is
    /// what the journal needs, since it never deletes — would leave a test that
    /// constructs `PromisedAnswerStore()` on the default path free to delete the
    /// owner's real outstanding promise. That is the exact failure this whole
    /// file exists to prevent, arriving from the test suite instead of from a
    /// crash.
    static func mayTouch(
        _ url: URL,
        isTesting: Bool = MynahLog.isRunningUnderXCTest
    ) -> Bool {
        guard isTesting else { return true }
        return url.standardizedFileURL != defaultFileURL().standardizedFileURL
    }

    /// Writes the promise. Never throws: a promise that cannot be recorded must
    /// not take down the turn that made it.
    public func record(_ promise: PromisedAnswer) {
        guard Self.mayTouch(fileURL) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(promise) else { return }
        try? OwnerOnlyFileSecurity.write(data, to: fileURL)
    }

    /// The promise a previous run left behind, if any.
    public func outstanding() -> PromisedAnswer? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PromisedAnswer.self, from: data)
    }

    /// Removes the record **only if it is still the one given**.
    ///
    /// ## Why there is no unconditional `clear()`
    ///
    /// Because a blind clear reproduces the bug, and the first draft of this
    /// feature had one. The record is durable and therefore crosses process
    /// boundaries, while every piece of reasoning about "is anything
    /// outstanding?" is about the *current* process. Those two came apart in
    /// nine places at once.
    ///
    /// Concretely: the daemon crashes at 10:17 owing an answer. It restarts and
    /// begins waiting for the Signal socket so it can apologise. In that window
    /// the owner — who has had no answer and no explanation — sends anything at
    /// all: a voice note it cannot read, a `//?`, a message while paused, a
    /// message that is too long. Each of those replies is classified `.answer`,
    /// each would have cleared the file, and the apology that was seconds away
    /// would never be sent. The owner is left exactly where he started, by the
    /// feature built to rescue him.
    ///
    /// The same hazard runs the other way: the recovery path must not delete a
    /// *new* promise made by a turn that started while it was still connecting.
    ///
    /// One rule removes both: nothing clears this file without saying which
    /// promise it believes it is clearing.
    public func clear(ifStill promise: PromisedAnswer) {
        guard Self.mayTouch(fileURL) else { return }
        guard outstanding() == promise else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
