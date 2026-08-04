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
    /// **The clock is pinned, and it has to be.** Written against `Date()` this
    /// passed all morning and began failing at one o'clock — the appointment in
    /// the fixture lapsed, the departure became explained, and the line it
    /// asserts correctly stopped being emitted. It then crashed on `lines[0]`
    /// rather than failing, which is how a green suite turns into a fatal error
    /// between two runs with no edit in between.
    ///
    /// A test whose result depends on the hour it is run is not a test.
    func testADepartedTaskIsNamed() throws {
        let lines = ProactiveWatch.taskNews(
            [],
            against: ["a": "open"],
            titles: ["a": "Dentist appointment — Tuesday 4 August 2026, 1pm"],
            seeded: true,
            // The morning of, so the appointment is still ahead and its
            // departure is genuinely unexplained.
            now: Self.at(2026, 8, 4, 9, 0)
        )

        XCTAssertEqual(lines.count, 1)
        let first = try XCTUnwrap(lines.first)
        XCTAssertTrue(first.contains("Dentist appointment"), first)
        XCTAssertTrue(first.contains("came off the list"), first)
    }

    private static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return Calendar.current.date(from: parts)!
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
    /// **The first version of this scan checked one file and said so in the
    /// past tense.** It kept only files containing both `callTool(` and a
    /// non-comment `"sage_task"`, which over the whole of `Sources/` is
    /// `MCPTaskSource.swift` and nothing else, and its `checked > 0` sentinel
    /// was satisfied at one. So it reported success having looked at the board's
    /// drag gesture and at no other door into the list — the call surface, which
    /// runs a full tool loop down a phone line, was never in scope at all.
    ///
    /// Two kinds of door are checked now, because there are two.
    ///
    /// - A **direct** call: `callTool("sage_task", …)`. Nothing inspects a trace
    ///   afterwards because there is no turn — dragging a card does not spend
    ///   one — so the call site itself has to write the note, and the block it
    ///   sits in must say `recordFromAnotherProcess`.
    /// - A **model turn**: anything handed a `transcript:`. The model may call
    ///   `sage_task` on any of them, through `ToolLoop`'s generic dispatch,
    ///   which never names the tool. Those are caught after the fact by
    ///   `wroteToTheTaskList(_:)` reading the turn's trace — so the guard
    ///   follows the turn's own result binding and requires *that* value to
    ///   reach it. Following the binding rather than the file is what stops one
    ///   fixed call site in a file covering an unfixed one beside it.
    ///
    /// Comments are stripped from both halves. They were stripped from the
    /// `"sage_task"` half only, so a file that merely *mentioned*
    /// `recordFromAnotherProcess` in prose — as the fix's own comments do, at
    /// length — counted as having called it.
    func testEveryPlaceThatWritesTasksTellsTheWatch() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no Swift sources, so this guard is checking nothing")

        var sites: [TaskWriteSite] = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            sites += Self.taskWriteSites(in: source, file: file.lastPathComponent)
        }

        // Both sentinels name a kind rather than a count, because a count of one
        // is exactly what the previous version was satisfied by.
        XCTAssertTrue(
            sites.contains { $0.kind == .directCall },
            "no direct sage_task call was found anywhere in Sources/, so half this guard checks nothing"
        )
        XCTAssertTrue(
            sites.contains { $0.kind == .modelTurn },
            "no model turn was found anywhere in Sources/, so half this guard checks nothing"
        )

        let silent = sites.filter { !$0.tellsTheWatch }.map(\.description)
        XCTAssertEqual(
            silent, [],
            """
            these change the owner's task list without telling the proactive watch, \
            so it will report his own edit back to him over Signal as news, a quarter of \
            an hour later, as though a stranger had done it: \(silent.joined(separator: "; "))
            """
        )
    }

    // MARK: The scan

    /// One place that can change the owner's task list.
    struct TaskWriteSite {
        enum Kind { case directCall, modelTurn }

        let file: String
        let line: Int
        let kind: Kind
        let tellsTheWatch: Bool
        /// What it would have to do to stop being reported here.
        let owed: String

        var description: String { "\(file):\(line) — \(owed)" }
    }

    /// Every door into the task list in one file, and whether each tells the
    /// watch it went through.
    static func taskWriteSites(in source: String, file: String) -> [TaskWriteSite] {
        let scan = SwiftSourceScan(source)
        var sites: [TaskWriteSite] = []

        for call in scan.indices(of: "callTool(") {
            guard let arguments = scan.arguments(from: call),
                  scan.text(in: arguments).contains("\"sage_task\"") else { continue }
            // The block the call sits in, matched by brace depth. `MCPTaskSource`
            // writes its note in the same `do { … }` as the call, which is the
            // shape being required: a write and its note are one action.
            let scope = scan.enclosingBlock(of: call).map { scan.text(in: $0) } ?? scan.text(in: 0..<scan.characters.count)
            sites.append(
                TaskWriteSite(
                    file: file,
                    line: scan.line(of: call),
                    kind: .directCall,
                    tellsTheWatch: scope.contains("recordFromAnotherProcess"),
                    owed: "a direct sage_task call whose own block never calls OwnTaskEdits.recordFromAnotherProcess"
                )
            )
        }

        for call in scan.indices(of: ".run(") {
            guard let arguments = scan.arguments(from: call),
                  scan.text(in: arguments).contains("transcript:"),
                  Self.callsTheBrainDirectly(scan.receiver(before: call), in: scan) else { continue }
            // The turn's result, followed by name. The declaration is often a
            // line above the call — the daemon's is
            // `let result = try await withDeadline(…) { try await brain.run(…) }`
            // — so it cannot be read off the call's own line, and a binding
            // whose scope does not contain the call is a different statement's.
            let binding = scan.bindingBefore(call).flatMap { binding -> (name: String, scope: String)? in
                guard let scope = scan.enclosingBlock(of: binding.index), scope.contains(call) else { return nil }
                return (binding.name, scan.text(in: scope))
            }
            guard let binding else {
                sites.append(
                    TaskWriteSite(
                        file: file,
                        line: scan.line(of: call),
                        kind: .modelTurn,
                        tellsTheWatch: false,
                        owed: "a model turn whose result is discarded, so nothing can see whether it wrote a task"
                    )
                )
                continue
            }
            sites.append(
                TaskWriteSite(
                    file: file,
                    line: scan.line(of: call),
                    kind: .modelTurn,
                    tellsTheWatch: binding.scope.contains("wroteToTheTaskList(\(binding.name)"),
                    owed: """
                        a model turn whose result is never passed to \
                        OwnTaskEdits.wroteToTheTaskList(\(binding.name).trace)
                        """
                )
            )
        }

        return sites
    }

    /// Whether `receiver.run(transcript:)` reaches the brain here, or hands the
    /// turn to something in this repository that runs it.
    ///
    /// **Not a nicety — without it this guard demands a second note for one
    /// edit.** The window's view model calls `engine.run(transcript:history:)`
    /// on a `TurnEngine`, whose implementation is `ConversationEngine.run`, and
    /// that function is scanned in its own right at the line where it calls the
    /// loop and already writes the note. Requiring the wrapper to write one too
    /// would mean two markers for one edit and, worse, a guard that reads as
    /// "record it wherever you happen to see the word run".
    ///
    /// An unrecognised receiver counts as the brain. A false name here costs a
    /// comment and a re-read; a missed surface costs the owner his own edit read
    /// back to him over Signal, which is the failure this file exists for.
    static func callsTheBrainDirectly(_ receiver: String, in scan: SwiftSourceScan) -> Bool {
        guard !receiver.isEmpty else { return true }
        var annotated = false
        for keyword in ["let \(receiver)", "var \(receiver)"] {
            for declaration in scan.indices(of: keyword) {
                let line = scan.statement(at: declaration)
                if line.contains("ToolLoop") { return true }
                let rest = line.components(separatedBy: receiver).dropFirst().first ?? ""
                if rest.trimmingCharacters(in: .whitespaces).hasPrefix(":") { annotated = true }
            }
        }
        return !annotated
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
