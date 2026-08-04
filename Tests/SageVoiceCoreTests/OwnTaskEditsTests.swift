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
    /// wrote the ledger never stored any. It now says nothing rather than
    /// saying "A task came off the list." — the line he read twice in a row and
    /// correctly called useless. A departure it cannot name is one he cannot act
    /// on, and it can only happen for a single tick.
    func testAnUpgradedLedgerWithNoTitlesSaysNothing() {
        let lines = ProactiveWatch.taskNews([], against: ["a": "open"], seeded: true)

        XCTAssertEqual(lines, [])
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
        XCTAssertTrue(OwnTaskEdits.taskWritingTools.contains("sage_task"))

        for readOnly in ["sage_backlog", "sage_recall", "sage_inbox", "web_search", "read_note"] {
            XCTAssertFalse(OwnTaskEdits.taskWritingTools.contains(readOnly), readOnly)
        }
    }

    /// A write the node refused changed nothing, so there is nothing to suppress
    /// — and suppressing on it would swallow whatever genuinely did change in
    /// the same window.
    func testAFailedTaskWriteDoesNotCount() {
        XCTAssertTrue(OwnTaskEdits.wroteToTheTaskList(Self.trace(("sage_task", false))))
        XCTAssertFalse(OwnTaskEdits.wroteToTheTaskList(Self.trace(("sage_task", true))))
        XCTAssertFalse(OwnTaskEdits.wroteToTheTaskList(Self.trace(("sage_backlog", false))))
    }

    // MARK: - Across the process boundary

    /// **The bug of 4 August, in one test.** He edited the list in the window;
    /// the daemon's watch, a different process, reported his own edit back to him
    /// over Signal six seconds later. The in-memory flag could never have seen
    /// it.
    func testAnEditFromAnotherProcessSuppressesTheNextCheck() async throws {
        let marker = Self.scratchMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let edits = OwnTaskEdits(marker: marker)

        var complaints: [String] = []
        OwnTaskEdits.recordFromAnotherProcess(marker: marker, log: { complaints.append($0) })

        XCTAssertEqual(complaints, [], "the note could not be written")
        let suppressed = await edits.takeSuppression()
        XCTAssertTrue(suppressed, "the window's edit did not reach the daemon")
    }

    /// A note that cannot be written says so. Silence here means he gets his own
    /// edit read back to him with nothing in the log to explain it — the failure
    /// this whole change exists to end, arriving with its evidence thrown away.
    func testAMarkerThatCannotBeWrittenIsReported() {
        let unwritable = URL(fileURLWithPath: "/System/nowhere/own-task-edit")

        var complaints: [String] = []
        OwnTaskEdits.recordFromAnotherProcess(marker: unwritable, log: { complaints.append($0) })

        XCTAssertEqual(complaints.count, 1, "a failed write said nothing")
        XCTAssertTrue(complaints[0].contains("own-task-edit"), complaints[0])
    }

    /// Take-and-clear, across the boundary too: the second check has news to
    /// deliver and must.
    func testTheMarkerIsConsumedByTheCheckThatReadsIt() async throws {
        let marker = Self.scratchMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let edits = OwnTaskEdits(marker: marker)
        OwnTaskEdits.recordFromAnotherProcess(marker: marker)

        _ = await edits.takeSuppression()

        let second = await edits.takeSuppression()
        XCTAssertFalse(second, "one edit suppressed two checks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// No marker and no local edit is the ordinary case, and it must say so —
    /// otherwise the watch goes permanently silent about tasks.
    func testNothingIsSuppressedWhenNobodyEdited() async {
        let edits = OwnTaskEdits(marker: Self.scratchMarker())

        let suppressed = await edits.takeSuppression()

        XCTAssertFalse(suppressed)
    }

    /// Both doors, one answer. An edit here and an edit there in the same window
    /// is still one suppression.
    func testALocalEditStillSuppressesWithNoMarkerPresent() async {
        let edits = OwnTaskEdits(marker: Self.scratchMarker())

        await edits.record()

        let suppressed = await edits.takeSuppression()
        XCTAssertTrue(suppressed)
    }

    // MARK: - Every door into the list

    /// **Because looking is what failed.** The daemon's own edits were
    /// suppressed from the day this type was written, and two other ways to
    /// change the same list went unwatched for the whole of that time: the
    /// window's chat, and dragging a card on the board — which does not even
    /// spend a model turn, so nothing in the daemon could have inferred it. Both
    /// were found by reading the code after the owner was shown his own edit as
    /// news, and a third added tomorrow would arrive the same silent way.
    ///
    /// A source scan, in the shape `MynahIdentityTests` uses for the same reason:
    /// the regression worth catching is "somebody added a way to write tasks",
    /// not any particular runtime value.
    ///
    /// Scoped to files that invoke a tool *directly*, by `callTool`. Writes the
    /// model makes go through `ToolLoop`'s generic dispatch, which never names
    /// `sage_task` — those are caught after the fact by
    /// `wroteToTheTaskList(_:)` reading the turn's trace, and both surfaces do.
    /// The gap this closes is the other kind: UI that changes the list with no
    /// turn to inspect, which is precisely what dragging a card is.
    ///
    /// Comments are excluded, so that *writing about* `sage_task` — as three
    /// catalogue files in the brain do — is not mistaken for calling it.
    func testEveryPlaceThatWritesTasksTellsTheWatch() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no Swift sources, so this guard is checking nothing")

        var silent: [String] = []
        var checked = 0
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8),
                  source.contains("callTool(") else { continue }
            let writesTasks = source.split(separator: "\n").contains {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.contains("\"sage_task\"") && !line.hasPrefix("//")
            }
            guard writesTasks else { continue }
            checked += 1
            if !source.contains("recordFromAnotherProcess") {
                silent.append(file.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(checked, 0, "the guard matched no direct task writer, so it checks nothing")

        XCTAssertEqual(
            silent, [],
            """
            these change the owner's task list without telling the proactive watch, \
            so it will report his own edit back to him over Signal as news: \
            \(silent.joined(separator: ", "))
            """
        )
    }

    // MARK: - Fixtures

    /// In a directory of its own, because `OwnerOnlyFileSecurity` chmods the
    /// containing directory to 0700 and the shared temp directory refuses that.
    /// The real marker lives beside the ledger, in a directory the appliance
    /// already owns.
    private static func scratchMarker() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-task-edits-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("own-task-edit", isDirectory: false)
    }

    private static func trace(_ calls: (name: String, failed: Bool)...) -> ToolLoopTrace {
        var trace = ToolLoopTrace(model: "stub", toolsOffered: 1)
        for call in calls {
            trace.toolCalls.append(
                ToolCallRecord(
                    iteration: 1,
                    name: call.name,
                    arguments: [:],
                    result: call.failed ? "refused" : "ok",
                    failed: call.failed,
                    durationSeconds: 0
                )
            )
        }
        return trace
    }

    private struct StubSource: ProactiveSource {
        var tasks: [WatchedTask] = []
        var messages: [AgentInboxItem] = []

        func waitingMessages(limit: Int) async throws -> [AgentInboxItem] { messages }
        func openTasks() async throws -> [WatchedTask] { tasks }
    }
}
