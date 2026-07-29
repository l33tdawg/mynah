import Foundation
import Observation
import OSLog
import SageVoiceCore

// MARK: - What is on the owner's plate

private let boardLog = Logger(subsystem: "com.sage.mynah", category: "board")

/// One task, as the board draws it.
///
/// Every field here is something the node actually publishes. There is no
/// priority, no due date and no estimate, because the task feed returns none of
/// those and a board that invents them is a board nobody can trust twice.
struct BoardTask: Identifiable, Equatable, Sendable {

    /// Another agent's hands on this task, and which kind of involvement it is.
    /// The two are not the same claim and the card says which.
    enum Carrier: Equatable, Sendable {
        /// Assigned here, but another agent started it.
        case pickedUpBy(String)
        /// The node says this is not this appliance's work at all.
        case assignedTo(String)
        /// The agent that carried it to `done`. Terminal transitions keep the
        /// assignee as attribution rather than clearing it, which is what makes
        /// "Completed by" a fact rather than a guess.
        case completedBy(String)
        /// The same, for work that was abandoned.
        case droppedBy(String)

        var agent: String {
            switch self {
            case .pickedUpBy(let agent), .assignedTo(let agent),
                 .completedBy(let agent), .droppedBy(let agent):
                return agent
            }
        }
    }

    /// The workflow the node really runs.
    ///
    /// Not a shape invented for the screen: tasks carry `planned`,
    /// `in_progress`, `done` and `dropped`. All four are columns — an earlier
    /// version of this file dropped abandoned work on the grounds that "a column
    /// of things the owner gave up on is a monument", which was a reasonable
    /// opinion about a board and the wrong call about *this* board. CEREBRUM
    /// shows four, this shows the same four, and an owner comparing the two must
    /// not find work in one that is missing from the other.
    enum Progress: String, Equatable, Sendable, CaseIterable {
        case planned
        case inProgress
        case done
        case dropped

        /// `nil` for anything the node did not label, which is a real case and
        /// not an error: rows written by older versions come back with an
        /// **empty** status because SAGE deliberately does not guess whether
        /// unknown work is planned or finished. Neither does this. They go to
        /// `TaskBoard.unclassified` and are counted, never quietly filed under
        /// Planned to make the board look tidy.
        init?(nodeStatus: String) {
            switch nodeStatus {
            case "planned": self = .planned
            case "in_progress": self = .inProgress
            case "done": self = .done
            case "dropped": self = .dropped
            default: return nil
            }
        }

        /// Work that has stopped moving, and is therefore subject to the
        /// seven-day window.
        var isTerminal: Bool { self == .done || self == .dropped }
    }

    /// The task's memory id, which is stable across reads.
    let id: String
    var title: String
    /// `nil` when the node returned no status. See `Progress.init(nodeStatus:)`.
    var progress: Progress?
    /// The domain the task was filed under. Shown because it is the only
    /// grouping the owner themselves chose.
    var domain: String?
    /// Who is holding this, when that is worth saying.
    var carrier: Carrier?
    /// Who wrote it down. Empty for a task the owner created themselves, which
    /// is why the card says nothing rather than "unknown".
    var author: String?
    var createdAt: Date?
    /// When the task last changed status — *not* when it was written.
    ///
    /// The board's seven-day window for finished work is measured from this and
    /// nothing else. A task created in March and finished yesterday is a card
    /// the owner still wants to see; measured from `createdAt` it would already
    /// be gone.
    var statusChangedAt: Date?

    /// The timestamp worth showing on the card: when it stopped, if it has
    /// stopped, and otherwise when it started.
    var shownAt: Date? {
        (progress?.isTerminal == true ? statusChangedAt : nil) ?? createdAt
    }
}

/// The four columns, plus whatever the node could not label.
struct TaskBoard: Equatable, Sendable {
    var planned: [BoardTask] = []
    var inProgress: [BoardTask] = []
    var done: [BoardTask] = []
    var dropped: [BoardTask] = []

    /// Rows the node returned with no status at all.
    ///
    /// Not a column. These are historical rows whose writer never persisted a
    /// status, and the node hands them over unlabelled precisely so that a human
    /// can decide. Mynah cannot decide for them and does not try; the board says
    /// how many there are and leaves it there.
    var unclassified: [BoardTask] = []

    /// How long a finished or abandoned card stays on the board.
    ///
    /// Seven days from the terminal transition, which is what CEREBRUM does with
    /// the same field. Matching it is the point: two boards over the same node
    /// showing different amounts of finished work is how an owner stops
    /// believing either.
    static let terminalWindow: TimeInterval = 7 * 24 * 60 * 60

    var isEmpty: Bool {
        planned.isEmpty && inProgress.isEmpty && done.isEmpty
            && dropped.isEmpty && unclassified.isEmpty
    }

    /// Terminal cards from the last seven days, or all of them.
    func recent(_ tasks: [BoardTask], showingAll: Bool, now: Date = Date()) -> [BoardTask] {
        guard !showingAll else { return tasks }
        return tasks.filter { task in
            // No timestamp means the node could not say when it finished. Kept
            // rather than hidden: disappearing a card because a field was blank
            // is the board losing work on a technicality.
            guard let changed = task.statusChangedAt else { return true }
            return now.timeIntervalSince(changed) <= Self.terminalWindow
        }
    }

    /// How many finished cards the window is currently holding back, so "Show
    /// all" can say what it would reveal instead of being a mystery switch.
    func olderThanWindow(now: Date = Date()) -> Int {
        let terminal = done + dropped
        return terminal.count - recent(terminal, showingAll: false, now: now).count
    }

    /// Splits what the node returned into columns.
    static func from(rows: [BoardTask]) -> TaskBoard {
        // Newest first within a column. For open work that is when it was
        // asked for; for finished work it is when it finished, which is the
        // order somebody scanning "what got done" actually wants.
        let ordered = rows.sorted { first, second in
            (first.shownAt ?? .distantPast) > (second.shownAt ?? .distantPast)
        }
        return TaskBoard(
            planned: ordered.filter { $0.progress == .planned },
            inProgress: ordered.filter { $0.progress == .inProgress },
            done: ordered.filter { $0.progress == .done },
            dropped: ordered.filter { $0.progress == .dropped },
            unclassified: ordered.filter { $0.progress == nil }
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

    /// The one that must never be mistaken for an empty plate.
    ///
    /// An unsigned local read of the CEREBRUM board answers `401
    /// {"login_required":true}` — verified against the owner's own node. Every
    /// word of this is chosen so that a person with thirty-four open tasks
    /// cannot read it as "you have nothing on".
    ///
    /// **The node is not locked, and this used to say it was.** `login_required`
    /// is the same token SAGE returns over MCP when a vault really is sealed,
    /// which is how it came to be read as one here — but over REST, unsigned,
    /// it only means *you are not an operator*. Checked by reading the node at
    /// the moment this state was on screen: 13,372 memories across some 700
    /// subjects, answered without complaint. One token, two doors, opposite
    /// meanings, and the copy took the alarming one.
    ///
    /// **This said "Mynah just can't read them", and that is false.**
    ///
    /// Mynah reads this node freely — the owner has a screenshot of it listing
    /// his subjects back to him, in a window whose top half was showing this
    /// sentence. Two different doors were being conflated: Mynah reads memories
    /// over MCP as a signed agent, and this board was asking a CEREBRUM
    /// *operator* endpoint that the app has no session for. The 401 is about
    /// the app's lack of a key, not about what the appliance may see.
    ///
    /// Naming Mynah in a sentence about the app's own limitation is what made
    /// it read as a claim about the appliance.
    static let locked = Exchange.Failure(
        headline: "Your tasks need CEREBRUM.",
        explanation: "They are all still there. This list comes from a part of your node "
            + "that only answers a signed-in operator, and this window isn't one. "
            + "Open CEREBRUM to see them.",
        canRetry: true
    )

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

    /// The node answered and refused. In practice this means the request was
    /// signed, which this reader deliberately never does — see
    /// `CerebrumTaskSource`.
    static let refused = Exchange.Failure(
        headline: "Your node wouldn't show Mynah the board.",
        explanation: "Your tasks are unaffected. Quit Mynah and open it again; if it keeps "
            + "happening, the board is still in CEREBRUM.",
        canRetry: true
    )

    /// **No reinstall suggestion, and that is deliberate.**
    ///
    /// A reinstall is the instinctive fix and it is the one thing that cannot
    /// work: the appliance's key lives in Application Support, which macOS does
    /// not remove when an app is trashed, so the same identity comes back with
    /// the same registration and the same capability mask. Telling somebody to
    /// reinstall would send them through the whole ritual to arrive exactly
    /// where they started, and conclude the product is broken beyond fixing.
    static let notInstalled = Exchange.Failure(
        headline: "Mynah can't find what it remembers.",
        explanation: "Quit Mynah and open it again. If your list is still missing after that, "
            + "send the diagnostics from Settings — this one needs a look rather than a retry.",
        isSevere: true
    )
}

/// Reads the same board CEREBRUM draws.
///
/// **Why this is HTTP and not the MCP tool it used to be.** The previous version
/// called `sage_backlog`, which returns "open tasks *explicitly assigned to the
/// signed agent ID*" — so it could only ever return work assigned to Mynah
/// itself. Nothing was, which is why a node holding 6 planned, 7 in progress and
/// 21 done rendered as two empty columns and a sentence blaming the node for not
/// publishing finished work. The node published all of it; the tool was the
/// wrong question. `GET /v1/dashboard/tasks?all=true` is the feed CEREBRUM reads
/// and it returns all four statuses.
///
/// **This request is deliberately unsigned.** The full board is gated on being a
/// local CEREBRUM read; a signed agent identity is answered `403` and told to
/// use the scoped backlog. So attaching Mynah's identity here would not get more
/// access, it would get less. On an unencrypted node the unsigned local read
/// passes; on an encrypted one it is answered `401 {"login_required":true}`,
/// which becomes `TaskBoardTrouble.locked` and never an empty board.
///
/// Read-only, and not merely "for now": every mutation on this surface —
/// reorder, assign, change status — requires operator authority this process
/// does not have and cannot obtain by asking nicely. A card that could be
/// dragged would be a control that fails, which is worse than no control.
actor CerebrumTaskSource: TaskSource {

    static let shared = CerebrumTaskSource()

    /// The backend's own maximum. Asking for more is silently clamped, so this
    /// is the honest number rather than an optimistic one.
    static let maximumCards = 500

    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL? = nil, timeout: TimeInterval = 15) {
        self.endpoint = endpoint ?? Self.defaultEndpoint()
        // The shared loopback session: no cookies, no credentials, no caching,
        // and a hard refusal to follow a redirect off the loopback interface.
        self.session = LoopbackSecurity.makeSession(timeout: timeout)
    }

    /// `127.0.0.1:8080` is the shipped REST default. `SAGE_API_URL` overrides it
    /// for anyone running the node somewhere else, and is ignored unless it
    /// points at this machine — a task board fetched from a stranger's node
    /// would be somebody else's life rendered as the owner's.
    static func defaultEndpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let fallback = URL(string: "http://127.0.0.1:8080")!
        let configured = environment["SAGE_API_URL"].flatMap(URL.init(string:))
        let base = LoopbackSecurity.isLoopback(configured) ? (configured ?? fallback) : fallback
        return base.appendingPathComponent("v1/dashboard/tasks")
    }

    private var request: URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "all", value: "true"),
            URLQueryItem(name: "limit", value: String(Self.maximumCards))
        ]
        var request = URLRequest(url: components?.url ?? endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func board() async throws -> TaskBoard {
        let request = self.request
        guard let url = request.url else { throw TaskSourceFailure.unreachable }
        do {
            try LoopbackSecurity.requireLoopback(url)
        } catch {
            boardLog.error("task board endpoint is not loopback")
            throw TaskSourceFailure.unreachable
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            boardLog.error("task board fetch failed: \(String(describing: error), privacy: .public)")
            throw TaskSourceFailure.unreachable
        }

        guard let http = response as? HTTPURLResponse else { throw TaskSourceFailure.unreadable }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw TaskSourceFailure.locked
        case 403:
            throw TaskSourceFailure.refused
        default:
            boardLog.error("task board returned \(http.statusCode, privacy: .public)")
            throw TaskSourceFailure.unreachable
        }

        guard let board = TaskBoardReading.board(fromResponse: data) else {
            boardLog.error("task board returned a body with no readable tasks array")
            throw TaskSourceFailure.unreadable
        }
        return board
    }
}

enum TaskSourceFailure: Error, Equatable {
    case notInstalled
    case unreachable
    case unreadable
    case locked
    case refused

    var failure: Exchange.Failure {
        switch self {
        case .notInstalled: return TaskBoardTrouble.notInstalled
        case .unreachable: return TaskBoardTrouble.cannotReach
        case .unreadable: return TaskBoardTrouble.cannotRead
        case .locked: return TaskBoardTrouble.locked
        case .refused: return TaskBoardTrouble.refused
        }
    }
}

// MARK: - Reading what the node said

/// Turning the task feed's reply into columns.
///
/// Its own type so it can be tested against real payloads without a node: this
/// is the seam where a change at the other end becomes a wrong board, and it is
/// much easier to be sure of here than through a screenshot.
enum TaskBoardReading {

    /// `{"tasks":[…],"total":N}`, as `handleGetTasks` writes it.
    static func board(fromResponse data: Data) -> TaskBoard? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let payload = JSONValue.parse(text) ?? SageMemoryStore.embeddedObject(in: text) else {
            return nil
        }
        return board(from: payload)
    }

    static func board(from payload: JSONValue) -> TaskBoard? {
        // The absence of the array means something other than an empty plate —
        // an error object, or a feed that changed — and the board must say it
        // could not read rather than draw nothing.
        guard let entries = payload["tasks"]?.arrayValue else { return nil }
        return TaskBoard.from(rows: entries.compactMap(task(from:)))
    }

    static func task(from entry: JSONValue) -> BoardTask? {
        guard let id = entry["memory_id"]?.stringValue, !id.isEmpty,
              let content = entry["content"]?.stringValue else { return nil }

        let title = strippingTaskMarker(content)
        guard !title.isEmpty else { return nil }

        // A missing or empty `task_status` is the unclassified case and stays
        // `nil` all the way to the board. Defaulting it here would be the guess
        // the node refused to make.
        let progress = (entry["task_status"]?.stringValue).flatMap(BoardTask.Progress.init(nodeStatus:))
        let domain = entry["domain_tag"]?.stringValue

        return BoardTask(
            id: id,
            title: title,
            progress: progress,
            domain: (domain?.isEmpty == false) ? domain : nil,
            carrier: carrier(in: entry, progress: progress),
            author: author(in: entry),
            createdAt: SageMemoryStore.date(from: entry["created_at"]?.stringValue),
            statusChangedAt: SageMemoryStore.date(from: entry["task_status_updated_at"]?.stringValue)
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
    /// Terminal cards read differently from open ones, and the node's own words
    /// for that are "Completed by" and "Dropped by": a finished task keeps its
    /// assignee purely as attribution, so naming them is reporting rather than
    /// implying anyone is still working on it.
    static func carrier(in entry: JSONValue, progress: BoardTask.Progress?) -> BoardTask.Carrier? {
        let assignee = entry["assignee"]?.stringValue
        let pickedUpBy = entry["task_picked_up_by"]?.stringValue

        if progress?.isTerminal == true {
            guard let who = [assignee, pickedUpBy].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
                return nil
            }
            return progress == .done ? .completedBy(who) : .droppedBy(who)
        }
        if let pickedUpBy, !pickedUpBy.isEmpty, pickedUpBy != assignee {
            return .pickedUpBy(pickedUpBy)
        }
        if let assignee, !assignee.isEmpty {
            return .assignedTo(assignee)
        }
        return nil
    }

    /// Who wrote the task down. Human-created tasks carry an empty provider, and
    /// that absence is the signal — a card with no author is one the owner made,
    /// and saying "you" on it would be noise.
    static func author(in entry: JSONValue) -> String? {
        for key in ["provider", "submitting_agent"] {
            if let value = entry[key]?.stringValue, !value.isEmpty { return value }
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
    /// and rebuilt as the owner moves around, and the connection behind this
    /// must not be.
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

    /// Whether finished work older than the seven-day window is on screen.
    ///
    /// View state, not a setting: it lasts as long as the owner is looking and
    /// resets when they come back, which is the behaviour of a "show me the rest"
    /// control rather than a preference they have to remember they changed.
    var showsOlderFinished = false

    private let source: any TaskSource

    init(source: any TaskSource = CerebrumTaskSource.shared) {
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
