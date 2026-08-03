import XCTest
@testable import SageVoiceCore

/// **"the tasks coming on and off the lists; what do you think - useful;
/// annoying ? too often ?"**
///
/// He was looking at this, minutes after asking Mynah to pin a deadline to an
/// open-ended task and being told in prose that it had:
///
///     A new task landed: "Apply for Thailand Digital Arrival Card (TDAC) …"
///     A new task landed: "Dentist appointment — Tuesday 4 August 2026, 1pm."
///     A task came off the list.
///     A task came off the list.
///
/// Four lines, every one of them his own two edits read back to him as news —
/// a replacement is an arrival and a departure — and two of them saying nothing
/// identifiable at all.
///
/// Useful for a task an *agent* added, or one that moved overnight. Not for the
/// edit he made thirty seconds ago and already had confirmed in words.
final class OwnTaskEditsTests: XCTestCase {

    // MARK: - The note itself

    func testNothingToSuppressUntilSomethingIsWritten() async {
        let edits = OwnTaskEdits()
        let quiet = await edits.takeSuppression()
        XCTAssertFalse(quiet)
    }

    func testAWriteSuppressesTheNextCheckAndOnlyTheNext() async {
        let edits = OwnTaskEdits()
        await edits.record()

        let first = await edits.takeSuppression()
        let second = await edits.takeSuppression()
        XCTAssertTrue(first)
        XCTAssertFalse(second, "the check after that has real news and must deliver it")
    }

    /// Two edits before a single check still cost one silence, not two. He
    /// changed his list twice; the next check is current either way.
    func testTwoWritesBeforeOneCheckStillSuppressOnce() async {
        let edits = OwnTaskEdits()
        await edits.record()
        await edits.record()

        let first = await edits.takeSuppression()
        let second = await edits.takeSuppression()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    // MARK: - What a suppressed check does

    private func watch(tasks: [WatchedTask]) -> ProactiveWatch {
        ProactiveWatch(source: StubSource(tasks: tasks))
    }

    private func task(_ id: String, _ title: String, status: String = "open") -> WatchedTask {
        WatchedTask(id: id, title: title, status: status)
    }

    /// **Silent, but not blind.** The ledger still takes in what changed, so the
    /// *next* check compares against the truth. Skipping the update instead
    /// would merely postpone the same four lines by fifteen minutes.
    func testASuppressedCheckSaysNothingAndStillLearns() async {
        let before = ProactiveLedger(
            knownTasks: ["a": "open"],
            knownTaskTitles: ["a": "Apply for the TDAC"],
            hasSeeded: true
        )
        let after = task("b", "Apply for the TDAC by Friday 7 August 2026")

        let report = await watch(tasks: [after])
            .check(against: before, announcingTaskChanges: false)

        XCTAssertNil(report.message)
        XCTAssertEqual(report.ledger.knownTasks, ["b": "open"])
        XCTAssertEqual(report.ledger.knownTaskTitles["b"], after.title)
    }

    /// And the next one is quiet too, because there is genuinely nothing left to
    /// say — which is the whole test that the absorption worked.
    func testTheCheckAfterASuppressedOneIsQuietBecauseNothingIsLeft() async {
        let before = ProactiveLedger(
            knownTasks: ["a": "open"],
            knownTaskTitles: ["a": "Apply for the TDAC"],
            hasSeeded: true
        )
        let after = task("b", "Apply for the TDAC by Friday 7 August 2026")
        let watch = watch(tasks: [after])

        let first = await watch.check(against: before, announcingTaskChanges: false)
        let second = await watch.check(against: first.ledger)

        XCTAssertNil(second.message)
    }

    /// **The suppression is about tasks and nothing else.** A message from
    /// another agent is news whatever the owner was just doing, and swallowing
    /// it would turn a noise fix into a lost errand.
    func testAnAgentMessageIsStillAnnouncedDuringASuppressedCheck() async {
        let source = StubSource(
            tasks: [task("a", "something new")],
            messages: [AgentInboxItem(
                id: "m1",
                content: UntrustedAgentContent(
                    sender: "codex", trust: .anotherAgentHere, body: "the branch is pushed"
                ),
                intent: nil,
                arrived: nil,
                expectsAResult: false
            )]
        )
        let report = await ProactiveWatch(source: source)
            .check(against: ProactiveLedger(hasSeeded: true), announcingTaskChanges: false)

        let message = try? XCTUnwrap(report.message)
        XCTAssertTrue(message?.contains("codex") ?? false, report.message ?? "nil")
        XCTAssertFalse(message?.contains("A new task landed") ?? true, report.message ?? "nil")
    }

    /// An ordinary check is unchanged. The default has to stay "say what
    /// changed" or the feature is off for everybody who never edits by voice.
    func testAnOrdinaryCheckStillReportsWhatChanged() async {
        let report = await watch(tasks: [task("a", "Call the plumber")])
            .check(against: ProactiveLedger(hasSeeded: true))

        XCTAssertTrue(report.message?.contains("Call the plumber") ?? false, report.message ?? "nil")
    }

    // MARK: - Naming what left

    /// **"A task came off the list." twice told him nothing.** Two identical
    /// lines are indistinguishable from each other and from any other pair, so
    /// the only thing they carried was that something had happened somewhere.
    func testADepartedTaskIsNamed() {
        let lines = ProactiveWatch.taskNews(
            [],
            against: ["a": "open"],
            titles: ["a": "Dentist appointment — Tuesday 4 August 2026, 1pm"],
            seeded: true
        )

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("Dentist appointment"), lines[0])
        XCTAssertTrue(lines[0].contains("came off the list"), lines[0])
    }

    func testTwoDeparturesAreTwoDifferentSentences() {
        let lines = ProactiveWatch.taskNews(
            [],
            against: ["a": "open", "b": "open"],
            titles: ["a": "Dentist appointment", "b": "Apply for the TDAC"],
            seeded: true
        )

        XCTAssertEqual(Set(lines).count, 2, "\(lines)")
    }

    /// The first tick after an upgrade has no titles, because the build that
    /// wrote the ledger never stored any. It says the old thing rather than
    /// saying nothing or crashing.
    func testAnUpgradedLedgerWithNoTitlesStillReportsTheDeparture() {
        let lines = ProactiveWatch.taskNews([], against: ["a": "open"], seeded: true)

        XCTAssertEqual(lines, ["A task came off the list."])
    }

    /// Departures are emitted in a stable order. Dictionary iteration is not,
    /// and a digest whose lines shuffle between runs is one nobody can diff.
    func testDeparturesAreOrderedTheSameWayEveryTime() {
        let known = ["c": "open", "a": "open", "b": "open"]
        let titles = ["a": "Alpha", "b": "Bravo", "c": "Charlie"]

        let first = ProactiveWatch.taskNews([], against: known, titles: titles, seeded: true)
        let again = ProactiveWatch.taskNews([], against: known, titles: titles, seeded: true)

        XCTAssertEqual(first, again)
    }

    // MARK: - Which tools count

    /// **The opposite policy to `ToolLoop.readOnlyTools`, deliberately.** There,
    /// an unlisted tool counts as having acted, because missing a real write is
    /// the dangerous direction. Here a wrongly-listed tool suppresses genuine
    /// news, so the list names only what actually writes.
    func testOnlyRealTaskWritesSuppress() {
        XCTAssertTrue(VoiceBridgeDaemon.taskWritingTools.contains("sage_task"))

        for readOnly in ["sage_backlog", "sage_recall", "sage_inbox", "web_search", "read_note"] {
            XCTAssertFalse(VoiceBridgeDaemon.taskWritingTools.contains(readOnly), readOnly)
        }
    }

    // MARK: - Fixtures

    private struct StubSource: ProactiveSource {
        var tasks: [WatchedTask] = []
        var messages: [AgentInboxItem] = []

        func waitingMessages(limit: Int) async throws -> [AgentInboxItem] { messages }
        func openTasks() async throws -> [WatchedTask] { tasks }
    }
}
