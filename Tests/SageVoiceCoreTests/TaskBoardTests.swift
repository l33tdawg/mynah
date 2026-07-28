import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The board that answers "what is on my plate".
///
/// The rule every test here defends: nothing on this screen may be invented. The
/// columns are the node's own workflow statuses, the cards carry only fields the
/// node publishes, and where the node cannot answer the board says so rather
/// than drawing an empty column that reads as "none".
final class TaskBoardReadingTests: XCTestCase {

    /// The shape `sage_backlog` documents: tasks grouped by domain, each row
    /// carrying its workflow status and who is holding it.
    private func payload(_ json: String) -> JSONValue {
        guard let value = JSONValue.parse(json) else {
            XCTFail("the fixture itself is not JSON")
            return .null
        }
        return value
    }

    private let backlog = """
    {
      "tasks_by_domain": {
        "house": [
          {
            "memory_id": "mem-1",
            "content": "[TASK] Get a written quote from the roofer",
            "task_status": "planned",
            "confidence": 0.8,
            "created_at": "2026-07-27T09:12:00.123Z",
            "assignee": "mynah",
            "assigned_to_you": true
          },
          {
            "memory_id": "mem-2",
            "content": "[TASK] Find three plumbers who work Saturdays",
            "task_status": "in_progress",
            "created_at": "2026-07-28T08:00:00Z",
            "assignee": "mynah",
            "assigned_to_you": true,
            "task_picked_up_by": "kimi-cli/errands"
          }
        ],
        "general": [
          {
            "memory_id": "mem-3",
            "content": "[TASK] Call your sister back",
            "task_status": "planned",
            "created_at": "2026-07-26T18:30:00Z",
            "assignee": "mynah",
            "assigned_to_you": true
          }
        ]
      },
      "total_open": 3,
      "message": "3 open tasks"
    }
    """

    // MARK: The columns are the node's statuses

    func testOpenTasksLandInTheColumnTheirStatusNames() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(backlog)))

        XCTAssertEqual(board.planned.map(\.id), ["mem-1", "mem-3"])
        XCTAssertEqual(board.inProgress.map(\.id), ["mem-2"])
    }

    /// Newest first, so a task the owner just asked for is where they will look
    /// for it.
    func testAColumnIsOrderedNewestFirst() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(backlog)))

        XCTAssertEqual(
            board.planned.map(\.title),
            ["Get a written quote from the roofer", "Call your sister back"]
        )
    }

    /// `[TASK] ` is how the node files a task. It is not something the owner
    /// wrote and has no business being the first word on every card.
    func testTheFilingPrefixIsNotShownToTheOwner() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(backlog)))

        XCTAssertEqual(board.planned.first?.title, "Get a written quote from the roofer")
        XCTAssertFalse(board.planned.contains { $0.title.contains("[TASK]") })
    }

    func testTheDomainTheTaskWasFiledUnderSurvives() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(backlog)))

        XCTAssertEqual(board.planned.first?.domain, "house")
        XCTAssertEqual(board.planned.last?.domain, "general")
    }

    /// Which agent is holding a task is a property of the task, never a column.
    func testAnotherAgentHoldingATaskIsShownOnTheCard() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(backlog)))

        XCTAssertEqual(board.inProgress.first?.carrier, .pickedUpBy("kimi-cli/errands"))
    }

    /// The ordinary case is silent: every row the backlog returns is this
    /// appliance's own, and naming it on every card would be noise.
    func testTheApplianceHoldingItsOwnWorkIsNotAnnounced() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(backlog)))

        XCTAssertNil(board.planned.first?.carrier)
    }

    func testTaskAssignedElsewhereNamesTheAgent() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload("""
        {"tasks_by_domain": {"general": [
          {"memory_id": "m", "content": "[TASK] chase the invoice", "task_status": "planned",
           "assignee": "other-agent", "assigned_to_you": false}
        ]}}
        """)))

        XCTAssertEqual(board.planned.first?.carrier, .assignedTo("other-agent"))
    }

    // MARK: What is not shown

    /// Finished work is `nil`, not `[]`. `sage_backlog` returns open tasks only,
    /// so nothing here knows whether anything is done — and a column reading
    /// "none" would be a claim nobody made.
    func testFinishedWorkIsUnknownRatherThanEmpty() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload(backlog)))

        XCTAssertNil(board.done, "the board claimed to know about finished work")
    }

    /// Abandoned work gets no column, and if the node ever hands one over it is
    /// dropped rather than filed under a heading it does not belong to.
    func testADroppedTaskIsNotShownAnywhere() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload("""
        {"tasks_by_domain": {"general": [
          {"memory_id": "m1", "content": "[TASK] abandoned", "task_status": "dropped"},
          {"memory_id": "m2", "content": "[TASK] still open", "task_status": "planned"}
        ]}}
        """)))

        XCTAssertEqual(board.planned.map(\.id), ["m2"])
        XCTAssertEqual(board.inProgress.count, 0)
        XCTAssertNil(board.done)
    }

    /// A status this app has never heard of is a later node version, not a
    /// column to guess at.
    func testAnUnknownStatusIsDroppedRatherThanGuessedAt() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload("""
        {"tasks_by_domain": {"general": [
          {"memory_id": "m1", "content": "[TASK] blocked on someone", "task_status": "waiting"}
        ]}}
        """)))

        XCTAssertTrue(board.isEmpty)
    }

    func testARowWithNoIdOrNoWordsIsNotACard() throws {
        let board = try XCTUnwrap(TaskBoardReading.board(from: payload("""
        {"tasks_by_domain": {"general": [
          {"content": "[TASK] no id", "task_status": "planned"},
          {"memory_id": "m2", "content": "[TASK]   ", "task_status": "planned"},
          {"memory_id": "m3", "content": "[TASK] a real one", "task_status": "planned"}
        ]}}
        """)))

        XCTAssertEqual(board.planned.map(\.id), ["m3"])
    }

    // MARK: Robustness

    /// The node prepends a plain-text banner addressed to an AI agent on the
    /// first call of a session. The board has to read straight past it.
    func testAReplyWrappedInTheNodesBannerStillReads() throws {
        let text = """
        Welcome back. You have 3 open tasks and 12 memories.

        ---

        {"tasks_by_domain": {"general": [
          {"memory_id": "m1", "content": "[TASK] the real one", "task_status": "planned"}
        ]}, "total_open": 1}
        """

        let board = try XCTUnwrap(TaskBoardReading.board(fromToolText: text))
        XCTAssertEqual(board.planned.map(\.title), ["the real one"])
    }

    /// An empty plate is a readable answer, and a different thing from a broken
    /// one — see the model tests below.
    func testAnEmptyBacklogIsAnEmptyBoardNotAFailure() throws {
        let board = try XCTUnwrap(
            TaskBoardReading.board(from: payload("""
            {"tasks_by_domain": {}, "total_open": 0, "message": "no open tasks"}
            """))
        )

        XCTAssertTrue(board.isEmpty)
        XCTAssertEqual(board.planned.count, 0)
    }

    /// Anything that is not the documented shape — an error object, a tool that
    /// changed underneath us — reads as "could not be read", never as an empty
    /// plate.
    func testAReplyWithoutTheDocumentedShapeIsNotAnEmptyBoard() {
        XCTAssertNil(TaskBoardReading.board(from: payload(#"{"error": "no such tool"}"#)))
        XCTAssertNil(TaskBoardReading.board(fromToolText: "the node fell over"))
        XCTAssertNil(TaskBoardReading.board(fromToolText: ""))
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
    /// must say why rather than draw three empty columns.
    func testAFailureWithNothingReadYetLeavesNoBoardToMisread() async {
        let source = ScriptedTaskSource(results: [.failure(TaskSourceFailure.unreachable)])
        let model = TaskBoardModel(source: source)

        await model.refresh()

        XCTAssertNil(model.board)
        XCTAssertEqual(model.trouble, TaskBoardTrouble.cannotReach)
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

    /// A missing node is a different sentence from a node that will not answer:
    /// one of them tells the owner to reinstall, the other to wait a moment.
    func testEachFailureKeepsItsOwnSentence() async {
        for (failure, expected) in [
            (TaskSourceFailure.notInstalled, TaskBoardTrouble.notInstalled),
            (TaskSourceFailure.unreadable, TaskBoardTrouble.cannotRead),
            (TaskSourceFailure.unreachable, TaskBoardTrouble.cannotReach)
        ] {
            let model = TaskBoardModel(source: ScriptedTaskSource(results: [.failure(failure)]))
            await model.refresh()
            XCTAssertEqual(model.trouble, expected)
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
