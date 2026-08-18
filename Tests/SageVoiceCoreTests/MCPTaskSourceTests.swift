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

/// **That the Tasks screen opens.**
///
/// It never has. Every screenshot the owner has sent says *"Tasks — this list
/// won't open"*, across every build, since the screen shipped.
///
/// The cause was not a bug in the reader — it was the third question in a row
/// being asked of the wrong source. The board began on `sage_backlog`, showed
/// nothing because nothing was assigned to this appliance, and that emptiness
/// was read as the tool being too narrow. So it moved to an unsigned
/// `GET /v1/dashboard/tasks?all=true`, which on the owner's node answers
/// `401 {"error":"unauthorized","login_required":true}` — verified again on
/// 2026-07-29 — and becomes `TaskSourceFailure.locked`.
///
/// An empty plate had been mistaken for a broken reader, and the fix for the
/// wrong diagnosis was a source the node refuses.
///
/// The owner's ruling settles which is right: *"sage_backlog should only return
/// this agents task - other agents you ask them for their backlog via pipe
/// message - and they can reply if they want - we cannot read other peoples todo
/// list bro."* So the narrow answer was always the correct one, and the test
/// that matters most here is the one asserting **an empty backlog is a board,
/// not a failure** — because getting that wrong is what started all of it.
final class MCPTaskSourceTests: XCTestCase {

    // MARK: Fixtures

    /// Shaped exactly like the payload `sage_backlog` returned on 2026-07-29,
    /// including the parts most likely to break a decoder: empty strings where a
    /// null would be expected, and a dictionary where an array would be.
    private func task(
        id: String,
        content: String,
        status: String,
        assignee: String = "65a6fab9",
        pickedUpBy: String = "",
        pickedUpAt: String = "",
        createdAt: String = "2026-07-29T12:23:10Z"
    ) -> JSONValue {
        .object([
            "assigned_to_you": .bool(true),
            "assignee": .string(assignee),
            "confidence": .double(0.9),
            "content": .string(content),
            "created_at": .string(createdAt),
            "memory_id": .string(id),
            "task_picked_up_at": .string(pickedUpAt),
            "task_picked_up_by": .string(pickedUpBy),
            "task_status": .string(status)
        ])
    }

    private func payload(_ domains: [String: [JSONValue]], total: Int? = nil) -> JSONValue {
        var members: [String: JSONValue] = [
            "tasks_by_domain": .object(domains.mapValues { JSONValue.array($0) }),
            "message": .string("You have \(total ?? 0) assigned open tasks.")
        ]
        members["total_open"] = .int(total ?? domains.values.map(\.count).reduce(0, +))
        return .object(members)
    }

    private func source(_ answer: JSONValue) -> MCPTaskSource {
        MCPTaskSource(call: { answer })
    }

    // MARK: The bug that kept it shut

    /// **The load-bearing test.** A node with nothing assigned is a node that
    /// answered. Treating that as a failure is what sent this board to an
    /// endpoint the node refuses, and it must never happen again.
    func testAnEmptyBacklogIsABoardRatherThanAFailure() async throws {
        let board = try await source(payload([:], total: 0)).board()

        XCTAssertTrue(board.isEmpty)
        XCTAssertTrue(board.planned.isEmpty)
        XCTAssertTrue(board.inProgress.isEmpty)
    }

    /// The same, through the model, because the model is what decides whether
    /// the words "this list won't open" appear on screen.
    @MainActor
    func testAnEmptyBacklogLeavesTheScreenWithNoTrouble() async {
        let model = TaskBoardModel(source: MCPTaskSource(call: { self.payload([:], total: 0) }))
        await model.refresh()

        XCTAssertNil(model.trouble, "an empty plate was reported as a broken list")
        XCTAssertNotNil(model.board)
    }

    /// A reply with neither tasks nor a total is genuinely unreadable, and must
    /// stay distinguishable from the empty case above.
    func testAReplyWithNothingInItIsUnreadable() async {
        do {
            _ = try await source(.object(["unexpected": .string("shape")])).board()
            XCTFail("a meaningless reply was accepted as a board")
        } catch {
            XCTAssertEqual(error as? TaskSourceFailure, .unreadable)
        }
    }

    // MARK: Reading the real shape

    func testTasksAreSortedIntoColumnsByStatus() async throws {
        let board = try await source(payload([
            "native-shell-ci": [
                task(id: "a", content: "[TASK] Write the thing", status: "planned"),
                task(id: "b", content: "[TASK] Doing the thing", status: "in_progress")
            ]
        ])).board()

        XCTAssertEqual(board.planned.map(\.id), ["a"])
        XCTAssertEqual(board.inProgress.map(\.id), ["b"])
    }

    /// The store writes `[TASK] ` onto every row. Left in, it is noise on every
    /// single card — the owner knows they are looking at tasks.
    func testTheStoredTaskPrefixIsNotShownToTheOwner() async throws {
        let board = try await source(payload([
            "d": [task(id: "a", content: "[TASK] Fix the relay", status: "planned")]
        ])).board()

        XCTAssertEqual(board.planned.first?.title, "Fix the relay")
    }

    /// **Empty strings, not nulls.** The node writes `""` for a timestamp it has
    /// no value for. A decoder treating that as a malformed date would reject
    /// most of a healthy board — every task nobody has started yet.
    func testAnUnstartedTaskWithEmptyTimestampsStillDecodes() async throws {
        let board = try await source(payload([
            "d": [task(id: "a", content: "[TASK] Not started", status: "planned",
                       pickedUpBy: "", pickedUpAt: "")]
        ])).board()

        let card = try XCTUnwrap(board.planned.first)
        XCTAssertEqual(card.id, "a")
        XCTAssertNil(card.statusChangedAt)
        XCTAssertNil(card.carrier)
        XCTAssertNotNil(card.createdAt, "a valid created_at was dropped")
    }

    /// The domain is the only grouping the owner chose themselves, and it comes
    /// from the dictionary key rather than from inside the row.
    func testTheDomainComesFromTheKeyItWasFiledUnder() async throws {
        let board = try await source(payload([
            "native-shell-ci": [task(id: "a", content: "[TASK] One", status: "planned")]
        ])).board()

        XCTAssertEqual(board.planned.first?.domain, "native-shell-ci")
    }

    /// A row with no id cannot be diffed or refreshed, so it is dropped rather
    /// than given a synthetic one — but it must not take the rest of the board
    /// down with it.
    func testARowWithNoIdIsSkippedWithoutLosingTheOthers() async throws {
        let board = try await source(payload([
            "d": [
                .object(["content": .string("[TASK] No id"), "task_status": .string("planned")]),
                task(id: "b", content: "[TASK] Has one", status: "planned")
            ]
        ])).board()

        XCTAssertEqual(board.planned.map(\.id), ["b"])
    }

    // MARK: Who is holding it

    /// Mynah picking up its own task is the ordinary case. "Picked up by
    /// <itself>" on every row is a line that carries no information.
    func testATaskThisAgentPickedUpItselfNamesNobody() async throws {
        let board = try await source(payload([
            "d": [task(id: "a", content: "[TASK] Mine", status: "in_progress",
                       assignee: "mynah", pickedUpBy: "mynah",
                       pickedUpAt: "2026-07-29T12:23:11Z")]
        ])).board()

        XCTAssertNil(board.inProgress.first?.carrier)
        XCTAssertNotNil(board.inProgress.first?.statusChangedAt)
    }

    /// Somebody else's hands on it is worth saying.
    func testATaskAnotherAgentPickedUpNamesThem() async throws {
        let board = try await source(payload([
            "d": [task(id: "a", content: "[TASK] Shared", status: "in_progress",
                       assignee: "mynah", pickedUpBy: "codex",
                       pickedUpAt: "2026-07-29T12:23:11Z")]
        ])).board()

        XCTAssertEqual(board.inProgress.first?.carrier, .pickedUpBy("codex"))
    }

    // MARK: What this source cannot see

    /// `sage_backlog` answers with open work. Finished tasks are **absent**, not
    /// empty — so the board must not claim to cover them, or the view prints
    /// "Nothing finished yet." for ever over work that was completed.
    func testTheBoardDoesNotClaimToCoverFinishedWork() async throws {
        let board = try await source(payload([
            "d": [task(id: "a", content: "[TASK] One", status: "planned")]
        ])).board()

        XCTAssertFalse(board.coversFinishedWork)
    }

    /// And an empty one says the same, so the columns do not flicker into
    /// existence on a board that happens to have nothing on it.
    func testEvenAnEmptyBoardDoesNotClaimToCoverFinishedWork() async throws {
        let board = try await source(payload([:], total: 0)).board()
        XCTAssertFalse(board.coversFinishedWork)
    }

    // MARK: Stability

    /// Dictionary order is not stable and `@Observable` announces on assignment
    /// rather than comparing, so an unstable order would repaint the screen
    /// every thirty seconds while the owner is reading it.
    func testTheSameBacklogReadTwiceIsTheSameBoard() async throws {
        let answer = payload([
            "zeta": [task(id: "z", content: "[TASK] Z", status: "planned")],
            "alpha": [task(id: "a", content: "[TASK] A", status: "planned")],
            "mid": [task(id: "m", content: "[TASK] M", status: "planned")]
        ])

        let first = try await source(answer).board()
        for _ in 0..<10 {
            let again = try await source(answer).board()
            XCTAssertEqual(again, first, "the board is not deterministic")
        }
    }

    // MARK: Failing

    /// A node that is not installed and a node that did not answer send somebody
    /// to two different places, so they must not collapse into one message.
    func testMCPFailuresKeepTheirDistinctions() {
        XCTAssertEqual(MCPTaskSource.failure(for: .missingExecutable("/nope")), .notInstalled)
        XCTAssertEqual(MCPTaskSource.failure(for: .timedOut("sage_backlog", 15)), .unreachable)
        XCTAssertEqual(MCPTaskSource.failure(for: .serverExited(1, "gone")), .unreachable)
        XCTAssertEqual(MCPTaskSource.failure(for: .malformedResponse("{")), .unreadable)
        XCTAssertEqual(MCPTaskSource.failure(for: .notStarted), .unreachable)
        XCTAssertEqual(MCPTaskSource.failure(for: .toolFailed("sage_backlog", "denied")), .refused)
    }

    /// A failed read must not erase the last good board — an owner with tasks
    /// and a node that stopped answering must never see an empty plate.
    @MainActor
    func testAFailedRefreshKeepsTheLastGoodBoard() async {
        struct Flaky: TaskSource {
            let answers: @Sendable () async throws -> TaskBoard
            func board() async throws -> TaskBoard { try await answers() }
            func move(taskID: String, to status: BoardTask.Progress) async throws {}
        }
        let good = TaskBoard.from(
            rows: [BoardTask(id: "a", title: "One", progress: .planned)],
            coversFinishedWork: false
        )
        let failNow = Failing()
        let model = TaskBoardModel(source: Flaky(answers: {
            if failNow.isOn { throw TaskSourceFailure.unreachable }
            return good
        }))

        await model.refresh()
        XCTAssertEqual(model.board, good)

        failNow.isOn = true
        await model.refresh()

        XCTAssertEqual(model.board, good, "a failed read erased the owner's tasks")
        XCTAssertNotNil(model.trouble)
    }
}

private final class Failing: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
#endif  // os(macOS)
