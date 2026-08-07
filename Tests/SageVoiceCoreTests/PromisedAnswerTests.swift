import XCTest
@testable import SageVoiceCore

/// A promise to come back has to survive the process that made it.
///
/// 5 August 2026: the appliance told the owner *"I'm on it… I'll let you know
/// the moment it's done"*, trapped inside WebKit three seconds later, and was
/// restarted by launchd. Nothing ever reached his phone. Every existing guard
/// against silence — the 360-second turn ceiling, the working-line gate —
/// assumed the daemon would still be alive to feel guilty about it.
final class PromisedAnswerTests: XCTestCase {

    private func scratchStore() -> (PromisedAnswerStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-promise-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("outstanding-promise.json")
        return (PromisedAnswerStore(fileURL: url), url)
    }

    private func promise(
        _ question: String = "whats the name of the connector on dgx spark",
        account: String = "+60111222333",
        at date: Date = Date()
    ) -> PromisedAnswer {
        PromisedAnswer(account: account, question: question, promisedAt: date, channel: .signal)
    }

    // MARK: The ordinary round trip

    func testAPromiseSurvivesBeingWrittenAndReadBack() {
        let (store, _) = scratchStore()
        XCTAssertNil(store.outstanding(), "a fresh store must not invent a promise")

        let owed = promise()
        store.record(owed)

        XCTAssertEqual(
            store.outstanding(), owed,
            "the promise did not survive a round trip, so a restart would not know an answer was owed"
        )
    }

    func testAnAnsweredPromiseIsCleared() {
        let (store, _) = scratchStore()
        let owed = promise()
        store.record(owed)

        store.clear(ifStill: owed)

        XCTAssertNil(
            store.outstanding(),
            "the promise outlived the answer, so the next boot would apologise for a question already answered"
        )
    }

    /// The excerpt is bounded, because this is a recovery record and not a
    /// second copy of the conversation.
    func testALongQuestionIsKeptToAnExcerpt() {
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(promise(long).question.count, PromisedAnswer.longestQuestion)
    }

    /// **A promise must equal itself after a round trip, or nothing ever
    /// clears.**
    ///
    /// Its own test because the failure is silent and permanent rather than
    /// loud. `clear(ifStill:)` compares by value; if the encoded form loses
    /// precision the comparison can never succeed, the record is never removed,
    /// and the appliance apologises for the same question on every boot for as
    /// long as it is installed. ISO-8601 carries no fractional seconds, which is
    /// exactly how this happened — the two values printed identically and were
    /// not equal.
    func testAPromiseEqualsItselfAfterEncodingSoItCanEverBeCleared() throws {
        // A time with fractional seconds, which is what `Date()` always is.
        let owed = promise(at: Date(timeIntervalSince1970: 1_785_896_271.101))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let roundTripped = try decoder.decode(PromisedAnswer.self, from: encoder.encode(owed))

        XCTAssertEqual(
            roundTripped, owed,
            """
            a promise does not survive encoding as an equal value, so clear(ifStill:) \
            can never match and the record will never be removed. The owner would be \
            apologised to for the same question on every boot, forever.
            """
        )
    }

    // MARK: The failure the first design would have shipped

    /// **A previous run's promise must not be cleared by this run's answer.**
    ///
    /// This is the bug that nearly went out, and it is worth stating in full
    /// because it reads as safe. The clearing was going to be unconditional, at
    /// the one seam every reply passes through, on the reasoning that "no
    /// promise can be outstanding here". That reasoning is true of the *current
    /// process* and the record is *durable* — and the whole point of the record
    /// is that it crosses a process boundary.
    ///
    /// So: the daemon dies at 10:17 owing an answer. It restarts and begins
    /// waiting for the Signal socket so it can apologise. In that window the
    /// owner — who has had no answer, no explanation, and no reason to sit still
    /// — sends anything at all. A voice note it cannot read. A `//?`. A message
    /// while paused. A message that is too long. Each of those is answered, each
    /// answer would have cleared the file, and the apology that was two seconds
    /// away would never be sent. He is left exactly where he started, by the
    /// feature built to rescue him.
    /// **This test has been wrong twice, and both times it passed.**
    ///
    /// Version one declared `let madeThisRun: PromisedAnswer? = nil` and then
    /// `if let mine = madeThisRun { ... }` — a branch the compiler can see is
    /// never taken. It asserted that a store nobody had touched still held what
    /// had just been put in it, and would have passed with the whole feature
    /// reverted.
    ///
    /// Version two replaced that with a local closure that *mimed* the daemon's
    /// rule. Better, and still not a test of anything: the rule it exercised was
    /// the one written three lines above it in the test file, so the production
    /// rule could be deleted and this stayed green. The second review round said
    /// so, and it was right.
    ///
    /// The rule now lives in `PromiseLedger`, and this calls it.
    func testAnUnrelatedAnswerDoesNotEraseAPromiseThisRunNeverMade() {
        let (store, _) = scratchStore()
        let owedByTheCrashedRun = promise("what's the connector on dgx spark", at: Date())
        store.record(owedByTheCrashedRun)

        // A fresh run: it has promised nobody anything.
        var ledger = PromiseLedger()
        ledger.beginExchange()

        // It answers something else entirely — "I couldn't read that voice
        // note." The ledger owes nothing, so nothing is discharged.
        if let discharged = ledger.answered() { store.clear(ifStill: discharged) }

        XCTAssertEqual(
            store.outstanding(), owedByTheCrashedRun,
            """
            an unrelated reply erased a promise made by a previous, crashed run. \
            The apology for it will now never be sent, which is precisely the \
            silence this whole feature exists to abolish.
            """
        )

        // And the other half, so this cannot pass by never clearing anything.
        ledger.beginExchange()
        if let made = ledger.promised(to: "+60111222333", channel: .signal, question: "something asked now", at: Date()) {
            store.record(made)
        }
        if let discharged = ledger.answered() { store.clear(ifStill: discharged) }

        XCTAssertNil(
            store.outstanding(),
            "a run's own promise was not discharged by its own answer, so it would apologise for an answered question"
        )
    }

    // MARK: The ledger, which is where both defects actually lived

    /// **The one the second review round found, stated as the appliance sees it.**
    ///
    /// The owner asks something. The working line goes out and the promise is
    /// recorded. The answer fails to send — signal-cli hiccups, the reply is
    /// logged and dropped — so the promise is still owed and still on disk.
    ///
    /// He then sends a voice note that will not transcribe. The daemon replies
    /// "I couldn't read that voice note.", which is classified `.answer` like
    /// every other refusal. If that discharges the outstanding promise, the
    /// record saying he is owed an answer is deleted, and no apology is made on
    /// this boot or any later one.
    ///
    /// Nine replies have this shape and all of them run before a turn begins,
    /// which is why the boundary is the incoming batch and not the turn.
    func testARefusalOnTheNextMessageDoesNotDischargeAnUndeliveredPromise() {
        var ledger = PromiseLedger()

        ledger.beginExchange()
        let owed = ledger.promised(to: "+60111222333", channel: .signal, question: "what's the connector", at: Date())
        XCTAssertNotNil(owed)
        // The answer never reaches Signal, so nothing discharges it here.

        // Next message: an unreadable voice note, refused before any turn starts.
        ledger.beginExchange()
        let dischargedByTheRefusal = ledger.answered()

        XCTAssertNil(
            dischargedByTheRefusal,
            """
            a refusal discharged a promise the appliance had not kept. He is owed \
            an answer, the record that said so has been deleted, and the apology \
            will never be sent.
            """
        )
    }

    /// The ordinary case still works: a promise made and kept in one exchange.
    func testAPromiseMadeAndAnsweredInOneExchangeIsDischarged() {
        var ledger = PromiseLedger()
        ledger.beginExchange()

        let made = ledger.promised(to: "+60111222333", channel: .signal, question: "what's the connector", at: Date())
        XCTAssertNotNil(made)
        XCTAssertEqual(ledger.outstanding, made)

        XCTAssertEqual(
            ledger.answered(), made,
            "the answer did not discharge its own promise, so the next boot would apologise for a question already answered"
        )
        XCTAssertNil(ledger.outstanding)
        XCTAssertNil(ledger.answered(), "discharging twice returned a promise the second time")
    }

    /// Nothing is promised when there is nothing to name.
    func testAnEmptyQuestionPromisesNothing() {
        var ledger = PromiseLedger()
        ledger.beginExchange()

        XCTAssertNil(ledger.promised(to: "+60111222333", channel: .signal, question: "   ", at: Date()))
        XCTAssertNil(
            ledger.outstanding,
            "a promise was recorded with no question in it, so its apology could not say what was asked"
        )
    }

    /// A second working line in one exchange replaces rather than accumulates.
    ///
    /// One promise, because the appliance can owe at most one answer at a time —
    /// a ledger that could hold two would be modelling a state that cannot occur.
    func testASecondWorkingLineReplacesThePromise() {
        var ledger = PromiseLedger()
        ledger.beginExchange()

        _ = ledger.promised(to: "+60111222333", channel: .signal, question: "first", at: Date(timeIntervalSince1970: 1))
        let second = ledger.promised(to: "+60111222333", channel: .signal, question: "second", at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(ledger.outstanding, second)
        XCTAssertEqual(ledger.answered(), second)
    }

    /// And the mirror image: recovery must not delete a *newer* promise.
    ///
    /// The apology path can be waiting up to sixty seconds for the Signal socket
    /// while the message loop is already running. A turn that starts in that
    /// window writes its own promise. If the apology then cleared the file
    /// blind, it would delete a live promise on its way out — and if that turn
    /// went on to die, the owner gets nothing. The fix causing the bug.
    func testRecoveryDoesNotEraseAPromiseMadeWhileItWasConnecting() {
        let (store, _) = scratchStore()
        let inherited = promise("the old question", at: Date().addingTimeInterval(-30))
        store.record(inherited)

        // The daemon boots, reads the inherited promise, and starts waiting for
        // the socket. Meanwhile a new turn begins and promises.
        let newer = promise("a brand new question")
        store.record(newer)

        // The apology for the inherited one is delivered, and tries to clear it.
        store.clear(ifStill: inherited)

        XCTAssertEqual(
            store.outstanding(), newer,
            """
            recovery deleted a promise it did not own. The turn that made it can \
            still die, and now nothing on disk says anyone is waiting.
            """
        )
    }

    /// Clearing is by value, so a promise re-made after being cleared is a
    /// different promise and stays.
    func testClearingIsByValueRatherThanByPresence() {
        let (store, _) = scratchStore()
        let first = promise("question one", at: Date(timeIntervalSince1970: 1_000_000))
        let second = promise("question two", at: Date(timeIntervalSince1970: 2_000_000))

        store.record(second)
        store.clear(ifStill: first)

        XCTAssertEqual(store.outstanding(), second, "clearing matched on presence rather than on identity")
    }

    // MARK: The guard that stops the suite eating the owner's promise

    /// **The test guard covers deleting, not only writing.**
    ///
    /// Borrowed from `AgentSendJournal`, which only ever appends and so only
    /// ever needed to guard its write. This type deletes, and an unguarded
    /// delete is worse than an unguarded write: a test constructing
    /// `PromisedAnswerStore()` on the default path would remove the owner's real
    /// outstanding promise, producing exactly the silence being fixed — from the
    /// test suite rather than from a crash.
    func testTheRealFileIsUntouchableFromTheTestSuite() {
        let real = PromisedAnswerStore.defaultFileURL()

        XCTAssertFalse(
            PromisedAnswerStore.mayTouch(real, isTesting: true),
            "the suite may touch the owner's real promise file"
        )
        XCTAssertTrue(
            PromisedAnswerStore.mayTouch(real, isTesting: false),
            "the appliance itself must be able to write its own file — this guard is for tests only"
        )
        XCTAssertTrue(
            PromisedAnswerStore.mayTouch(
                FileManager.default.temporaryDirectory.appendingPathComponent("somewhere-else.json"),
                isTesting: true
            ),
            "a test that supplies its own path is not what this guard is for"
        )
    }

    /// The default-path store is inert under XCTest, in both directions.
    func testADefaultStoreNeitherWritesNorDeletesUnderTest() {
        let store = PromisedAnswerStore()
        let before = FileManager.default.fileExists(atPath: PromisedAnswerStore.defaultFileURL().path)

        store.record(promise("this must not be written"))
        store.clear(ifStill: promise("this must not delete anything"))

        XCTAssertEqual(
            FileManager.default.fileExists(atPath: PromisedAnswerStore.defaultFileURL().path),
            before,
            "the default store changed the owner's real file from inside the test suite"
        )
    }

    // MARK: On disk

    /// Owner-only from the first byte, like everything else holding his words.
    func testThePromiseIsWrittenOwnerOnly() throws {
        let (store, url) = scratchStore()
        store.record(promise())

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(
            mode, OwnerOnlyFileSecurity.filePermissions,
            "the promise holds an excerpt of the owner's own words and was not written owner-only"
        )
    }

    func testAnUnreadableFileIsNoPromiseRatherThanACrash() throws {
        let (store, url) = scratchStore()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("this is not JSON".utf8).write(to: url)

        XCTAssertNil(
            store.outstanding(),
            "a corrupt promise file must read as no promise; throwing here would take down daemon start-up"
        )
    }
}
