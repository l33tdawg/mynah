import Foundation

/// **What the caller asked for during a call, to be done once the line drops.**
///
/// The owner's ruling, 5 August 2026: "calls cannot send files bro - calls are
/// for actionable things that happen AFTER the call - so you can request to say
/// send me this file after the call or do xyz and message agent abc etc - but
/// sending files should be done at the end".
///
/// So a call records the request and performs nothing. This is the record.
///
/// **A class with a lock, not an actor, and that is the whole design.**
/// `ToolProviding.call` is `async`, so an actor's `enqueue` would be a
/// suspension point and `Task.cancel()` could land between the model deciding
/// to queue something and the queue holding it. The window is small and it is
/// exactly the window that matters: the caller says "send me that after this"
/// and hangs up, which cancels the turn. A non-suspending write is the only
/// shape where the record cannot be lost there. `NotesToolSource.deliver(_:)`
/// is synchronous for the same stated reason, and `OwnTaskEdits.record()` sits
/// above the `Task.isCancelled` guard in the daemon for the same one.
///
/// Deliberately **not** `AgentSendJournal`, which is the closest-looking thing.
/// Its doc states the opposite contract — "That is a diagnostic, not a
/// recovery. Nothing here resends on startup, and deliberately" — and it caps
/// itself at fifty entries with `suffix(50)`. A deliberate queue and a
/// diagnostic tail must not share a file, and a queue that silently drops its
/// oldest entry is a promise the appliance forgets it made.
public final class CallActionQueue: @unchecked Sendable {

    /// **Which call, and which turn of it, asked for this.**
    ///
    /// Not decoration: it is the guard that stops an abandoned turn from
    /// filing into the next call. `withDeadline` runs the model turn in an
    /// unstructured task and walks away from it — the caller is handed
    /// `DeadlineExceeded` while the orphan is still parked, and `MCPClient`
    /// reads the node's pipe with no deadline at all, so the orphan can come
    /// back minutes later. `ToolLoop` walks its tool calls with no cancellation
    /// check, so when it does come back it still dispatches them.
    ///
    /// Without this, the sequence is: call A wedges, the caller hears
    /// `tookTooLong` and hangs up, redials, and four minutes into call B the
    /// orphan unwedges and queues call A's request against call B — which then
    /// performs it and writes it into call B's transcript, for a call the owner
    /// was told had failed. A "is a call open?" check passes in exactly that
    /// window, which is why the token names the call rather than asking whether
    /// one exists.
    public struct Generation: Equatable, Sendable, Codable {
        public let call: String
        public let turn: Int

        public init(call: String, turn: Int) {
            self.call = call
            self.turn = turn
        }
    }

    /// The generation of the turn currently being answered.
    ///
    /// A task-local because that is the one mechanism with the right
    /// inheritance: an unstructured `Task {}` inherits it, so it propagates
    /// into `withDeadline`'s worker and is still correct when the orphan wakes;
    /// a `Task.detached` does **not**, which is exactly right for the drain,
    /// since the drain must never be able to enqueue.
    @TaskLocal public static var current: Generation?

    public enum Kind: String, Codable, Sendable {
        case file
        case agent
        case instruction
    }

    /// **Claimed, not cleared.**
    ///
    /// The obvious design takes the entries at hang-up and empties the file.
    /// Then the only copy of the owner's queued work lives in a detached task's
    /// memory — and process death here is routine, not exotic: launchd SIGTERMs
    /// this daemon on every reconcile, and its own exit path runs
    /// `exit(await body())` with no unwind for a detached task. The appliance
    /// would have posted "I'll send you three files" into the owner's thread
    /// with nothing on disk and no path that would ever mention it again.
    ///
    /// So a claim marks; only a confirmed outcome deletes. Anything found
    /// `draining` at startup is work this process was in the middle of when it
    /// died, and it is reported to the owner rather than performed.
    public enum State: String, Codable, Sendable {
        case queued
        case draining
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// Minted at enqueue and persisted, which is the whole idempotency
        /// story: a re-drain of the same entry presents the same key, and SAGE
        /// answers with the original `message_id` instead of sending twice.
        /// Both existing call sites mint a fresh key per attempt, which is
        /// right for them and wrong for a queue.
        public let key: String
        public let generation: Generation
        public let kind: Kind
        public let what: String
        /// The agent as the caller said it — never a wire address.
        /// `AgentAddress.init` is internal precisely so a stored address cannot
        /// skip the resolve, and resolving at drain time is what gets the
        /// ambiguity refusal that the 1ab7aa10/74140c2d mix-up lacked.
        public let who: String?
        /// The caller's own sentence, for the line the owner reads.
        public let asked: String
        public let queued: Date
        public var state: State

        public init(
            key: String,
            generation: Generation,
            kind: Kind,
            what: String,
            who: String?,
            asked: String,
            queued: Date,
            state: State = .queued
        ) {
            self.key = key
            self.generation = generation
            self.kind = kind
            self.what = what
            self.who = who
            self.asked = asked
            self.queued = queued
            self.state = state
        }

        /// One short line for the transcript. Bounded on purpose — see
        /// `CallTranscript.queued(_:)`, where an unbounded line can push the
        /// whole closing summary over its budget and erase it.
        public var spokenLine: String {
            switch kind {
            case .file: return "send you \(what)"
            case .agent: return "message \(who ?? "them") for you"
            case .instruction: return what
            }
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var liveCall: String?

    /// Non-optional with a defaulted path, copying `PromisedAnswerStore`'s
    /// reasoning: an optional defaulting to nil means any future construction
    /// that forgets to pass one silently gets the old behaviour, which here is
    /// "promise on a call and never do it".
    public init(fileURL: URL = CallActionQueue.defaultFileURL()) {
        self.fileURL = fileURL
        self.entries = Self.read(fileURL)
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("after-the-call.json", isDirectory: false)
    }

    /// Guards writing **and** deleting, not just writing — a test that
    /// constructs `CallActionQueue()` on the default path must not be able to
    /// delete work the owner really queued.
    static func mayTouch(
        _ url: URL,
        isTesting: Bool = MynahLog.isRunningUnderXCTest
    ) -> Bool {
        guard isTesting else { return true }
        return url.standardizedFileURL != defaultFileURL().standardizedFileURL
    }

    // MARK: - The call's own lifecycle

    /// Opens a call. Anything already on disk belongs to an earlier call or an
    /// earlier process and is not adopted by this one.
    public func beginCall(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        liveCall = id
    }

    /// Closes a call without taking anything — the daemon-shutdown exit, where
    /// no drain will run. The entries stay on disk and come back as abandoned.
    public func closeCall() {
        lock.lock()
        defer { lock.unlock() }
        liveCall = nil
    }

    // MARK: - Writing

    /// Records a request. Returns nil when the generation is not the live
    /// call's, which is the refusal that stops a late orphan queueing into a
    /// call it was not part of.
    public func enqueue(
        generation: Generation,
        kind: Kind,
        what: String,
        who: String?,
        asked: String,
        now: Date = Date()
    ) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let live = liveCall, generation.call == live else { return nil }
        let entry = Entry(
            key: AgentSendJournal.newKey(),
            generation: generation,
            kind: kind,
            what: what,
            who: who,
            asked: asked,
            queued: now
        )
        entries.append(entry)
        persistLocked()
        return entry
    }

    /// **Changing your mind mid-sentence is ordinary in speech.**
    ///
    /// "send me the budget after this — no wait, forget that, send the Q3 deck
    /// instead" is the natural register of the thing the ruling describes. An
    /// append-only queue performs both, and the owner can see in the posted
    /// transcript that the appliance ignored him.
    ///
    /// Only this call's own still-queued entries can be retracted: an entry
    /// already claimed by a drain is past the point where taking it back means
    /// anything.
    @discardableResult
    public func forget(generation: Generation) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let live = liveCall, generation.call == live else { return 0 }
        let before = entries.count
        entries.removeAll { $0.generation.call == live && $0.state == .queued }
        let dropped = before - entries.count
        if dropped > 0 { persistLocked() }
        return dropped
    }

    // MARK: - Reading

    /// How many this turn has queued, for the spoken backstop.
    ///
    /// Per-generation rather than a process-wide counter. A shared counter
    /// would report an orphan's enqueue against whichever turn happens to be
    /// running, which is precisely backwards — the same defect `FillerTally`
    /// was made a per-turn box for.
    public func queued(inTurn generation: Generation) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.generation == generation && $0.state == .queued }.count
    }

    /// Whether this call has queued anything at all, in any turn.
    ///
    /// **Deliberately the whole call and not the turn**, because it backs the
    /// opposite check and the two want opposite scopes. Adding a promise wants
    /// the turn: something was queued *just now* and the caller should hear
    /// about it. Contradicting one wants the call: the model saying "yes, I'll
    /// send that after we hang up" in turn five about something it queued in
    /// turn three is ordinary speech, and calling that a broken promise would
    /// be the appliance contradicting a promise it is in fact going to keep.
    ///
    /// Nothing queued anywhere on the call is the unambiguous case, and it is
    /// the one that shipped.
    ///
    /// `draining` counts. By the time the drain is running the promise is being
    /// kept, so an entry in that state is evidence for the promise, not against
    /// it.
    public func anythingQueued(onCall call: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.generation.call == call }
    }

    /// Takes ownership of everything, marking it `draining` rather than
    /// deleting it, and splits it into this call's work and everything else.
    ///
    /// One lock acquisition: the partition, the mark and the write are one
    /// step, so nothing can enqueue into the gap. Removal-is-the-read, the
    /// `OwnTaskEdits` rule.
    ///
    /// Pass nil for `call` at startup, where nothing is live and therefore
    /// everything found is abandoned.
    public func claim(forCall call: String?) -> (mine: [Entry], abandoned: [Entry]) {
        lock.lock()
        defer { lock.unlock() }

        var mine: [Entry] = []
        var abandoned: [Entry] = []
        for index in entries.indices {
            entries[index].state = .draining
            if let call, entries[index].generation.call == call {
                mine.append(entries[index])
            } else {
                abandoned.append(entries[index])
            }
        }
        liveCall = nil
        if !entries.isEmpty { persistLocked() }
        return (mine, abandoned)
    }

    /// Deletes one entry. The only thing that deletes, and it runs only on a
    /// confirmed outcome — an entry left behind is work whose fate was never
    /// learned, and that is the state worth keeping.
    public func remove(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        let before = entries.count
        entries.removeAll { $0.key == entry.key }
        if entries.count != before { persistLocked() }
    }

    public func everything() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    // MARK: - Disk

    private static func read(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    /// Never throws. A queue that cannot be written must not take down the turn
    /// that wrote to it — but it must say so, because the promise has already
    /// been made out loud by then.
    private func persistLocked() {
        guard Self.mayTouch(fileURL) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? OwnerOnlyFileSecurity.write(data, to: fileURL)
    }
}
