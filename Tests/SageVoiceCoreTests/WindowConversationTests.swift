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
/// This window's own conversation: written when a turn finishes, read back at
/// launch, and emptied only by the owner.
///
/// The polling, the digests and the longest-run overlap matcher that used to be
/// tested here are gone with the mirror. They existed to reconcile this record
/// against the daemon's sliding window; nothing but this app writes this file
/// now, so there is nothing to reconcile. What survives is every rule about the
/// owner's words: they persist, they are owner-only, and Clear means gone.
@MainActor
final class WindowConversationTests: XCTestCase {

    private var directory: URL!
    private var record: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("window-conversation-\(UUID().uuidString)", isDirectory: true)
        record = directory.appendingPathComponent("window-conversation.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeConversation() -> WindowConversation {
        WindowConversation(recordURL: record)
    }

    // MARK: What was said here

    /// **A turn recorded now must not join the list the transcript draws.**
    ///
    /// It used to, and that is what the owner screenshotted: every question he
    /// asked appeared twice, once plain and once with its timing and tool line.
    /// `messages` is what was said *before* the turns currently on screen;
    /// `ConversationModel.exchanges` owns the live ones. When `record` appended
    /// to `messages`, `TalkView.timeline` had the same turn from both and drew
    /// both.
    ///
    /// So this asserts the emptiness on purpose. The turn is not lost — the two
    /// tests below prove it reaches disk and comes back — it simply is not this
    /// list's to show yet.
    func testARecordedTurnDoesNotJoinTheMessagesTheTranscriptDraws() async {
        let subject = makeConversation()
        await subject.restore()
        subject.record(question: "what did the roofer say", answer: "he quoted 2500", askedAt: nil, answeredAt: nil)

        XCTAssertTrue(
            subject.messages.isEmpty,
            "the live turn was added to the earlier-turns list, so it is on screen twice"
        )
    }

    /// And restoring shows it as two messages, which is where the shape the old
    /// version of this test was checking actually belongs.
    func testAFinishedTurnComesBackAsTwoMessages() async {
        let first = makeConversation()
        await first.restore()
        first.record(question: "what did the roofer say", answer: "he quoted 2500", askedAt: nil, answeredAt: nil)

        let reopened = makeConversation()
        await reopened.restore()
        XCTAssertEqual(reopened.messages.map(\.text), ["what did the roofer say", "he quoted 2500"])
        XCTAssertEqual(reopened.messages.map(\.speaker), [.owner, .mynah])
    }

    /// The whole reason this type exists. Before it, the window's half of the
    /// conversation lived only in memory: what looked like history surviving a
    /// relaunch was the phone's messages being redrawn, and everything typed
    /// here was gone.
    func testWhatWasSaidHereSurvivesTheAppBeingReopened() async {
        let first = makeConversation()
        await first.restore()
        first.record(question: "remind me monday", answer: "will do", askedAt: nil, answeredAt: nil)

        let reopened = makeConversation()
        await reopened.restore()
        XCTAssertEqual(reopened.messages.map(\.text), ["remind me monday", "will do"])
    }

    func testTheRecordIsOwnerOnly() async throws {
        let subject = makeConversation()
        await subject.restore()
        subject.record(question: "q", answer: "a", askedAt: nil, answeredAt: nil)

        let mode = try FileManager.default.attributesOfItem(atPath: record.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    // MARK: Clearing

    /// "Clear" has to mean the sentences are gone from this Mac, not hidden.
    func testClearingRemovesTheWordsFromDisk() async throws {
        let subject = makeConversation()
        await subject.restore()
        subject.record(question: "something private", answer: "noted", askedAt: nil, answeredAt: nil)
        subject.clear()

        XCTAssertTrue(subject.messages.isEmpty)
        let written = try String(contentsOf: record, encoding: .utf8)
        XCTAssertFalse(written.contains("something private"))
    }

    /// The old record had to keep fingerprints of what it cleared, or the next
    /// poll put the conversation straight back. Nothing polls now, so a cleared
    /// window stays cleared across a relaunch with nothing left behind.
    func testAClearSurvivesTheAppBeingReopened() async {
        let first = makeConversation()
        await first.restore()
        first.record(question: "q", answer: "a", askedAt: nil, answeredAt: nil)
        first.clear()

        let reopened = makeConversation()
        await reopened.restore()
        XCTAssertTrue(reopened.messages.isEmpty)
    }

    // MARK: Not losing the window over a bad file

    func testAMalformedRecordLeavesTheWindowStanding() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: record)

        let subject = makeConversation()
        await subject.restore()
        XCTAssertTrue(subject.messages.isEmpty)
    }

    func testAFreshInstallHasNothingToShow() async {
        let subject = makeConversation()
        await subject.restore()
        XCTAssertTrue(subject.messages.isEmpty)
    }

    // MARK: The bound

    func testTheRecordStopsGrowingAtItsBound() async {
        let writer = makeConversation()
        await writer.restore()
        for index in 0..<(WindowRecord.maximumTurns) {
            writer.record(question: "q\(index)", answer: "a\(index)", askedAt: nil, answeredAt: nil)
        }
        // Through a reopen, because `record` no longer publishes — see
        // `testARecordedTurnDoesNotJoinTheMessagesTheTranscriptDraws`. The bound
        // is a property of what is kept, so measuring it on what is read back is
        // the more honest measurement anyway.
        let subject = makeConversation()
        await subject.restore()

        XCTAssertEqual(subject.messages.count, WindowRecord.maximumTurns)
        // The oldest go first, which is the honest direction: a transcript
        // missing its beginning still reads.
        XCTAssertEqual(subject.messages.last?.text, "a\(WindowRecord.maximumTurns - 1)")
    }

    // MARK: What the engine is told

    /// The seam that used to carry the phone's conversation into this window's
    /// answers now carries this window's own past. One conversation per surface,
    /// each answering from the one it is showing.
    func testTheEngineIsGroundedInThisWindowsOwnPast() async {
        let subject = makeConversation()
        await subject.restore()
        subject.record(question: "the quote was 2500", answer: "noted", askedAt: nil, answeredAt: nil)

        XCTAssertEqual(subject.priorMessages.map(\.content), ["the quote was 2500", "noted"])
        XCTAssertEqual(subject.priorMessages.map(\.role), [.user, .assistant])
    }

    func testAPreloadedConversationNeitherReadsNorWrites() async {
        let subject = WindowConversation(
            messages: [TranscriptMessage(id: 0, speaker: .owner, text: "fixture")]
        )
        await subject.restore()
        subject.record(question: "q", answer: "a", askedAt: nil, answeredAt: nil)

        XCTAssertEqual(subject.messages.map(\.text), ["fixture"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }
}

final class TranscriptExchangeGroupingTests: XCTestCase {

    private func message(_ id: Int, _ speaker: TranscriptMessage.Speaker, _ text: String) -> TranscriptMessage {
        TranscriptMessage(id: id, speaker: speaker, text: text)
    }

    func testAConversationBecomesOneExchangePerQuestion() {
        let exchanges = TranscriptExchange.group([
            message(0, .owner, "what did we agree"),
            message(1, .mynah, "Dinner at seven."),
            message(2, .owner, "and the wine"),
            message(3, .mynah, "You said you'd bring it.")
        ])

        XCTAssertEqual(exchanges.count, 2)
        XCTAssertEqual(exchanges.first?.asked.map(\.text), ["what did we agree"])
        XCTAssertEqual(exchanges.first?.answered.map(\.text), ["Dinner at seven."])
        XCTAssertEqual(exchanges.last?.asked.map(\.text), ["and the wine"])
    }

    /// Two voice notes in a row are one exchange, not two — the appliance
    /// answered them together, and splitting them would put an empty answer
    /// under the first.
    func testMessagesSentInARowBelongToOneExchange() {
        let exchanges = TranscriptExchange.group([
            message(0, .owner, "what did we agree"),
            message(1, .owner, "about thursday I mean"),
            message(2, .mynah, "Dinner at seven.")
        ])

        XCTAssertEqual(exchanges.count, 1)
        XCTAssertEqual(exchanges.first?.asked.count, 2)
        XCTAssertEqual(exchanges.first?.answered.count, 1)
    }

    /// The appliance answers in more than one message often enough — a working
    /// line, then the answer. Both belong to the question that prompted them.
    func testTwoAnswersToOneQuestionStayInThatExchange() {
        let exchanges = TranscriptExchange.group([
            message(0, .owner, "find me a plumber"),
            message(1, .mynah, "Looking that up online."),
            message(2, .mynah, "Three near you, all open Saturday.")
        ])

        XCTAssertEqual(exchanges.count, 1)
        XCTAssertEqual(exchanges.first?.answered.count, 2)
    }

    /// The daemon trims from the front, so a conversation can legitimately begin
    /// with an answer whose question is gone. Drawing it alone is honest;
    /// inventing a question for it would not be.
    func testAnAnswerWhoseQuestionWasTrimmedStillAppears() {
        let exchanges = TranscriptExchange.group([
            message(0, .mynah, "…and the roofer starts on the 14th."),
            message(1, .owner, "thanks"),
            message(2, .mynah, "Any time.")
        ])

        XCTAssertEqual(exchanges.count, 2)
        XCTAssertTrue(exchanges.first?.asked.isEmpty == true)
        XCTAssertEqual(exchanges.first?.answered.map(\.text), ["…and the roofer starts on the 14th."])
        XCTAssertEqual(exchanges.last?.asked.map(\.text), ["thanks"])
    }

    /// A question still waiting for its answer on the phone is an exchange with
    /// nothing in the second half, not a dropped message.
    func testAQuestionWithNoAnswerYetIsStillAnExchange() {
        let exchanges = TranscriptExchange.group([message(0, .owner, "you there")])

        XCTAssertEqual(exchanges.count, 1)
        XCTAssertEqual(exchanges.first?.asked.count, 1)
        XCTAssertTrue(exchanges.first?.answered.isEmpty == true)
    }

    func testAnEmptyConversationHasNoExchanges() {
        XCTAssertTrue(TranscriptExchange.group([]).isEmpty)
    }

    /// Every exchange needs its own identity or the list draws one of them.
    func testExchangesAreDistinctlyIdentified() {
        let exchanges = TranscriptExchange.group([
            message(0, .owner, "ok"),
            message(1, .mynah, "ok"),
            message(2, .owner, "ok"),
            message(3, .mynah, "ok")
        ])

        XCTAssertEqual(Set(exchanges.map(\.id)).count, exchanges.count)
    }

    /// Nothing is lost or duplicated in the regrouping — every message comes out
    /// exactly once, in the order it was said.
    func testEveryMessageSurvivesTheGrouping() {
        let messages = (0..<12).map { index in
            message(index, index.isMultiple(of: 3) ? .mynah : .owner, "turn \(index)")
        }

        let regrouped = TranscriptExchange.group(messages).flatMap { $0.asked + $0.answered }
        XCTAssertEqual(regrouped, messages)
    }
}

// MARK: - Documents in the window's own record

/// A PDF Mynah wrote, still openable after a relaunch.
///
/// The window has no attachment channel, so the file *is* the delivery here —
/// which makes the path in the record load-bearing rather than decoration. Two
/// things can go wrong and both are silent: an older record that predates the
/// field failing to decode at all, and a chip that opens nothing because the
/// owner moved the file.
final class WindowDocumentRecordTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("window-docs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recordURL() -> URL { directory.appendingPathComponent("window.json") }

    func testADocumentSurvivesARelaunch() throws {
        let file = directory.appendingPathComponent("quarterly-brief.pdf")
        try Data("%PDF-1.7".utf8).write(to: file)

        var record = WindowRecord()
        record.append(
            question: "make me a PDF about the quarter",
            answer: "Made you one.",
            askedAt: nil,
            answeredAt: nil,
            files: [file]
        )
        try record.save(to: recordURL())

        let reopened = WindowRecord.load(from: recordURL())
        XCTAssertEqual(reopened.turns.last?.files, [file.path])
    }

    func testARecordWrittenBeforeDocumentsExistedStillOpens() throws {
        // The field is optional for exactly this reason: every record on every
        // Mac was written without it, and a decoder that refuses one is an
        // owner whose entire conversation disappears on upgrade.
        let older = """
        {"turns":[{"role":"user","content":"hello"},{"role":"assistant","content":"hi"}]}
        """
        try Data(older.utf8).write(to: recordURL())

        let loaded = WindowRecord.load(from: recordURL())

        XCTAssertEqual(loaded.turns.count, 2)
        XCTAssertNil(loaded.turns.last?.files)
    }

    func testAQuestionCarriesNoDocuments() throws {
        let file = directory.appendingPathComponent("brief.pdf")
        try Data("%PDF".utf8).write(to: file)

        var record = WindowRecord()
        record.append(question: "q", answer: "a", askedAt: nil, answeredAt: nil, files: [file])

        XCTAssertNil(record.turns.first?.files, "the owner did not write a document")
        XCTAssertEqual(record.turns.last?.files, [file.path])
    }
}
