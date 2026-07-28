import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The window showing the conversation that actually happened.
///
/// The owner's words: "instead of it being fully chat, it should show what
/// messages it received and its reply — like a copy of the Signal Note-to-Self
/// channel". Before this, the Mac window kept its own separate chat: a voice
/// note sent from the phone and answered on the phone left no trace on the
/// screen that is supposed to be the appliance's face.
final class ConversationDisplayReadTests: XCTestCase {

    private var directory: URL!
    private var file: URL!
    private var store: ConversationStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conversation-display-\(UUID().uuidString)", isDirectory: true)
        file = directory.appendingPathComponent("conversations.json")
        store = ConversationStore(fileURL: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let thread = "+60123821767"

    // MARK: What the window shows

    func testTheWindowShowsWhatWasSaidAndWhoSaidIt() throws {
        try store.save([
            thread: [
                .user("remind me what the roofer said"),
                .assistant("He quoted two and a half thousand and said he could start next week.")
            ]
        ])

        let threads = store.threadsForDisplay()
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.turns.count, 2)
        XCTAssertEqual(threads.first?.turns.first?.speaker, .owner)
        XCTAssertEqual(threads.first?.turns.first?.content, "remind me what the roofer said")
        XCTAssertEqual(threads.first?.turns.last?.speaker, .mynah)
        XCTAssertEqual(threads.first?.id, thread)
    }

    /// Oldest at the top, as a messaging app draws it. Getting this backwards
    /// would put the answer above the question it answers.
    func testTurnsComeBackInTheOrderTheyWereSaid() throws {
        try store.save([
            thread: [
                .user("one"),
                .assistant("two"),
                .user("three"),
                .assistant("four")
            ]
        ])

        XCTAssertEqual(
            store.threadsForDisplay().first?.turns.map(\.content),
            ["one", "two", "three", "four"]
        )
    }

    /// The window has one column, so when there is more than one conversation
    /// the caller shows the first. It has to be the one spoken in most recently.
    func testTheMostRecentConversationComesFirst() throws {
        let now = Date()
        try store.save(["+A": [.user("older"), .assistant("ok")]], now: now.addingTimeInterval(-3_600))
        var carried = store.load(now: now)
        carried["+B"] = [.user("newer"), .assistant("ok")]
        try store.save(carried, now: now)

        XCTAssertEqual(store.threadsForDisplay().first?.id, "+B")
        XCTAssertEqual(store.threadsForDisplay().count, 2)
    }

    // MARK: Why this is not `load(now:)`

    /// Six hours is right for deciding what the appliance may carry into the
    /// next turn and wrong for deciding what a person may look at. A window that
    /// emptied itself overnight would read as broken, not tidy.
    func testAConversationOlderThanTheResumeWindowStillShows() throws {
        try store.save(
            [thread: [.user("shops in Chiang Mai"), .assistant("here they are")]],
            now: Date().addingTimeInterval(-48 * 60 * 60)
        )

        XCTAssertEqual(
            store.threadsForDisplay().first?.turns.count,
            2,
            "the window went blank on a conversation that is still on disk"
        )
    }

    /// A read that deletes what it read would be a window that erases the
    /// appliance's memory by being looked at. Expiry belongs to `load`, which
    /// the daemon calls, and stays there.
    func testShowingAConversationNeverDeletesIt() throws {
        try store.save(
            [thread: [.user("my landlord's bank details are 1234"), .assistant("noted")]],
            now: Date().addingTimeInterval(-48 * 60 * 60)
        )

        _ = store.threadsForDisplay()

        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.contains("landlord"), "a display read removed the owner's words")
    }

    /// And the daemon's side is untouched: the same file the window still shows
    /// is still expired for resuming.
    func testResumingIsStillGovernedByTheSixHourWindow() throws {
        try store.save(
            [thread: [.user("shops in Chiang Mai"), .assistant("here they are")]],
            now: Date().addingTimeInterval(-48 * 60 * 60)
        )

        XCTAssertFalse(store.threadsForDisplay().isEmpty)
        XCTAssertTrue(store.load(now: Date()).isEmpty, "expiry stopped applying to the daemon's read")
    }

    // MARK: Robustness

    /// A cache file that will not parse is worth an empty window and one log
    /// line. The owner's Mac must not be unable to draw a screen because of it.
    func testAMalformedFileIsAnEmptyWindowRatherThanACrash() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for junk in ["{ not json at all", "", "[]", "{\"savedAt\": \"tuesday\"}", "\u{0}\u{1}\u{2}"] {
            try Data(junk.utf8).write(to: file)
            XCTAssertTrue(
                store.threadsForDisplay().isEmpty,
                "a file containing \(junk.debugDescription) did not read as an empty window"
            )
        }
    }

    /// Truncated mid-write, which is what a `pkill` during a deploy produces.
    func testAHalfWrittenFileIsAnEmptyWindow() throws {
        try store.save([thread: [.user("hello"), .assistant("hi there")]])
        let whole = try Data(contentsOf: file)
        try whole.prefix(whole.count / 2).write(to: file)

        XCTAssertTrue(store.threadsForDisplay().isEmpty)
    }

    /// A fresh install has no file at all. That is the ordinary first-run state,
    /// not a failure.
    func testNoFileAtAllIsAnEmptyWindow() {
        XCTAssertTrue(store.threadsForDisplay().isEmpty)
    }

    /// Nothing but this type writes the file, so a role it never writes is a
    /// corrupted or hand-edited one. Dropping the turn beats guessing who spoke.
    func testATurnFromNobodyIsDroppedAndDoesNotTakeTheThreadWithIt() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "savedAt": Date().timeIntervalSinceReferenceDate,
            "conversations": [
                thread: [
                    "savedAt": Date().timeIntervalSinceReferenceDate,
                    "turns": [
                        ["role": "system", "content": "you are SAGE"],
                        ["role": "user", "content": "what did we agree"],
                        ["role": "tool", "content": "Task 41: rotate the Gemini key"],
                        ["role": "assistant", "content": "Dinner at seven."]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        let turns = store.threadsForDisplay().first?.turns ?? []
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.map(\.content), ["what did we agree", "Dinner at seven."])
    }

    /// A thread whose every turn was dropped is not an empty conversation to
    /// draw — it is nothing at all.
    func testAThreadWithNothingSayableDoesNotAppear() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "savedAt": Date().timeIntervalSinceReferenceDate,
            "conversations": [
                thread: [
                    "savedAt": Date().timeIntervalSinceReferenceDate,
                    "turns": [["role": "system", "content": "you are SAGE"]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        XCTAssertTrue(store.threadsForDisplay().isEmpty)
    }

    /// A file written by the previous version has no per-thread stamp. It must
    /// still be readable, or an upgrade shows an owner a blank window and their
    /// conversation is still on disk behind it.
    func testAFileFromThePreviousVersionStillShows() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "savedAt": Date().timeIntervalSinceReferenceDate,
            "threads": [thread: [["role": "user", "content": "legacy turn"]]]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        XCTAssertEqual(store.threadsForDisplay().first?.turns.first?.content, "legacy turn")
    }

    /// One stamp per conversation is all the file has, so that is all the window
    /// may ever claim. Nothing here hands out a time per message.
    func testTheOnlyTimeOfferedIsTheOneTheFileKeeps() throws {
        let spokenAt = Date().addingTimeInterval(-900)
        try store.save([thread: [.user("hello"), .assistant("hi")]], now: spokenAt)

        let thread = try XCTUnwrap(store.threadsForDisplay().first)
        XCTAssertEqual(thread.lastActivity.timeIntervalSince1970, spokenAt.timeIntervalSince1970, accuracy: 1)
    }
}

// MARK: - The window's own record

/// The semantics the owner spelled out: "if user clears it, it doesn't clear
/// here but you can clear here without clearing in Signal".
///
/// One-way and destructive in neither direction. Mynah never writes to their
/// messages, and their messages never delete what this window is holding — which
/// rules out drawing the daemon's file directly, since that file expires, trims
/// to sixteen turns and is rewritten on every turn.
@MainActor
final class ConversationMirrorTests: XCTestCase {

    private var directory: URL!
    private var inbox: URL!
    private var record: URL!
    private var store: ConversationStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conversation-mirror-\(UUID().uuidString)", isDirectory: true)
        inbox = directory.appendingPathComponent("conversations.json")
        record = directory.appendingPathComponent("window-transcript.json")
        store = ConversationStore(fileURL: inbox)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let thread = "+60123821767"

    private func makeMirror() -> ConversationMirror {
        ConversationMirror(store: store, recordURL: record)
    }

    // MARK: Showing the real conversation

    func testTheWindowShowsWhatWasSaidOnThePhone() async throws {
        try store.save([
            thread: [.user("did I ever send that email"), .assistant("Not that I know of.")]
        ])

        let mirror = makeMirror()
        await mirror.refresh()

        XCTAssertEqual(mirror.messages.map(\.text), ["did I ever send that email", "Not that I know of."])
        XCTAssertEqual(mirror.messages.first?.speaker, .owner)
        XCTAssertEqual(mirror.messages.last?.speaker, .mynah)
        XCTAssertNotNil(mirror.lastActivity)
    }

    /// The whole point of polling: an answer given on the phone appears in a
    /// window that is already open, without the owner restarting anything.
    func testAnAnswerGivenOnThePhoneAppearsInAnOpenWindow() async throws {
        try store.save([thread: [.user("what's on my list"), .assistant("Three things.")]])
        let mirror = makeMirror()
        await mirror.refresh()
        XCTAssertEqual(mirror.messages.count, 2)

        try store.save([
            thread: [
                .user("what's on my list"),
                .assistant("Three things."),
                .user("which of those can wait"),
                .assistant("The car service runs itself.")
            ]
        ])
        await mirror.refresh()

        XCTAssertEqual(mirror.messages.count, 4)
        XCTAssertEqual(mirror.messages.last?.text, "The car service runs itself.")
    }

    // MARK: Deduplication

    /// Every poll returns most of what the last one returned. Turns carry no id
    /// and no time, so this is the claim the whole design rests on.
    func testPollingTheSameConversationDoesNotRepeatIt() async throws {
        try store.save([thread: [.user("hello"), .assistant("hi there")]])
        let mirror = makeMirror()

        for _ in 0..<5 { await mirror.refresh() }

        XCTAssertEqual(mirror.messages.map(\.text), ["hello", "hi there"])
    }

    /// People repeat themselves, and "ok" said twice is two messages. A set of
    /// seen sentences would have swallowed the second one.
    func testTheSameWordsSaidTwiceAreTwoMessages() async throws {
        try store.save([thread: [.user("ok"), .assistant("ok")]])
        let mirror = makeMirror()
        await mirror.refresh()

        try store.save([thread: [.user("ok"), .assistant("ok"), .user("ok")]])
        await mirror.refresh()

        XCTAssertEqual(mirror.messages.count, 3)
        XCTAssertEqual(mirror.messages.map(\.speaker), [.owner, .mynah, .owner])
    }

    /// The daemon keeps sixteen turns and drops the rest off the front. The
    /// window is not a view of those sixteen — it is everything it has seen.
    func testTheDaemonTrimmingItsOwnCopyTakesNothingFromTheWindow() async throws {
        let firstBatch = (0..<16).map { BrainMessage.user("turn \($0)") }
        try store.save([thread: firstBatch])
        let mirror = makeMirror()
        await mirror.refresh()
        XCTAssertEqual(mirror.messages.count, 16)

        let longer = (0..<24).map { BrainMessage.user("turn \($0)") }
        try store.save([thread: longer])
        XCTAssertEqual(store.load()[thread]?.count, 16, "the daemon's own copy should have trimmed")

        await mirror.refresh()
        XCTAssertEqual(mirror.messages.count, 24, "the window lost what the daemon trimmed")
        XCTAssertEqual(mirror.messages.first?.text, "turn 0")
        XCTAssertEqual(mirror.messages.last?.text, "turn 23")
    }

    /// The reported worry, played out: a conversation that runs all morning,
    /// polled as it goes. The daemon's file slides along and drops the early
    /// turns; the window is watching the whole time and must keep every one.
    func testALongMorningIsKeptInFullWhileTheDaemonSlidesPastIt() async throws {
        let mirror = makeMirror()
        var spoken: [BrainMessage] = []

        for turn in 0..<40 {
            spoken.append(.user("question \(turn)"))
            spoken.append(.assistant("answer \(turn)"))
            try store.save([thread: spoken])
            await mirror.refresh()
        }

        XCTAssertEqual(store.load()[thread]?.count, 16, "the daemon's own copy should have trimmed")
        XCTAssertEqual(mirror.messages.count, 80, "the window lost turns the daemon dropped")
        XCTAssertEqual(mirror.messages.first?.text, "question 0")
        XCTAssertEqual(mirror.messages.last?.text, "answer 39")
        XCTAssertEqual(
            mirror.messages.map(\.text),
            (0..<40).flatMap { ["question \($0)", "answer \($0)"] },
            "the record is out of order or has gaps"
        )
    }

    /// Append-only still has to be bounded, and the oldest go first — a
    /// transcript missing its beginning still reads.
    func testTheRecordStopsGrowingAtItsBound() async throws {
        let mirror = makeMirror()
        let bound = WindowTranscript.maximumTurnsPerThread
        var spoken: [BrainMessage] = []

        for turn in 0..<(bound + 10) {
            spoken.append(.user("turn \(turn)"))
            // Saved in batches the daemon would actually write, so the store's
            // own trimming does the work rather than one implausible save.
            try store.save([thread: Array(spoken.suffix(16))])
            await mirror.refresh()
        }

        XCTAssertEqual(mirror.messages.count, bound)
        XCTAssertEqual(mirror.messages.first?.text, "turn 10", "the newest were dropped instead of the oldest")
        XCTAssertEqual(mirror.messages.last?.text, "turn \(bound + 9)")
    }

    // MARK: Clearing, in both directions

    /// The owner clearing the thread on their phone — or the daemon expiring
    /// it, which looks identical from here — must not empty the window. Nobody
    /// asked for the record on the Mac to go.
    func testClearingTheConversationOnThePhoneLeavesTheWindowAlone() async throws {
        try store.save([thread: [.user("remind me about the roofer"), .assistant("He quoted 2,500.")]])
        let mirror = makeMirror()
        await mirror.refresh()
        XCTAssertEqual(mirror.messages.count, 2)

        // What the daemon does when a conversation is gone: the file itself is
        // removed.
        try store.save([:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))

        await mirror.refresh()
        XCTAssertEqual(mirror.messages.count, 2, "the window emptied itself when the daemon's copy went")
        XCTAssertEqual(mirror.messages.last?.text, "He quoted 2,500.")
    }

    /// And the other way: clearing the window is local. Mynah has no business
    /// reaching into the owner's messages.
    func testClearingTheWindowNeverTouchesTheDaemonsCopy() async throws {
        try store.save([thread: [.user("what did we agree"), .assistant("Dinner at seven.")]])
        let mirror = makeMirror()
        await mirror.refresh()

        mirror.clear()

        XCTAssertTrue(mirror.messages.isEmpty)
        XCTAssertNil(mirror.lastActivity)
        XCTAssertEqual(store.load()[thread]?.count, 2, "clearing the window pruned the appliance's memory")
        let raw = try String(contentsOf: inbox, encoding: .utf8)
        XCTAssertTrue(raw.contains("Dinner at seven"), "clearing the window rewrote the daemon's file")
    }

    /// A clear that undid itself three seconds later would be worse than no
    /// clear at all — and it is exactly what a naive re-read would do, because
    /// the conversation is still sitting in the daemon's file.
    func testAClearedWindowDoesNotFillItselfBackUp() async throws {
        try store.save([thread: [.user("hello"), .assistant("hi there")]])
        let mirror = makeMirror()
        await mirror.refresh()

        mirror.clear()
        for _ in 0..<3 { await mirror.refresh() }

        XCTAssertTrue(mirror.messages.isEmpty, "the cleared conversation came back on the next poll")
    }

    /// What must still happen after a clear: the next thing said on the phone
    /// appears, on its own.
    func testAMessageSaidAfterAClearAppearsOnItsOwn() async throws {
        try store.save([thread: [.user("hello"), .assistant("hi there")]])
        let mirror = makeMirror()
        await mirror.refresh()
        mirror.clear()

        try store.save([
            thread: [.user("hello"), .assistant("hi there"), .user("you still there")]
        ])
        await mirror.refresh()

        XCTAssertEqual(mirror.messages.map(\.text), ["you still there"])
    }

    /// Clearing has to survive a restart, or the owner's "clear" was a screen
    /// wipe that the next launch undoes.
    func testAClearSurvivesTheAppBeingReopened() async throws {
        try store.save([thread: [.user("hello"), .assistant("hi there")]])
        let mirror = makeMirror()
        await mirror.refresh()
        mirror.clear()

        let reopened = makeMirror()
        await reopened.refresh()

        XCTAssertTrue(reopened.messages.isEmpty, "a cleared window came back when the app was reopened")
    }

    // MARK: The record itself

    /// The window keeps its own copy, so the conversation is still there when
    /// the app is opened again — including after the daemon has expired its own.
    func testTheWindowsRecordSurvivesTheAppBeingReopened() async throws {
        try store.save([thread: [.user("what did we agree"), .assistant("Dinner at seven.")]])
        await makeMirror().refresh()

        try store.save([:])
        let reopened = makeMirror()
        await reopened.refresh()

        XCTAssertEqual(reopened.messages.map(\.text), ["what did we agree", "Dinner at seven."])
    }

    /// It holds the owner's own words with no expiry, which is what they asked
    /// for — so it gets the same permissions as their keys and their notes.
    func testTheRecordIsOwnerOnly() async throws {
        try store.save([thread: [.user("something private"), .assistant("noted")]])
        await makeMirror().refresh()

        let filePerms = try FileManager.default
            .attributesOfItem(atPath: record.path)[.posixPermissions] as? NSNumber
        let dirPerms = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePerms, 0o600)
        XCTAssertEqual(dirPerms, 0o700)
    }

    /// Clearing means the sentences are gone from this Mac, not hidden.
    func testClearingRemovesTheWordsFromDisk() async throws {
        try store.save([
            thread: [.user("my landlord's bank details are 1234"), .assistant("noted")]
        ])
        let mirror = makeMirror()
        await mirror.refresh()

        mirror.clear()

        let raw = try String(contentsOf: record, encoding: .utf8)
        XCTAssertFalse(raw.contains("landlord"), "cleared words are still in the window's record")
    }

    /// A record that will not parse is worth an empty window and one log line.
    /// The conversation is re-read from the daemon's copy on the next poll.
    func testAMalformedRecordLeavesTheWindowStanding() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: record)
        try store.save([thread: [.user("hello"), .assistant("hi there")]])

        let mirror = makeMirror()
        await mirror.refresh()

        XCTAssertEqual(mirror.messages.count, 2)
    }

    /// A fresh install: no daemon file, no record, and nothing that looks like a
    /// failure for the empty state to explain away.
    func testAFreshInstallHasNothingToShow() async {
        let mirror = makeMirror()
        await mirror.refresh()

        XCTAssertTrue(mirror.messages.isEmpty)
        XCTAssertNil(mirror.lastActivity)
    }

    /// A corrupt daemon file must leave the window standing too.
    func testAMalformedInboxLeavesTheWindowStanding() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: inbox)

        let mirror = makeMirror()
        await mirror.refresh()

        XCTAssertTrue(mirror.messages.isEmpty)
    }

    // MARK: Not repainting for nothing

    /// Re-reading an unchanged conversation must not tell the view it is out of
    /// date. `@Observable` does not compare, it announces — so without the guard
    /// the transcript would be invalidated every three seconds for the whole
    /// time the window is open.
    func testAnUnchangedConversationDoesNotInvalidateTheTranscript() async throws {
        try store.save([thread: [.user("hello"), .assistant("hi")]])
        let mirror = makeMirror()
        await mirror.refresh()

        let changed = ChangeFlag()
        withObservationTracking {
            _ = mirror.messages
            _ = mirror.lastActivity
        } onChange: {
            changed.fired = true
        }

        await mirror.refresh()
        XCTAssertFalse(changed.fired, "an unchanged conversation was written back over itself")
    }

    /// The other half of the same claim: when something *was* said, the view is
    /// told. A guard that never lets anything through is the worse bug.
    func testANewMessageDoesInvalidateTheTranscript() async throws {
        try store.save([thread: [.user("hello"), .assistant("hi")]])
        let mirror = makeMirror()
        await mirror.refresh()

        let changed = ChangeFlag()
        withObservationTracking {
            _ = mirror.messages
        } onChange: {
            changed.fired = true
        }

        try store.save([thread: [.user("hello"), .assistant("hi"), .user("you there")]])
        await mirror.refresh()
        XCTAssertTrue(changed.fired, "a new message never reached the screen")
    }

    /// A preview holds a fixture. Polling would replace it with whatever is
    /// saved on the machine the preview happens to be open on — and would write
    /// that back over the owner's real record.
    func testAPreloadedMirrorNeitherReadsNorWrites() async {
        let mirror = ConversationMirror(
            messages: [MirroredMessage(id: 0, speaker: .owner, text: "fixture")]
        )

        await mirror.follow()
        mirror.clear()

        XCTAssertEqual(mirror.messages.map(\.text), ["fixture"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }
}

// MARK: - The matching itself

/// The rule that decides what is new, exercised directly. It is the one piece of
/// this that cannot be checked by looking at the screen.
final class WindowTranscriptOverlapTests: XCTestCase {

    func testAnUnchangedSnapshotIsEntirelyAlreadySeen() {
        XCTAssertEqual(WindowTranscript.overlap(between: ["a", "b", "c"], and: ["a", "b", "c"]), 3)
    }

    /// The ordinary case: the daemon's file has slid along by two turns.
    func testOnlyTheTailOfASlidingWindowIsNew() {
        XCTAssertEqual(
            WindowTranscript.overlap(between: ["a", "b", "c"], and: ["b", "c", "d", "e"]),
            2
        )
    }

    /// Nothing in common — a conversation that was cleared on the phone and
    /// started again from scratch.
    func testAnUnrelatedConversationIsEntirelyNew() {
        XCTAssertEqual(WindowTranscript.overlap(between: ["a", "b"], and: ["x", "y"]), 0)
    }

    func testNothingRecordedYetMeansEverythingIsNew() {
        XCTAssertEqual(WindowTranscript.overlap(between: [], and: ["a", "b"]), 0)
    }

    func testAnEmptySnapshotAddsNothing() {
        XCTAssertEqual(WindowTranscript.overlap(between: ["a", "b"], and: []), 0)
    }

    /// The longest run, not the first that matches. A short repeated phrase can
    /// line up in more than one place, and only the longest can be the one the
    /// file is actually sliding along.
    func testTheLongestRunWins() {
        XCTAssertEqual(
            WindowTranscript.overlap(between: ["a", "b", "a", "b"], and: ["a", "b", "c"]),
            2
        )
    }

    /// Two identical sentences in a row are two turns, and the matching has to
    /// keep them both.
    func testARepeatedTurnIsStillCountedOnce() {
        XCTAssertEqual(WindowTranscript.overlap(between: ["a", "a"], and: ["a", "a", "b"]), 2)
    }

    /// Role is part of the fingerprint, so an answer that quotes the question
    /// back is not mistaken for the question.
    func testTheSameWordsFromEitherSideAreDifferentTurns() {
        let asked = WindowTranscript.digest(RecordedTurn(role: "user", content: "dinner at seven?"))
        let answered = WindowTranscript.digest(RecordedTurn(role: "assistant", content: "dinner at seven?"))
        XCTAssertNotEqual(asked, answered)
    }
}

/// A box for the one flag the observation callbacks set. `withObservationTracking`
/// hands back a `@Sendable` closure, which cannot write to a local `var`.
private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

/// The window keeps what it has shown, whatever the daemon does to its own file.
///
/// This is the reason the record exists. `conversations.json` is the daemon's
/// *resumable history*, not an archive: it is written through
/// `trimmed(_:keepingLastTurns:)` and capped again on save, so the oldest turns
/// leave it as a conversation goes on. A window that mirrored it live would drop
/// the owner's morning off the screen while they were reading it, for a file
/// they never touched.
@MainActor
final class WindowRecordTests: XCTestCase {

    private var directory: URL!
    private var store: ConversationStore!
    private var record: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("window-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
        record = directory.appendingPathComponent("window-transcript.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let thread = "+60123821767"

    func testTrimmingTheDaemonsFileDoesNotEraseWhatTheWindowShowed() async throws {
        try store.save([thread: [
            .user("what is on my list"),
            .assistant("The A100 benchmarks, before Friday."),
            .user("and the eurorack shops"),
            .assistant("Nothing on that list yet.")
        ]])

        let mirror = ConversationMirror(store: store, recordURL: record)
        await mirror.refresh()
        let shown = mirror.messages.count
        XCTAssertEqual(shown, 4, "the window did not show the conversation to begin with")

        // The daemon trims, as it does on every turn once a conversation is long
        // enough. Only the newest exchange survives in its file.
        try store.save([thread: [
            .user("and the eurorack shops"),
            .assistant("Nothing on that list yet.")
        ]])
        await mirror.refresh()

        XCTAssertEqual(
            mirror.messages.count, shown,
            "the window lost \(shown - mirror.messages.count) message(s) because the daemon "
                + "trimmed its own file; the owner watches their morning disappear from a "
                + "window they never touched"
        )
        XCTAssertTrue(
            mirror.messages.contains { $0.text.contains("A100") },
            "the earliest exchange is gone from the window"
        )
    }

    /// A repeated question is two messages, not one.
    ///
    /// Turns carry no ids and no timestamps, so dedup has to work on sequence
    /// rather than on a set of contents — an owner who asks the same thing twice
    /// in a day must see it twice.
    func testTheSameThingSaidTwiceIsShownTwice() async throws {
        try store.save([thread: [
            .user("any news"),
            .assistant("Nothing new."),
            .user("any news"),
            .assistant("Still nothing.")
        ]])

        let mirror = ConversationMirror(store: store, recordURL: record)
        await mirror.refresh()

        XCTAssertEqual(
            mirror.messages.filter { $0.text == "any news" }.count, 2,
            "a repeated question was collapsed into one; dedup is matching content "
                + "rather than position"
        )
    }
}
