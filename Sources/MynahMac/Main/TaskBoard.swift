import Foundation
import Observation
import OSLog
import SageVoiceCore

// MARK: - What is on the owner's plate

private let boardLog = MynahLog(category: "board")

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

    /// Whether the source that filled this board can speak about finished work
    /// at all.
    ///
    /// `sage_backlog` answers with **open** tasks; done and dropped work is not
    /// empty in its reply, it is absent. Drawing a Done column from it would
    /// print "Nothing finished yet." permanently over work that exists and was
    /// completed — a column that is always wrong is worse than a column that is
    /// not there. So the reader says what it can see and the view draws only
    /// that.
    var coversFinishedWork: Bool = true

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
    /// Moves a card between columns without asking the node.
    ///
    /// For the moment between the owner letting go and the write landing. The
    /// node is the authority and `TaskBoardModel.move` re-reads from it
    /// immediately afterwards — this exists so the card arrives at the speed of
    /// the gesture rather than the speed of consensus.
    /// One card, wherever it currently sits.
    func task(withID id: String) -> BoardTask? {
        (planned + inProgress + done + dropped + unclassified).first { $0.id == id }
    }

    mutating func move(taskID: String, to status: BoardTask.Progress) {
        var all = planned + inProgress + done + dropped + unclassified
        guard let index = all.firstIndex(where: { $0.id == taskID }) else { return }
        all[index].progress = status
        let moved = TaskBoard.from(rows: all, coversFinishedWork: coversFinishedWork)
        self = moved
    }

    static func from(rows: [BoardTask], coversFinishedWork: Bool = true) -> TaskBoard {
        // Newest first within a column. For open work that is when it was
        // asked for; for finished work it is when it finished, which is the
        // order somebody scanning "what got done" actually wants.
        let ordered = rows.sorted { first, second in
            (first.shownAt ?? .distantPast) > (second.shownAt ?? .distantPast)
        }
        return TaskBoard(
            planned: byWhenTheyHappen(ordered.filter { $0.progress == .planned }),
            inProgress: ordered.filter { $0.progress == .inProgress },
            done: ordered.filter { $0.progress == .done },
            dropped: ordered.filter { $0.progress == .dropped },
            unclassified: ordered.filter { $0.progress == nil },
            coversFinishedWork: coversFinishedWork
        )
    }

    /// Soonest first, and undated work after all of it.
    ///
    /// **The order a list is read in is the order it gets done in.** Sorted by
    /// when it was written down, the board put Thursday's haircut above
    /// Tuesday's meeting because the haircut was typed two seconds later. The
    /// owner: *"i'm talking about the order in which they should be 'executed'
    /// / reminder sent to you based on the timing - like don't remind me about
    /// thursday on monday instead of telling me about things on tuesday /
    /// wednesday"*.
    ///
    /// The date comes out of the task's own words — Mynah writes "Wednesday 5
    /// August 2026, 11am" into the title — so this needs no store of its own
    /// and works on every task already on his node. See `SpokenDate.writtenDate`
    /// for why a numeric "5/8" deliberately yields nothing.
    ///
    /// Undated last rather than first: "apply for the UOB card" has no deadline
    /// and putting it above a dated appointment would bury the thing that
    /// actually expires. Within the undated the existing newest-first order is
    /// kept, which is what `sorted(by:)` being stable gives us for free.
    static func byWhenTheyHappen(_ tasks: [BoardTask]) -> [BoardTask] {
        let dated = tasks.compactMap { task in
            SpokenDate.writtenDate(in: task.title).map { (task, $0) }
        }
        let undatedIDs = Set(dated.map(\.0.id))
        return dated.sorted { $0.1 < $1.1 }.map(\.0)
            + tasks.filter { !undatedIDs.contains($0.id) }
    }
}

// MARK: - Things happening at the same moment

/// One box on the board: usually a single task, sometimes several that happen at
/// the same time.
///
/// The owner, looking at a dentist appointment and a Google Meet both written
/// for Tuesday at 1pm and drawn as two unrelated cards: *"if there's a clash,
/// can we put them like into 1 bounding box - so its clear it happens at the
/// same time"*, and then the shape of it: *"we still need them to show as
/// separate items but within the blue or red box, make it 1 bounding box"*.
///
/// **Not a warning.** His own example is two things that share a slot perfectly
/// well — *"some things can be done simultaneously; like send car to car wash
/// and get groceries"* — so this states a fact and leaves the judgement to him.
/// Nothing here calls it a conflict, refuses it, or asks him to fix it.
struct TaskCluster: Identifiable, Equatable {
    var tasks: [BoardTask]
    /// The clock time they share, already written the way the owner wrote it —
    /// `nil` for an ordinary single card.
    var sharedTime: String?

    /// Stable across renders because it is built from the members, and unique
    /// because task ids are.
    var id: String { tasks.map(\.id).joined(separator: "+") }

    var isShared: Bool { tasks.count > 1 }
}

extension TaskBoard {

    /// Groups an **already ordered** list into boxes.
    ///
    /// Consecutive-only, which is not a shortcut: `byWhenTheyHappen` has sorted
    /// by date, so everything at the same moment is already adjacent. Scanning
    /// the whole list instead would let two tasks be boxed together across a
    /// third that happens between them, and a box whose contents are not
    /// contiguous in time is a lie about the day.
    ///
    /// **A shared *day* is not a shared moment.** Two things due Friday with no
    /// hour written are not happening at once — a day holds plenty — so
    /// `.day` granularity never clusters. That is the same distinction
    /// `ReminderLadder` draws, and for the same reason: no hour was named, so
    /// none may be invented.
    static func clustered(_ ordered: [BoardTask], calendar: Calendar = .current) -> [TaskCluster] {
        var boxes: [TaskCluster] = []
        var current: [(task: BoardTask, when: SpokenDate.WrittenDate)] = []

        func flush() {
            guard !current.isEmpty else { return }
            boxes.append(TaskCluster(
                tasks: current.map(\.task),
                sharedTime: current.count > 1 ? clock(current[0].when.at, calendar: calendar) : nil
            ))
            current = []
        }

        for task in ordered {
            guard let when = SpokenDate.writtenDateMatch(in: task.title, calendar: calendar),
                  when.granularity != .day else {
                flush()
                boxes.append(TaskCluster(tasks: [task], sharedTime: nil))
                continue
            }
            if let open = current.first, open.when.at != when.at {
                flush()
            }
            current.append((task, when))
        }
        flush()
        return boxes
    }

    /// The shared hour, written the short way somebody says it: `1pm`, `10:30am`.
    ///
    /// Deliberately not `Date.formatted`, which is locale-driven and would put
    /// `13:00` on a board whose every task title says `1pm`. The label exists to
    /// name the moment two cards have in common, and naming it differently from
    /// how both of them spell it is worse than not labelling it at all.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "am" : "pm"
        return minute == 0
            ? "\(twelve)\(suffix)"
            : String(format: "%d:%02d%@", twelve, minute, suffix)
    }
}

// MARK: - How near a task is

/// Near enough to mark on the card.
///
/// The owner, looking at a 10am task sitting four cards down: *"things that are
/// due today should be at the top probably with a 'blue' border for the card
/// perhaps to show its something happening soon"*, then *"use orange then for
/// due tomorrow"*.
///
/// The ordering half of that was already built and was not working, for a reason
/// worth keeping written down: the task had no readable date, so it sorted with
/// the undated. `DatedTaskWrites` is what fixed that. This is only the mark.
///
/// Out of the view so "is this today" is a function with tests rather than a
/// date comparison inlined in a `body`.
enum TaskNearness: Equatable, Sendable {
    case today
    case tomorrow

    /// Nothing for a task that is undated, further off, or already past.
    ///
    /// **Overdue is deliberately unmarked.** A red-ish border on a lapsed task
    /// would be the fourth job for a colour on this board, and the appliance
    /// already has a better channel for it: the ladder asks about overdue work
    /// in a message, in words, with a way to act. A border cannot be answered.
    static func of(_ task: BoardTask, now: Date = Date(), calendar: Calendar = .current) -> TaskNearness? {
        guard let due = SpokenDate.writtenDate(in: task.title, calendar: calendar) else { return nil }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: due)
        ).day
        switch days {
        case 0: return .today
        case 1: return .tomorrow
        default: return nil
        }
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

    /// Moves one task to a new status.
    ///
    /// Separate from `board()` because it is the first thing this screen has
    /// ever *written*. Everything else here reads and redraws; this changes the
    /// node, and a source that cannot write should fail loudly rather than
    /// pretend by returning.
    func move(taskID: String, to status: BoardTask.Progress) async throws
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
    /// it only means *you are not an operator*. The node answered signed MCP
    /// calls throughout the period this state was on screen, so nothing was
    /// sealed. One token, two doors, opposite meanings, and the copy took the
    /// alarming one.
    ///
    /// **This also said "Mynah just can't read them", which named the wrong
    /// subject.** Whether Mynah can read a given subject is a per-domain
    /// question and mostly the answer is no — but it has nothing to do with
    /// *this* failure. This board asks a CEREBRUM operator endpoint the app has
    /// no session for. The 401 is about the app's lack of a key, and naming
    /// Mynah in a sentence about the app's own limitation is what made it read
    /// as a claim about the appliance.
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

    /// A refused move. Names the card's own way back, because the owner is
    /// looking straight at the card that snapped home and the one thing they
    /// need to know is whether to try again or go somewhere else.
    static let cannotMove = Exchange.Failure(
        headline: "Mynah couldn't move that card.",
        explanation: "The card is back where it was. Try again, or change it in "
            + "CEREBRUM if it keeps refusing.",
        isSevere: false
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

    /// Refuses. This source reads an unsigned dashboard endpoint that answers
    /// `401` on a real node — it has never opened, let alone written — so a
    /// `move` that returned would be claiming to have changed something.
    func move(taskID: String, to status: BoardTask.Progress) async throws {
        throw TaskSourceFailure.refused
    }

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
            boardLog.error("task board fetch failed: \(String(describing: error))")
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
            boardLog.error("task board returned \(http.statusCode)")
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

    /// **MCP, not the CEREBRUM feed.** The unsigned dashboard read this used to
    /// make is answered `401` on the owner's node and has never once opened —
    /// see `MCPTaskSource` for why the narrow, signed, self-scoped tool is the
    /// correct answer rather than the consolation prize.
    init(source: any TaskSource = MCPTaskSource.shared) {
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

    /// Moves a card, and puts it back if the node refuses.
    ///
    /// **Optimistically, and that is the point.** The owner dragged a card; the
    /// card has to arrive where they dropped it, at the speed of the gesture,
    /// not after a round trip to a consensus write. So the board is updated
    /// first and reverted if the write fails — and a revert is loud, because a
    /// card that silently slides back is indistinguishable from a dropped
    /// gesture and the owner will simply try again.
    ///
    /// The write is `sage_task` with `memory_id` and `status`, which is the same
    /// call the model makes when asked to move something — the owner is doing it
    /// directly instead of spending a turn asking. That was the whole request.
    func move(_ task: BoardTask, to status: BoardTask.Progress) async {
        guard task.progress != status else { return }
        let previous = board

        if var optimistic = board {
            optimistic.move(taskID: task.id, to: status)
            board = optimistic
        }

        do {
            try await source.move(taskID: task.id, to: status)
            // Read back rather than trusting the local edit: the node decides
            // what a status change means for assignment and timestamps, and the
            // card should show what it actually said.
            await refresh()
        } catch {
            boardLog.error("could not move \(task.id) to \(status): \(String(describing: error))")
            board = previous
            trouble = TaskBoardTrouble.cannotMove
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
            boardLog.error("could not read the board: \(String(describing: error))")
            trouble = TaskBoardTrouble.cannotReach
        }
    }
}

/// A board handed over rather than read. Previews only — the app never builds
/// one, because a board that can be told what to say is not a board.
private struct FixtureTaskSource: TaskSource {
    let fixture: TaskBoard?

    func move(taskID: String, to status: BoardTask.Progress) async throws {}

    func board() async throws -> TaskBoard {
        guard let fixture else { throw TaskSourceFailure.unreachable }
        return fixture
    }
}
