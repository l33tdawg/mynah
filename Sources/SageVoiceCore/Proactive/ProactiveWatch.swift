import Foundation

// MARK: - What a check can find

/// One task on the appliance's own list, as a check sees it.
public struct WatchedTask: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let status: String

    public init(id: String, title: String, status: String) {
        self.id = id
        self.title = title
        self.status = status
    }
}

/// What the appliance looks at when it checks on things by itself.
///
/// Narrow on purpose. A protocol that could reach anything would eventually
/// reach something the owner did not agree to be told about unprompted.
public protocol ProactiveSource: Sendable {
    /// Messages from the owner's other agents.
    func waitingMessages(limit: Int) async throws -> [AgentInboxItem]
    /// The appliance's own open tasks.
    func openTasks() async throws -> [WatchedTask]
}

// MARK: - What it has already said

/// What the last check saw, so this one can tell what is new.
///
/// **The whole feature lives or dies here.** An appliance that reports the same
/// four open tasks every hour is not proactive, it is a nag, and the owner
/// switches it off within a day. Nothing is said twice because everything said
/// once is written down.
public struct ProactiveLedger: Sendable, Equatable, Codable {

    /// Inbox items already reported. Ids only — the messages themselves are the
    /// node's to keep.
    public var toldAboutMessages: Set<String>

    /// Task id to the status it was in when last reported.
    public var knownTasks: [String: String]

    /// When the last check ran, whatever it found.
    ///
    /// Set on every attempt rather than every report, for the reason
    /// `UpdatePreferences.lastCheckedAt` is: this bounds how often the
    /// appliance asks its node, not how often it has something to say.
    public var lastCheckedAt: Date?

    /// Whether a first check has ever completed.
    ///
    /// The first one says nothing at all, and that is deliberate: the ledger is
    /// empty, so everything already on the list would read as having "just
    /// happened" — four tasks and a fortnight of inbox arriving in one message
    /// the moment the owner flicks the switch. What this feature is for is what
    /// changes *from now on*.
    public var hasSeeded: Bool

    /// Reminder rungs already delivered. See `ReminderLadder.Nudge.key`.
    public var saidReminders: Set<String>

    /// The open tasks as of the last check that actually reached the node.
    ///
    /// **Cached so reminders can be punctual without being expensive.** The
    /// owner set the check interval to fifteen minutes, and a rung that fires on
    /// a fifteen-minute grid cannot honestly say "in about half an hour". But
    /// the *dates* do not change between checks — only the clock moves. So the
    /// ladder is evaluated against this every tick, a minute apart, while the
    /// node is still only asked as often as he chose.
    ///
    /// Kept out of `knownTasks`, which stores statuses for a different question.
    public var lastSeenTasks: [WatchedTask]

    public init(
        toldAboutMessages: Set<String> = [],
        knownTasks: [String: String] = [:],
        lastCheckedAt: Date? = nil,
        hasSeeded: Bool = false,
        saidReminders: Set<String> = [],
        lastSeenTasks: [WatchedTask] = []
    ) {
        self.toldAboutMessages = toldAboutMessages
        self.knownTasks = knownTasks
        self.lastCheckedAt = lastCheckedAt
        self.hasSeeded = hasSeeded
        self.saidReminders = saidReminders
        self.lastSeenTasks = lastSeenTasks
    }

    // Both new fields decode as empty from a ledger written by an older build,
    // which is the correct upgrade: no reminder is "already said" on a Mac that
    // has never had reminders, and the first check refills the task cache.
    enum CodingKeys: String, CodingKey {
        case toldAboutMessages, knownTasks, lastCheckedAt, hasSeeded, saidReminders, lastSeenTasks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toldAboutMessages = try container.decodeIfPresent(Set<String>.self, forKey: .toldAboutMessages) ?? []
        knownTasks = try container.decodeIfPresent([String: String].self, forKey: .knownTasks) ?? [:]
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        hasSeeded = try container.decodeIfPresent(Bool.self, forKey: .hasSeeded) ?? false
        saidReminders = try container.decodeIfPresent(Set<String>.self, forKey: .saidReminders) ?? []
        lastSeenTasks = try container.decodeIfPresent([WatchedTask].self, forKey: .lastSeenTasks) ?? []
    }

    /// Bounded, because this file is written forever and an appliance that runs
    /// for a year should not carry every pipe id it ever saw. Only ids still
    /// present in the inbox are worth keeping — an item the node has dropped
    /// cannot arrive again.
    public mutating func forgetMessagesNotIn(_ present: Set<String>) {
        toldAboutMessages.formIntersection(present)
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("proactive-ledger.json", isDirectory: false)
    }

    public static func load(from url: URL = ProactiveLedger.defaultFileURL()) -> ProactiveLedger {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(ProactiveLedger.self, from: data) else {
            return ProactiveLedger()
        }
        return stored
    }

    public func save(to url: URL = ProactiveLedger.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }
}

// MARK: - What one check decided

/// The outcome of a single look, kept as a value so it can be tested without a
/// clock, a node or a phone.
public struct ProactiveReport: Sendable, Equatable {
    /// What to send, or `nil` when there is nothing worth saying — which is
    /// most checks, and is the point.
    public let message: String?
    public let ledger: ProactiveLedger
}

// MARK: - Checking without being asked

/// Looks at the inbox and the task list on a timer, and speaks only when
/// something has changed.
///
/// **This contradicts a note on `AgentMessaging`, and deliberately.** That type
/// says there is no polling, because a *window* polling a node that may refuse
/// is a retry storm somebody generates by leaving an app open. This is not a
/// window: it runs at an interval the owner chose, in the process that already
/// holds the Signal connection, and it stops entirely when they switch it off.
///
/// Three rules hold the whole design together:
///
/// 1. **Nothing is said twice.** Everything reported goes in the ledger.
/// 2. **The first check is silent.** It writes down what already exists so that
///    what follows is genuinely new.
/// 3. **Nothing is invented.** The message names what changed and stops; it
///    does not ask the model to have an opinion about it, which would cost a
///    turn on every check and could hallucinate on any of them.
public struct ProactiveWatch: Sendable {

    /// How much of another agent's message travels unprompted.
    ///
    /// Attributed and short. This text was written by something that is not
    /// Mynah — `UntrustedAgentContent` exists to keep that fact attached — and
    /// an unbounded relay would let an agent elsewhere push whatever it liked
    /// into the owner's Signal thread. Enough to know whether to go and read it
    /// is the right amount.
    public static let excerptCharacters = 160

    /// Items named in one message before it stops counting.
    public static let mostItemsNamed = 4

    private let source: any ProactiveSource

    public init(source: any ProactiveSource) {
        self.source = source
    }

    /// One check.
    ///
    /// Never throws. A node that is asleep, restarting or refusing is an
    /// ordinary state for a machine that runs all year, and a check that failed
    /// is simply a check that found nothing to say — it must not take the
    /// appliance down or produce an error message on the owner's phone.
    public func check(against ledger: ProactiveLedger) async -> ProactiveReport {
        // **`?? []` was the bug, and it was worse than silence.**
        //
        // A node that refuses used to be coalesced to an empty list, which is
        // not "nothing is there" — it is "I could not look", and the two are
        // opposite. Read as an empty backlog it meant every task the owner has
        // had just been completed, so the check announced *"A task came off the
        // list."* once per task and then overwrote the ledger with the empty
        // result. The next healthy tick, having forgotten everything, announced
        // the entire backlog and inbox again as new.
        //
        // Not hypothetical on this Mac. `sage_backlog failed: … connect:
        // connection refused` appears six times in one day in the owner's log,
        // and he has just set the interval to fifteen minutes.
        //
        // Nil, not empty, and the two halves fail independently: a reachable
        // inbox is still worth reporting when the backlog is down.
        let messages = try? await source.waitingMessages(limit: 20)
        let tasks = try? await source.openTasks()

        var updated = ledger

        // Every mutation below is guarded by "did we actually see it". The rule
        // this preserves is the one in the doc comment above — a failed check
        // says nothing — plus the one it was missing: a failed check must not
        // *forget* anything either.
        if let messages {
            updated.forgetMessagesNotIn(Set(messages.map(\.id)))
            updated.toldAboutMessages.formUnion(messages.map(\.id))
        }
        if let tasks {
            updated.knownTasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })
            // Refilled only on a check that actually read the node, for the same
            // reason as everything else in this block: a refusal must not empty
            // the cache, or the ladder would go quiet until the node came back.
            updated.lastSeenTasks = tasks
            updated.saidReminders = ReminderLadder.keysWorthKeeping(updated.saidReminders, tasks: tasks)
        }

        let newMessages = (messages ?? []).filter { !ledger.toldAboutMessages.contains($0.id) }
        let taskNews = tasks.map {
            Self.taskNews($0, against: ledger.knownTasks, seeded: ledger.hasSeeded)
        } ?? []

        // The silent first pass. Everything above is written down; nothing is
        // said.
        //
        // Only counts as seeded once something was actually read. Seeding on a
        // check that reached nothing would mark a ledger "primed" against an
        // empty picture, and the *next* check would then report the owner's
        // whole backlog as newly arrived — which is the same fault as the one
        // above, arriving one tick later.
        guard ledger.hasSeeded else {
            updated.hasSeeded = messages != nil || tasks != nil
            return ProactiveReport(message: nil, ledger: updated)
        }

        let lines = newMessages.map(Self.line(forMessage:)) + taskNews
        guard !lines.isEmpty else {
            return ProactiveReport(message: nil, ledger: updated)
        }
        return ProactiveReport(message: Self.message(from: lines), ledger: updated)
    }

    // MARK: What changed

    /// Added, moved and finished — in that order, because that is the order
    /// somebody cares about them.
    ///
    /// A task the appliance has never seen before is only news once it has been
    /// seeded; on an unseeded ledger every task is "new" and none of it is.
    static func taskNews(
        _ tasks: [WatchedTask],
        against known: [String: String],
        seeded: Bool
    ) -> [String] {
        guard seeded else { return [] }
        var lines: [String] = []

        for task in tasks where known[task.id] == nil {
            lines.append("A new task landed: “\(ending(task.title))”")
        }
        for task in tasks {
            guard let before = known[task.id], before != task.status else { continue }
            lines.append("“\(task.title)” is now \(readable(task.status)).")
        }
        // Gone from the open list, which on this node means finished or
        // dropped. Which of the two is not knowable from an absence, so it does
        // not claim to know.
        let present = Set(tasks.map(\.id))
        for (id, _) in known where !present.contains(id) {
            _ = id
            lines.append("A task came off the list.")
        }
        return lines
    }

    /// A task's own words, ending in a full stop exactly once.
    ///
    /// The owner writes these by speaking, so some end in a stop and some do
    /// not — and `“…the TBCERT event.”.` is the sort of detail that makes a
    /// message read as assembled rather than written.
    static func ending(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    static func readable(_ status: String) -> String {
        switch status.lowercased() {
        case "in_progress", "in progress": return "in progress"
        case "planned": return "planned"
        case "blocked": return "blocked"
        case "done", "completed": return "done"
        default: return status
        }
    }

    static func line(forMessage item: AgentInboxItem) -> String {
        let excerpt = Self.excerpt(item.content.read())
        let opening = item.expectsAResult
            ? "\(item.content.sender) sent work"
            : "\(item.content.sender) sent a message"
        let about = item.intent.map { " (\($0))" } ?? ""
        guard !excerpt.isEmpty else { return "\(opening)\(about)." }
        return "\(opening)\(about): “\(excerpt)”"
    }

    static func excerpt(_ body: String) -> String {
        let flat = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > Self.excerptCharacters else { return flat }
        return flat.prefix(Self.excerptCharacters).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One message, however many things happened.
    ///
    /// Not one per item: four notifications arriving at once is the behaviour
    /// that makes people mute a thread, and the appliance shares a thread with
    /// the owner's own notes.
    static func message(from lines: [String]) -> String {
        let named = lines.prefix(Self.mostItemsNamed)
        var body = named.joined(separator: "\n\n")
        let remainder = lines.count - named.count
        if remainder > 0 {
            body += "\n\n…and \(remainder) more. Ask me and I'll go through them."
        }
        return body
    }
}
