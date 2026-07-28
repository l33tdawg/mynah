import Foundation
import Observation
import OSLog
import SageVoiceCore

// MARK: - What is on the owner's plate

private let boardLog = Logger(subsystem: "com.sage.mynah", category: "board")

/// One task, as the board draws it.
///
/// Every field here is something the node actually publishes. There is no
/// priority, no due date and no estimate, because `sage_backlog` returns none of
/// those and a board that invents them is a board nobody can trust twice.
struct BoardTask: Identifiable, Equatable, Sendable {

    /// Another agent's hands on this task, and which kind of involvement it is.
    /// The two are not the same claim and the card says which.
    enum Carrier: Equatable, Sendable {
        /// Assigned here, but another agent started it.
        case pickedUpBy(String)
        /// The node says this is not this appliance's work at all.
        case assignedTo(String)

        var agent: String {
            switch self {
            case .pickedUpBy(let agent), .assignedTo(let agent): return agent
            }
        }
    }

    /// The workflow the node really runs.
    ///
    /// Not a shape invented for the screen: tasks carry `planned`,
    /// `in_progress`, `done` and `dropped`, new ones enter as `planned`, and a
    /// task only reaches `in_progress` once it has an owner. Three of those are
    /// columns. `dropped` is not — see `TaskBoard`.
    enum Progress: Equatable, Sendable {
        case planned
        case inProgress
        case done

        init?(nodeStatus: String) {
            switch nodeStatus {
            case "planned": self = .planned
            case "in_progress": self = .inProgress
            case "done": self = .done
            // `dropped`, and anything a later node version invents, is dropped
            // rather than guessed at. A task filed under the wrong heading is
            // worse than a task the board admits it did not show.
            default: return nil
            }
        }
    }

    /// The task's memory id, which is stable across reads.
    let id: String
    var title: String
    var progress: Progress
    /// The domain the task was filed under. Shown because it is the only
    /// grouping the owner themselves chose.
    var domain: String?
    /// Who is holding this, when that is not simply the appliance itself.
    ///
    /// The distinction the board must not lose: *which agent* is doing a thing
    /// is a property of the task, not a column. A column of "sent to other
    /// agents" would be a heading with nothing to populate it, since the node
    /// hands this appliance only the work assigned to it.
    var carrier: Carrier?
    var createdAt: Date?
}

/// The three columns, and an honest hole where the fourth answer should be.
struct TaskBoard: Equatable, Sendable {
    var planned: [BoardTask] = []
    var inProgress: [BoardTask] = []

    /// Finished work — `nil` when nobody can say, which is not the same as `[]`.
    ///
    /// It is `nil` today for a reason worth writing down rather than papering
    /// over: `sage_backlog` returns *open* tasks only (planned and in-progress),
    /// and the other tool that can list memories, `sage_list`, publishes a
    /// memory's own status — proposed, committed, deprecated — and not the task
    /// workflow status, so nothing it returns can tell a finished task from an
    /// open one. Until something publishes them, the column says it cannot see
    /// them. It never says there are none.
    var done: [BoardTask]?

    var isEmpty: Bool {
        planned.isEmpty && inProgress.isEmpty && (done?.isEmpty ?? true)
    }

    /// Splits what the node returned into columns.
    ///
    /// `dropped` tasks never arrive here — the backlog is open work — and if one
    /// ever did, `Progress` drops it. That is the decision: abandoned work is
    /// not shown at all rather than given a column of its own. A column of
    /// things the owner gave up on is a monument, and nobody asked for one.
    static func from(rows: [BoardTask]) -> TaskBoard {
        // Newest first, so a task the owner just asked for is at the top of the
        // column where they will look for it. The node returns no ordering of
        // its own beyond the domain grouping.
        let ordered = rows.sorted { first, second in
            (first.createdAt ?? .distantPast) > (second.createdAt ?? .distantPast)
        }
        return TaskBoard(
            planned: ordered.filter { $0.progress == .planned },
            inProgress: ordered.filter { $0.progress == .inProgress },
            done: nil
        )
    }
}

// MARK: - Where the board gets its tasks

/// Anything that can answer "what is on the owner's plate?".
///
/// A protocol so the previews and the tests can drive the real screen without a
/// node — and so the one implementation that talks to the node is the only place
/// that can put a task on the board.
protocol TaskSource: Sendable {
    func board() async throws -> TaskBoard
}

/// What went wrong, in the owner's words.
///
/// `Exchange.Failure` rather than a new type: it is already the app's
/// sentence-pair-with-a-verb-in-it, and the board's failures are the same
/// failures the conversation has.
enum TaskBoardTrouble {

    static let cannotReach = Exchange.Failure(
        headline: "Mynah can't reach your list.",
        explanation: "It couldn't get to what keeps your tasks. Try again in a moment — "
            + "nothing has been lost.",
        canRetry: true
    )

    static let cannotRead = Exchange.Failure(
        headline: "Mynah couldn't read your list.",
        explanation: "What came back wasn't something it could make sense of. Try again.",
        canRetry: true
    )

    static let notInstalled = Exchange.Failure(
        headline: "Mynah can't find what it remembers.",
        explanation: "Quit Mynah and open it again. If that doesn't help, install it once more.",
        isSevere: true
    )
}

/// Reads the owner's open tasks from the memory node bundled in this app.
///
/// The same shape as `SageMemoryStore` and for the same reasons: one long-lived
/// `MCPClient`, because the child process runs a handshake that takes seconds,
/// and `MynahIdentity` for the signature, because the backlog is *per agent* —
/// signing as anything else would return a different appliance's plate.
///
/// Read-only, deliberately and for now. `sage_task` can move a task between
/// statuses, which is a write into consensus on the owner's own node; a board
/// that could be dragged would be doing that on a mis-click. Until that is
/// somebody's considered decision, this type has no method that writes.
actor SageTaskSource: TaskSource {

    static let shared = SageTaskSource()

    private var client: MCPClient?

    private static var executableURL: URL? {
        EnvironmentProbe.defaultSageBundleExecutables.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func connection() throws -> MCPClient {
        if let client { return client }
        guard let executable = Self.executableURL else { throw TaskSourceFailure.notInstalled }
        // The same identity every other spawn site uses. Signing as anything
        // else returns a different agent's backlog — which would look like a
        // working board and be somebody else's work.
        let environment = ["SAGE_IDENTITY_PATH": MynahIdentity.resolvedKeyPath()]
        // 30s, matching the memories screen. A list that has not answered in
        // half a minute has failed, and the board owes the owner a sentence
        // rather than another minute of nothing.
        let made = MCPClient(
            executableURL: executable,
            arguments: ["mcp"],
            environment: environment,
            requestTimeoutSeconds: 30
        )
        client = made
        return made
    }

    /// Drops a dead child so the next attempt starts a fresh one. A retained
    /// dead client answers every later request with the same failure forever.
    private func reset() {
        client?.stop()
        client = nil
    }

    func board() async throws -> TaskBoard {
        let client = try connection()
        let text: String
        do {
            // No arguments: `domain` would filter, and the whole point of this
            // screen is everything on the plate at once.
            text = try await client.call(name: "sage_backlog", arguments: [:])
        } catch let error as MCPClientError {
            boardLog.error("sage_backlog failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .missingExecutable:
                throw TaskSourceFailure.notInstalled
            case .toolFailed, .rpcError, .malformedResponse:
                throw TaskSourceFailure.unreadable
            case .launchFailed, .notStarted, .serverExited, .timedOut:
                reset()
                throw TaskSourceFailure.unreachable
            }
        } catch {
            boardLog.error("sage_backlog failed: \(String(describing: error), privacy: .public)")
            reset()
            throw TaskSourceFailure.unreachable
        }

        guard let board = TaskBoardReading.board(fromToolText: text) else {
            boardLog.error("sage_backlog returned text with no readable payload")
            throw TaskSourceFailure.unreadable
        }
        return board
    }
}

enum TaskSourceFailure: Error, Equatable {
    case notInstalled
    case unreachable
    case unreadable

    var failure: Exchange.Failure {
        switch self {
        case .notInstalled: return TaskBoardTrouble.notInstalled
        case .unreachable: return TaskBoardTrouble.cannotReach
        case .unreadable: return TaskBoardTrouble.cannotRead
        }
    }
}

// MARK: - Reading what the node said

/// Turning `sage_backlog`'s reply into columns.
///
/// Its own type so it can be tested against real payloads without a node: this
/// is the seam where a change at the other end becomes a wrong board, and it is
/// much easier to be sure of here than through a screenshot.
enum TaskBoardReading {

    /// The node's reply, which is not always bare JSON — a first call in a
    /// session carries a plain-text banner meant for an AI agent. The brace
    /// matcher that survives it already exists on the memories screen and is
    /// reused rather than written twice.
    static func board(fromToolText text: String) -> TaskBoard? {
        guard let payload = SageMemoryStore.embeddedObject(in: text) else { return nil }
        return board(from: payload)
    }

    static func board(from payload: JSONValue) -> TaskBoard? {
        // `tasks_by_domain` is the documented shape. Its absence means something
        // other than an empty plate — an error object, or a tool that changed —
        // and the board must say it could not read rather than draw nothing.
        guard let byDomain = payload["tasks_by_domain"]?.objectValue else { return nil }

        var rows: [BoardTask] = []
        for (domain, entries) in byDomain {
            for entry in entries.arrayValue ?? [] {
                guard let task = self.task(from: entry, domain: domain) else { continue }
                rows.append(task)
            }
        }
        return TaskBoard.from(rows: rows)
    }

    static func task(from entry: JSONValue, domain: String?) -> BoardTask? {
        guard let id = entry["memory_id"]?.stringValue, !id.isEmpty,
              let content = entry["content"]?.stringValue,
              let status = entry["task_status"]?.stringValue,
              let progress = BoardTask.Progress(nodeStatus: status) else { return nil }

        let title = strippingTaskMarker(content)
        guard !title.isEmpty else { return nil }

        return BoardTask(
            id: id,
            title: title,
            progress: progress,
            domain: (domain?.isEmpty == false) ? domain : nil,
            carrier: carrier(in: entry),
            createdAt: SageMemoryStore.date(from: entry["created_at"]?.stringValue)
        )
    }

    /// Tasks are stored with exactly one `[TASK] ` prefix so the node can tell
    /// them apart. That is filing, not something the owner wrote, and it has no
    /// business being the first word on every card.
    static func strippingTaskMarker(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[TASK] ") {
            text.removeFirst("[TASK] ".count)
        } else if text.hasPrefix("[TASK]") {
            text.removeFirst("[TASK]".count)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whose hands the task is in, when that is worth saying.
    ///
    /// Silent in the ordinary case. Every row the backlog returns is assigned to
    /// this appliance, so naming it on every card would be noise; what is worth
    /// showing is the exception — another agent has picked the work up, or the
    /// node says it is not this appliance's after all.
    static func carrier(in entry: JSONValue) -> BoardTask.Carrier? {
        let assignee = entry["assignee"]?.stringValue
        if let pickedUpBy = entry["task_picked_up_by"]?.stringValue,
           !pickedUpBy.isEmpty,
           pickedUpBy != assignee {
            return .pickedUpBy(pickedUpBy)
        }
        if entry["assigned_to_you"]?.boolValue == false, let assignee, !assignee.isEmpty {
            return .assignedTo(assignee)
        }
        return nil
    }
}

// MARK: - The board's state

/// What the board knows, and how sure it is of it.
///
/// The rule this type exists to keep: an owner with twelve tasks and a node that
/// has stopped answering must never be shown an empty board. The last good
/// answer and the current trouble are separate values for exactly that reason —
/// a single `enum` state would have to throw one away to hold the other.
@MainActor
@Observable
final class TaskBoardModel {

    /// One per app, like the conversation and the mirror: the pane is destroyed
    /// and rebuilt as the owner moves around, and the node connection behind
    /// this must not be.
    static let shared = TaskBoardModel()

    /// How often the plate is re-read while it is on screen.
    ///
    /// Slower than the conversation's poll on purpose. A task appears when the
    /// owner asks for one and is answered, which is a thing they watch happen;
    /// half a minute is well inside "it noticed" and this is a call into a node
    /// that is also answering their phone.
    static let refreshInterval: Duration = .seconds(30)

    /// The last board that was actually read. Held through a failure.
    private(set) var board: TaskBoard?
    /// The most recent failure, or `nil` when the last read worked.
    private(set) var trouble: Exchange.Failure?
    private let source: any TaskSource

    init(source: any TaskSource = SageTaskSource.shared) {
        self.source = source
    }

    /// Preloaded, for previews. Reads nothing.
    init(board: TaskBoard?, trouble: Exchange.Failure? = nil) {
        self.source = FixtureTaskSource(fixture: board)
        self.board = board
        self.trouble = trouble
    }

    /// Reads once, then keeps reading until the caller's task is cancelled —
    /// which SwiftUI does when the pane goes away, so nothing polls the node
    /// while the owner is somewhere else in the app.
    func follow() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh() async {
        do {
            let read = try await source.board()
            // Assigning an equal value still tells every observer to redraw —
            // `@Observable` announces rather than compares — and this one runs
            // on a timer, so an unchanged plate must not repaint the screen.
            if read != board { board = read }
            if trouble != nil { trouble = nil }
        } catch let failure as TaskSourceFailure {
            trouble = failure.failure
        } catch {
            boardLog.error("could not read the board: \(String(describing: error), privacy: .public)")
            trouble = TaskBoardTrouble.cannotReach
        }
    }
}

/// A board handed over rather than read. Previews only — the app never builds
/// one, because a board that can be told what to say is not a board.
private struct FixtureTaskSource: TaskSource {
    let fixture: TaskBoard?

    func board() async throws -> TaskBoard {
        guard let fixture else { throw TaskSourceFailure.unreachable }
        return fixture
    }
}
