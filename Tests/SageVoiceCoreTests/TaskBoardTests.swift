// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The board that answers "what is on my plate".
///
/// The rule every test here defends: nothing on this screen may be invented. The
/// columns are the node's own workflow statuses, the cards carry only fields the
/// node publishes, and where the node cannot answer the board says so rather
/// than drawing an empty column that reads as "none".
///
/// **These tests were rewritten when the board changed feeds, and the reason is
/// worth keeping.** It used to read `sage_backlog`, which returns open tasks
/// *assigned to the signed agent* — so on a node holding 6 planned, 7 in
/// progress and 21 done it returned nothing, and the board rendered two empty
/// columns and a sentence blaming the node for not publishing finished work.
/// Several tests below passed happily against that, because they asserted the
/// decoder matched the tool rather than that the board matched the owner's life.
/// The fixtures here are now the shape `GET /v1/dashboard/tasks?all=true`
/// actually returns, taken from `web/handler.go:handleGetTasks`.
final class TaskBoardReadingTests: XCTestCase {

    private func payload(_ json: String) -> JSONValue {
        guard let value = JSONValue.parse(json) else {
            XCTFail("the fixture itself is not JSON")
            return .null
        }
        return value
    }

    /// One row of every status, shaped exactly as `handleGetTasks` writes it.
    private let feed = """
    {
      "tasks": [
        {
          "memory_id": "mem-1",
          "content": "[TASK] Get a written quote from the roofer",
          "domain_tag": "house",
          "task_status": "planned",
          "confidence_score": 0.8,
          "created_at": "2026-07-27T09:12:00Z",
          "provider": "",
          "submitting_agent": "",
          "assignee": "",
          "task_picked_up_by": ""
        },
        {
          "memory_id": "mem-2",
          "content": "[TASK] Find three plumbers who work Saturdays",
          "domain_tag": "house",
          "task_status": "in_progress",
          "created_at": "2026-07-28T08:00:00Z",
          "provider": "claude-code",
          "assignee": "mynah",
          "task_picked_up_by": "kimi-cli/errands"
        },
        {
          "memory_id": "mem-3",
          "content": "[TASK] Book the car in for its service",
          "domain_tag": "house",
          "task_status": "done",
          "created_at": "2026-07-01T10:00:00Z",
          "assignee": "claude-code/sage",
          "task_status_updated_at": "2026-07-28T12:00:00Z"
        },
        {
          "memory_id": "mem-4",
          "content": "[TASK] Move the broadband to the other provider",
          "domain_tag": "house",
          "task_status": "dropped",
          "created_at": "2026-07-02T10:00:00Z",
          "assignee": "claude-code/sage",
          "task_status_updated_at": "2026-07-27T12:00:00Z"
        }
      ],
      "total": 4
    }
    """

    // MARK: The columns are the node's statuses

    /// All four. An earlier board showed three and dropped abandoned work on
    /// the grounds that nobody wants a monument; CEREBRUM shows four over the
    /// same node, and an owner comparing them must not find work in one that is
    /// missing from the other.
    func testEveryStatusTheNodePublishesGetsAColumn() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(feed)))

        XCTAssertEqual(board.planned.map(\.id), ["mem-1"])
        XCTAssertEqual(board.inProgress.map(\.id), ["mem-2"])
        XCTAssertEqual(board.done.map(\.id), ["mem-3"])
        XCTAssertEqual(board.dropped.map(\.id), ["mem-4"])
    }

    /// `[TASK] ` is how the node files a task. It is not something the owner
    /// wrote and has no business being the first word on every card.
    func testTheFilingPrefixIsNotShownToTheOwner() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(feed)))

        XCTAssertEqual(board.planned.first?.title, "Get a written quote from the roofer")
        XCTAssertFalse(board.planned.contains { $0.title.contains("[TASK]") })
    }

    func testTheDomainTheTaskWasFiledUnderSurvives() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(feed)))
        XCTAssertEqual(board.planned.first?.domain, "house")
    }

    /// Which agent is holding a task is a property of the task, never a column.
    func testAnotherAgentHoldingATaskIsShownOnTheCard() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(feed)))
        XCTAssertEqual(board.inProgress.first?.carrier, .pickedUpBy("kimi-cli/errands"))
    }

    /// A task nobody was assigned says nothing about who holds it. Every row on
    /// this feed is the whole board rather than one agent's slice, so "assigned
    /// to nobody" is the ordinary case and not worth a line on the card.
    func testAnUnassignedTaskNamesNobody() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(feed)))
        XCTAssertNil(board.planned.first?.carrier)
    }

    /// The node keeps the assignee on a finished task purely as attribution, and
    /// its own words for that are "Completed by" and "Dropped by". Rendering
    /// those as "Assigned to" would say somebody is still working on it.
    func testFinishedWorkNamesWhoFinishedItRatherThanWhoHoldsIt() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(feed)))

        XCTAssertEqual(board.done.first?.carrier, .completedBy("claude-code/sage"))
        XCTAssertEqual(board.dropped.first?.carrier, .droppedBy("claude-code/sage"))
    }

    // MARK: Work the node will not classify

    /// **The one that matters most.** Rows written by an older version come back
    /// with an empty status because SAGE deliberately does not guess whether
    /// unknown work is planned or finished. Neither does this. Filing them into
    /// Planned would put finished work back on the owner's plate.
    func testAnEmptyStatusIsNeverGuessedIntoAColumn() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload("""
        {"tasks": [
          {"memory_id": "m1", "content": "[TASK] something old", "task_status": ""},
          {"memory_id": "m2", "content": "[TASK] no status key at all"}
        ]}
        """)))

        XCTAssertEqual(board.planned.count, 0, "an unlabelled task was filed under Planned")
        XCTAssertEqual(board.done.count, 0)
        XCTAssertEqual(board.unclassified.map(\.id), ["m1", "m2"])
    }

    /// A status this app has never heard of is a later node version. Held in the
    /// same place as the unlabelled ones — counted, and not guessed at. Dropping
    /// it silently would lose the owner's work rather than merely fail to file
    /// it.
    func testAnUnknownStatusIsHeldRatherThanGuessedOrDiscarded() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload("""
        {"tasks": [{"memory_id": "m1", "content": "[TASK] blocked", "task_status": "waiting"}]}
        """)))

        XCTAssertEqual(board.unclassified.map(\.id), ["m1"])
        XCTAssertFalse(board.isEmpty, "a task the board could not file vanished entirely")
    }

    func testARowWithNoIdOrNoWordsIsNotACard() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload("""
        {"tasks": [
          {"content": "[TASK] no id", "task_status": "planned"},
          {"memory_id": "m2", "content": "[TASK]   ", "task_status": "planned"},
          {"memory_id": "m3", "content": "[TASK] a real one", "task_status": "planned"}
        ]}
        """)))

        XCTAssertEqual(board.planned.map(\.id), ["m3"])
    }

    // MARK: The seven-day window

    /// Measured from the terminal transition and not from `created_at`, which is
    /// the whole reason the node publishes `task_status_updated_at`. A task
    /// written in March and finished yesterday is one the owner still wants to
    /// see; measured from creation it would already be gone.
    func testTheWindowIsMeasuredFromWhenWorkStoppedNotWhenItStarted() {
        let now = Date()
        let finishedYesterdayStartedInMarch = BoardTask(
            id: "1",
            title: "long one",
            progress: .done,
            createdAt: now.addingTimeInterval(-120 * 24 * 3600),
            statusChangedAt: now.addingTimeInterval(-24 * 3600)
        )
        let board = TaskBoard(done: [finishedYesterdayStartedInMarch])

        XCTAssertEqual(
            board.recent(board.done, showingAll: false, now: now).count,
            1,
            "a card finished yesterday was hidden because it was written months ago"
        )
        XCTAssertEqual(board.olderThanWindow(now: now), 0)
    }

    func testWorkFinishedMoreThanAWeekAgoLeavesTheBoardUntilAskedFor() {
        let now = Date()
        let old = BoardTask(
            id: "1", title: "old", progress: .done,
            statusChangedAt: now.addingTimeInterval(-8 * 24 * 3600)
        )
        let fresh = BoardTask(
            id: "2", title: "fresh", progress: .done,
            statusChangedAt: now.addingTimeInterval(-2 * 24 * 3600)
        )
        let board = TaskBoard(done: [old, fresh])

        XCTAssertEqual(board.recent(board.done, showingAll: false, now: now).map(\.id), ["2"])
        XCTAssertEqual(board.recent(board.done, showingAll: true, now: now).map(\.id), ["1", "2"])
        XCTAssertEqual(board.olderThanWindow(now: now), 1)
    }

    /// Abandoned work ages out on the same clock as finished work.
    func testDroppedWorkAgesOutTheSameWay() {
        let now = Date()
        let board = TaskBoard(dropped: [
            BoardTask(id: "1", title: "old", progress: .dropped,
                      statusChangedAt: now.addingTimeInterval(-30 * 24 * 3600))
        ])
        XCTAssertEqual(board.recent(board.dropped, showingAll: false, now: now).count, 0)
        XCTAssertEqual(board.olderThanWindow(now: now), 1)
    }

    /// A blank timestamp means the node could not say when it finished. Kept:
    /// disappearing a card because a field was empty is losing work on a
    /// technicality.
    func testACardWithNoTerminalTimestampIsKeptRatherThanHidden() {
        let board = TaskBoard(done: [BoardTask(id: "1", title: "no stamp", progress: .done)])
        XCTAssertEqual(board.recent(board.done, showingAll: false, now: Date()).count, 1)
    }

    // MARK: Robustness

    func testAnEmptyFeedIsAnEmptyBoardNotAFailure() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(#"{"tasks": [], "total": 0}"#)))
        XCTAssertTrue(board.isEmpty)
    }

    /// Anything that is not the documented shape — an error object, a feed that
    /// changed underneath us — reads as "could not be read", never as an empty
    /// plate.
    func testAReplyWithoutTheDocumentedShapeIsNotAnEmptyBoard() {
        XCTAssertNil(TaskBoardReading.board(from: payload(#"{"error": "unauthorized"}"#)))
        XCTAssertNil(TaskBoardReading.board(fromResponse: Data("the node fell over".utf8)))
        XCTAssertNil(TaskBoardReading.board(fromResponse: Data()))
    }

    func testTheFeedIsReadStraightFromTheResponseBody() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(fromResponse: Data(feed.utf8)))
        XCTAssertEqual(board.planned.count, 1)
    }
}

// MARK: - Where the board reads from

final class CerebrumTaskSourceTests: XCTestCase {

    /// The shipped REST default.
    func testTheDefaultEndpointIsTheLocalNodesTaskFeed() {
        let url = CerebrumTaskSource.defaultEndpoint(environment: [:])
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8080/v1/dashboard/tasks")
    }

    func testAnOverrideIsHonouredWhenItPointsAtThisMachine() {
        let url = CerebrumTaskSource.defaultEndpoint(environment: ["SAGE_API_URL": "http://localhost:9999"])
        XCTAssertEqual(url.absoluteString, "http://localhost:9999/v1/dashboard/tasks")
    }

    /// A task board fetched from somewhere else on the network would be another
    /// person's life rendered as the owner's. The override is ignored rather
    /// than obeyed, and the tricks that beat a naive host check — a lookalike
    /// subdomain, an embedded credential, the integer form — are all rejected by
    /// `LoopbackSecurity`.
    func testAnOverridePointingOffThisMachineIsIgnored() {
        for hostile in ["http://192.168.1.9:8080", "http://127.0.0.1.evil.com",
                        "http://127.0.0.1@evil.com", "http://2130706433", "https://example.com"] {
            let url = CerebrumTaskSource.defaultEndpoint(environment: ["SAGE_API_URL": hostile])
            XCTAssertEqual(
                url.absoluteString,
                "http://127.0.0.1:8080/v1/dashboard/tasks",
                "\(hostile) was accepted as the task feed"
            )
        }
    }

    /// The backend clamps anything larger, so asking for more would be a number
    /// in the source that the node quietly disagrees with.
    func testTheCardLimitIsTheBackendsOwnMaximum() {
        XCTAssertEqual(CerebrumTaskSource.maximumCards, 500)
    }

    /// **The path the owner actually hits, proved end to end.**
    ///
    /// Everything else here is decoding against fixtures. This is the only
    /// assertion that exercises the real request against the real node, and it
    /// is the one that matters before a build goes out: his node is encrypted,
    /// so the unsigned local read is answered `401 {"login_required":true}`, and
    /// the whole design rests on that becoming `locked` rather than an empty
    /// board. An owner with 34 open tasks being shown "Nothing planned" is the
    /// failure this screen was rewritten to prevent.
    ///
    /// Passes on either kind of node: an unencrypted one answers 200 and the
    /// board reads, an encrypted one throws `locked`. What must never happen is
    /// a success carrying no tasks.
    func testTheRealNodeEitherAnswersOrSaysItIsLocked() async throws {
        try LiveNode.required("the real node either answers or says it is locked")

        do {
            let board = try await CerebrumTaskSource().board()
            // An unencrypted node. A readable board is a real answer, empty or
            // not — but it must have come from a 200, not from a swallowed 401.
            XCTAssertNotNil(board, "the source returned no board and did not throw")
        } catch let failure as TaskSourceFailure {
            XCTAssertEqual(
                failure,
                .locked,
                "the node refused in a way the board does not recognise as locked, so it would "
                    + "render \(failure) instead of offering the owner their passphrase"
            )
            XCTAssertEqual(failure.failure, TaskBoardTrouble.locked)
        }
    }
}

// MARK: - What the board says when it cannot see

@MainActor
final class TaskBoardModelTests: XCTestCase {

    private func task(_ id: String, _ progress: BoardTask.Progress) -> BoardTask {
        BoardTask(id: id, title: "task \(id)", progress: progress)
    }

    func testAGoodReadFillsTheBoard() async {
        let source = ScriptedTaskSource(results: [.success(TaskBoard(planned: [task("1", .planned)]))])
        let model = TaskBoardModel(source: source)

        await model.refresh()

        XCTAssertEqual(model.board?.planned.count, 1)
        XCTAssertNil(model.trouble)
    }

    /// The one this screen exists to get right: an owner with twelve tasks and a
    /// node that has stopped answering must never be told they have none.
    func testTasksSurviveTheNodeGoingAway() async {
        let source = ScriptedTaskSource(results: [
            .success(TaskBoard(planned: [task("1", .planned), task("2", .planned)])),
            .failure(TaskSourceFailure.unreachable)
        ])
        let model = TaskBoardModel(source: source)

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(model.board?.planned.count, 2, "a failed refresh emptied the owner's board")
        XCTAssertEqual(model.trouble, TaskBoardTrouble.cannotReach)
    }

    /// And with nothing ever read, there is no board to show — so the screen
    /// must say why rather than draw four empty columns.
    func testAFailureWithNothingReadYetLeavesNoBoardToMisread() async {
        let source = ScriptedTaskSource(results: [.failure(TaskSourceFailure.unreachable)])
        let model = TaskBoardModel(source: source)

        await model.refresh()

        XCTAssertNil(model.board)
        XCTAssertEqual(model.trouble, TaskBoardTrouble.cannotReach)
    }

    /// An encrypted node answers an unsigned local read with `401
    /// {"login_required":true}` — verified against the owner's own node, which
    /// holds 34 tasks. If this ever resolves to an empty board rather than a
    /// locked one, the app tells somebody with a full plate that their life is
    /// empty because a vault is shut.
    func testALockedNodeIsALockedNodeAndNeverAnEmptyPlate() async {
        let model = TaskBoardModel(source: ScriptedTaskSource(results: [.failure(TaskSourceFailure.locked)]))

        await model.refresh()

        XCTAssertNil(model.board, "a locked node produced a board")
        XCTAssertEqual(model.trouble, TaskBoardTrouble.locked)
    }

    /// And the words have to hold the line too. "Nothing planned" is what the
    /// columns say; the locked sentence must contradict it, not echo it.
    func testTheLockedSentenceSaysTheTasksAreStillThere() {
        let said = (TaskBoardTrouble.locked.headline + " " + TaskBoardTrouble.locked.explanation)
        XCTAssertTrue(said.lowercased().contains("still there"))
        XCTAssertTrue(TaskBoardTrouble.locked.canRetry, "a node the owner can unlock offers no retry")
        for lie in ["no tasks", "nothing on", "empty", "you have none"] {
            XCTAssertFalse(said.lowercased().contains(lie), "the locked sentence says \"\(lie)\"")
        }
    }

    /// An empty plate is not a failure and must carry no trouble with it.
    func testAnEmptyPlateIsNotAFailure() async {
        let source = ScriptedTaskSource(results: [.success(TaskBoard())])
        let model = TaskBoardModel(source: source)

        await model.refresh()

        XCTAssertNotNil(model.board, "an empty board is still a board")
        XCTAssertTrue(model.board?.isEmpty == true)
        XCTAssertNil(model.trouble)
    }

    func testTheNodeComingBackClearsTheTrouble() async {
        let source = ScriptedTaskSource(results: [
            .failure(TaskSourceFailure.unreachable),
            .success(TaskBoard(planned: [task("1", .planned)]))
        ])
        let model = TaskBoardModel(source: source)

        await model.refresh()
        await model.refresh()

        XCTAssertNil(model.trouble)
        XCTAssertEqual(model.board?.planned.count, 1)
    }

    /// A missing node is a different sentence from a node that will not answer,
    /// and both are different from one that is merely locked: they send the
    /// owner to reinstall, to wait, and to their passphrase respectively.
    func testEachFailureKeepsItsOwnSentence() async {
        for (failure, expected) in [
            (TaskSourceFailure.notInstalled, TaskBoardTrouble.notInstalled),
            (TaskSourceFailure.unreadable, TaskBoardTrouble.cannotRead),
            (TaskSourceFailure.unreachable, TaskBoardTrouble.cannotReach),
            (TaskSourceFailure.locked, TaskBoardTrouble.locked),
            (TaskSourceFailure.refused, TaskBoardTrouble.refused)
        ] {
            let model = TaskBoardModel(source: ScriptedTaskSource(results: [.failure(failure)]))
            await model.refresh()
            XCTAssertEqual(model.trouble, expected)
        }
    }

    /// Every failure sentence, held to the same standard as the locked one: none
    /// of them may leave an owner thinking their tasks are gone.
    func testNoFailureSentenceClaimsTheWorkIsGone() {
        let all = [
            TaskBoardTrouble.locked, TaskBoardTrouble.cannotReach, TaskBoardTrouble.cannotRead,
            TaskBoardTrouble.refused, TaskBoardTrouble.notInstalled
        ]
        for trouble in all {
            let said = (trouble.headline + " " + trouble.explanation).lowercased()
            for lie in ["no tasks", "you have none", "nothing left", "list is empty"] {
                XCTAssertFalse(said.contains(lie), "\"\(trouble.headline)\" says \"\(lie)\"")
            }
        }
    }

    /// The board polls on a timer, and `@Observable` announces rather than
    /// compares — so an unchanged plate must not repaint the screen every thirty
    /// seconds.
    func testAnUnchangedPlateDoesNotRepaintTheBoard() async {
        let board = TaskBoard(planned: [task("1", .planned)])
        let model = TaskBoardModel(source: ScriptedTaskSource(results: [.success(board), .success(board)]))
        await model.refresh()

        let changed = BoardChangeFlag()
        withObservationTracking {
            _ = model.board
        } onChange: {
            changed.fired = true
        }

        await model.refresh()
        XCTAssertFalse(changed.fired, "an unchanged board was written back over itself")
    }
}

/// A source that hands back a prepared sequence of answers, so a test can put
/// the node's failure exactly where it wants it.
private final class ScriptedTaskSource: TaskSource, @unchecked Sendable {
    func move(taskID: String, to status: BoardTask.Progress) async throws {}

    private var results: [Result<TaskBoard, Error>]
    private let lock = NSLock()

    init(results: [Result<TaskBoard, Error>]) {
        self.results = results
    }

    func board() async throws -> TaskBoard {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else { throw TaskSourceFailure.unreachable }
        return try results.removeFirst().get()
    }
}

private final class BoardChangeFlag: @unchecked Sendable {
    var fired = false
}
#endif  // os(macOS)
